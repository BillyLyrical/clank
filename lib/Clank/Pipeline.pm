# Clank::Pipeline — parse .clank blueprints and run topic-wired pipelines.
# Also handles inline pipe construction (>| stage1 | stage2).
package Clank::Pipeline;
use strict;
use warnings;

my $PIPELINE_DIR;

sub pipeline_dir {
    my ($class, $dir) = @_;
    $PIPELINE_DIR = $dir if defined $dir;
    return $PIPELINE_DIR // "$ENV{HOME}/.clank/pipelines";
}

# Parse a .clank blueprint text into a structured pipeline.
# Returns { name, about, sources => [...], agents => [...], sinks => [...] }.
sub parse {
    my ($class, $text) = @_;
    my %pipeline;
    my @blocks;
    my ($current_type, $current_name, %current_props);

    for my $line (split /\n/, $text) {
        $line =~ s/\s*$//;
        # Strip trailing comments: skip # inside quoted strings.
        my $out = '';
        my $in_quote = 0;
        for my $ch (split //, $line) {
            if ($ch eq '"') { $in_quote = !$in_quote }
            last if $ch eq '#' && !$in_quote;
            $out .= $ch;
        }
        $line = $out;
        $line =~ s/\s+$//;
        $line =~ s/^\s+//;
        next unless length $line;

        # End of block.
        if ($line eq ']') {
            if (defined $current_type) {
                my $block = { type => $current_type, name => $current_name, %current_props };
                push @blocks, $block;
                $pipeline{name} = $current_name if $current_type eq 'Pipeline';
                $pipeline{about} = $current_props{about} // '' if $current_type eq 'Pipeline';
            }
            ($current_type, $current_name, %current_props) = (undef, undef, ());
            next;
        }

        # Block start: TypeName[
        if ($line =~ /^(\w+)\[$/) {
            $current_type = $1;
            $current_name = '';
            %current_props = ();
            next;
        }

        # Property: name("value") or subscribe("topic") etc.
        if ($line =~ /^(\w+)\("([^"]*)"\)$/ && defined $current_type) {
            my ($key, $val) = ($1, $2);
            if ($key eq 'name') {
                $current_name = $val;
            } elsif ($key eq 'subscribe') {
                # Multi-value: collect into arrayref.
                $current_props{$key} //= [];
                push @{ $current_props{$key} }, $val;
            } else {
                $current_props{$key} = $val;
            }
            next;
        }
    }

    # Categorize blocks (skip Pipeline metadata block).
    for my $b (@blocks) {
        next if $b->{type} eq 'Pipeline';
        if ($b->{type} eq 'Source') {
            push @{ $pipeline{sources} }, $b;
        } elsif ($b->{type} eq 'Agent') {
            push @{ $pipeline{agents} }, $b;
        } elsif ($b->{type} eq 'Sink') {
            push @{ $pipeline{sinks} }, $b;
        }
    }

    $pipeline{sources} //= [];
    $pipeline{agents}   //= [];
    $pipeline{sinks}    //= [];

    return \%pipeline;
}

# Load a named pipeline from the pipelines directory.
sub load {
    my ($class, $name) = @_;
    my $dir = $class->pipeline_dir;
    my $path = "$dir/$name.clank";
    return undef unless -f $path;
    open my $fh, '<', $path or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $class->parse($text);
}

# List available pipeline names.
sub list {
    my ($class) = @_;
    my $dir = $class->pipeline_dir;
    opendir my $dh, $dir or return ();
    my @names = sort map { s/\.clank$//r } grep { /\.clank$/ } readdir $dh;
    closedir $dh;
    return @names;
}

# Run a parsed pipeline. Returns { ok, output }.
# Wiring: Source publishes → Bus delivers to subscribed Agents → Sink collects.
sub run {
    my ($class, $pipeline, %args) = @_;
    my $app = $args{app} or die "Pipeline::run requires app\n";
    my $bus = $app->bus;

    my $output = '';
    my @subs;

    # Wire Sinks: subscribe to their topic, collect output.
    for my $sink (@{ $pipeline->{sinks} // [] }) {
        my $topic = $sink->{subscribe} // $sink->{topic};
        next unless $topic;
        my $sub_id = $bus->subscribe($topic, sub {
            my ($ev) = @_;
            $output .= ref $ev->{payload} eq 'HASH'
                ? ($ev->{payload}{text} // $ev->{payload}{output} // Clank::Util::jencode($ev->{payload}))
                : ($ev->{payload} // '');
        }, name => "pipeline_sink_$sink->{name}");
        push @subs, $sub_id;
    }

    # Wire Agents: subscribe to input, call tool, publish output.
    for my $agent (@{ $pipeline->{agents} // [] }) {
        my $sub_topics = $agent->{subscribe};
        $sub_topics = [$sub_topics] if defined $sub_topics && !ref $sub_topics;
        my $pub_topic = $agent->{publish};
        next unless $sub_topics && $pub_topic;

        for my $topic (@$sub_topics) {
            my $sub_id = $bus->subscribe($topic, sub {
                my ($ev) = @_;
                my $input = ref $ev->{payload} eq 'HASH'
                    ? ($ev->{payload}{text} // $ev->{payload}{output} // Clank::Util::jencode($ev->{payload}))
                    : ($ev->{payload} // '');

                # Call the agent's tool via the LLM.
                my $tool = $agent->{tool} // '';
                my $wit  = $agent->{wit} // '';
                my $prompt = "Pipeline stage '$agent->{name}' ($wit/$tool):\n\n$input";
                my $resp = eval { $app->run_prompt($prompt) };

                my $result = '';
                if ($resp->{ok}) {
                    my $leaf = $app->store->get_message(
                        $app->store->leaf_message($app->session->id));
                    if ($leaf && $leaf->{role} eq 'assistant' && ref $leaf->{content} eq 'HASH') {
                        $result = $leaf->{content}{text} // '';
                    }
                } else {
                    $result = "pipeline error in $agent->{name}: " . ($resp->{error} // 'unknown');
                }

                $bus->publish($pub_topic, { text => $result, source => $agent->{name} });
            }, name => "pipeline_agent_$agent->{name}_$topic");
            push @subs, $sub_id;
        }
    }

    # Fire Sources: publish initial events.
    for my $source (@{ $pipeline->{sources} // [] }) {
        my $topic = $source->{topic};
        next unless $topic;
        my $payload = $args{payload} // { text => $args{input} // '' };
        $bus->publish($topic, $payload);
    }

    # Brief wait for synchronous bus delivery.
    select(undef, undef, undef, 0.2);

    # Unsubscribe all wiring.
    $bus->unsubscribe($_) for @subs;

    return { ok => 1, output => $output };
}

# Parse and run an inline pipe: "stage1 | stage2 | stage3"
# Each stage is an LLM call. Output feeds into next stage.
sub run_inline {
    my ($class, $text, %args) = @_;
    my $app = $args{app} or die "Pipeline::run_inline requires app\n";

    my @stages = split /\s*\|\s*/, $text;
    return { ok => 0, error => 'empty pipeline' } unless @stages;

    my $input = $args{input} // '';
    my @outputs;

    for my $stage (@stages) {
        $stage =~ s/^\s+|\s+$//g;
        next unless length $stage;

        my $prompt = length $input
            ? "Pipeline stage '$stage'. Input:\n\n$input\n\nProcess this according to: $stage"
            : "$stage";

        my $resp = eval { $app->run_prompt($prompt) };
        my $output = '';
        if ($resp->{ok}) {
            my $leaf = $app->store->get_message(
                $app->store->leaf_message($app->session->id));
            if ($leaf && $leaf->{role} eq 'assistant' && ref $leaf->{content} eq 'HASH') {
                $output = $leaf->{content}{text} // '';
            }
        } else {
            $output = "pipeline error at stage '$stage': " . ($resp->{error} // 'unknown');
        }

        push @outputs, { stage => $stage, output => $output };
        $input = $output;
    }

    return {
        ok      => 1,
        output  => $input,
        stages  => \@outputs,
    };
}

1;
