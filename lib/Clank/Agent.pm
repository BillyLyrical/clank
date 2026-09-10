# Named agent profiles: load TOML+Markdown, spawn constrained subagents.
package Clank::Agent;
use strict;
use warnings;
use File::Basename ();

my $AGENT_DIR;

# Common stop words to exclude from TF scoring.
my %STOP = map { $_ => 1 } qw(
    the a an is are was were be been am do does did have has had
    will would shall should may might can could of in to for on
    with at by from as into through during before after above below
    between out off over under again further then once here there when
    where why how all each every both few more most other some such
    no nor not only own same so than too very that this these those
    and but or if because until while it its i me my we our you your
    he him his she her they them their what which who whom
);

sub agent_dir {
    my ($class, $dir) = @_;
    $AGENT_DIR = $dir if defined $dir;
    return $AGENT_DIR // File::Basename::dirname(__FILE__) . '/../../agents';
}

# Load an agent profile by name. Returns undef if not found.
# Profile = { name, description, model, tools, max_turns, prompt, delegate_to }
sub load {
    my ($class, $name) = @_;
    my $dir = $class->agent_dir;
    my $toml_path = "$dir/$name.toml";
    my $md_path   = "$dir/$name.md";
    return undef unless -f $toml_path;

    my $meta = $class->_parse_toml(_slurp($toml_path));
    $meta->{prompt} = -f $md_path ? _slurp($md_path) : '';
    $meta->{name}   = $name unless defined $meta->{name};
    return $meta;
}

# List available agent profile names.
sub list {
    my ($class) = @_;
    my $dir = $class->agent_dir;
    opendir my $dh, $dir or return ();
    my @names = sort map { s/\.toml$//r } grep { /\.toml$/ } readdir $dh;
    closedir $dh;
    return @names;
}

# Get metadata for all agents (for routing/display).
sub metadata {
    my ($class) = @_;
    return [ map { $class->load($_) } $class->list ];
}

# Route a prompt to the best-matching agent profile using TF scoring.
# Returns { name, score } or undef if no profile scores above threshold.
sub route {
    my ($class, $prompt) = @_;
    my @profiles = map { $class->load($_) } $class->list;
    return undef unless @profiles;

    my @prompt_tokens = _tokenize($prompt);
    return undef unless @prompt_tokens;
    my %prompt_tf;
    $prompt_tf{$_}++ for @prompt_tokens;

    my ($best_name, $best_score);
    for my $p (@profiles) {
        my @desc_tokens = _tokenize($p->{description} // '');
        next unless @desc_tokens;
        my %desc_tf;
        $desc_tf{$_}++ for @desc_tokens;

        # Score = sum of min(prompt_tf, desc_tf) for shared tokens.
        my $score = 0;
        for my $t (keys %prompt_tf) {
            next unless $desc_tf{$t};
            $score += ($prompt_tf{$t} < $desc_tf{$t} ? $prompt_tf{$t} : $desc_tf{$t});
        }
        # Normalize by description length to avoid bias toward short descriptions.
        $score /= scalar @desc_tokens if @desc_tokens;

        if (!defined $best_score || $score > $best_score) {
            $best_score = $score;
            $best_name  = $p->{name};
        }
    }

    # Require minimum signal — don't route on noise.
    return undef if !defined $best_score || $best_score < 0.1;
    return { name => $best_name, score => $best_score };
}

# Spawn a subagent with a named profile via the parent loop.
# Args: name (profile), prompt (task), loop (parent Clank::Loop),
#       max_turns (override), model (override).
sub spawn {
    my ($class, %args) = @_;
    my $name   = $args{name}   or die "Agent::spawn requires name\n";
    my $prompt = $args{prompt} or die "Agent::spawn requires prompt\n";
    my $loop   = $args{loop}   or die "Agent::spawn requires loop\n";

    my $profile = $class->load($name);
    die "unknown agent profile: $name\n" unless $profile;

    my $store = $loop->{session}{store};
    my $bus   = $loop->_bus;
    my $parent = $loop->{session};

    # Resolve model: profile default, overridden by caller.
    my $model = $args{model} // $profile->{model};

    # Create child provider if agent specifies a different model.
    my $provider = $parent->{provider};
    if (defined $model && $model ne ($provider->{model} // '')) {
        $provider = bless { %$provider, model => $model }, ref($provider);
    }

    # Create child session.
    require Clank::Session;
    my $child = Clank::Session->new(
        store    => $store,
        bus      => $bus,
        provider => $provider,
        name     => "agent_$name",
    );

    # Copy all tools from parent, then apply allowlist filter.
    for my $tool ($parent->tools) {
        $child->add_tool($tool);
    }
    if ($profile->{tools} && @{$profile->{tools}}) {
        $child->set_tool_filter($profile->{tools});
    }

    # Build agent-specific system prompt: base + agent instructions.
    my $base_prompt = $parent->system_prompt;
    my $agent_prompt = $profile->{prompt} // '';
    my $full_prompt = $base_prompt . "\n\n" . $agent_prompt;

    # Anti-injection hook: let wits prepend defense instructions.
    my $defense = $bus->publish('agent_prompt_defense', {
        agent  => $name,
        prompt => $full_prompt,
    });
    if ($defense && ref $defense eq 'HASH' && $defense->{prepend}) {
        $full_prompt = $defense->{prepend} . "\n\n" . $full_prompt;
    }

    $child->set_system_prompt($full_prompt);

    # Copy skills and context files.
    $child->{skills}        = [ @{ $parent->{skills}        // [] } ];
    $child->{context_files} = [ @{ $parent->{context_files} // [] } ];

    # Publish pre_agent_start lifecycle event (before loop runs).
    $bus->publish('pre_agent_start', {
        parent_session_id => $parent->id,
        child_session_id  => $child->id,
        agent             => $name,
        model             => $provider->{model},
    });

    $bus->publish('subagent_start', {
        parent_session_id => $parent->id,
        child_session_id  => $child->id,
        prompt            => $prompt,
        agent             => $name,
    });

    # Create and run child loop.
    my $child_loop = ref($loop)->new(
        session   => $child,
        stream    => 0,
        max_turns => $args{max_turns} // $profile->{max_turns} // 30,
        governor  => $loop->{governor},
        tracer    => $loop->{tracer},
        cache     => $loop->{cache},
        metrics   => $loop->{metrics},
    );

    my $result = $child_loop->run_prompt($prompt);

    # Publish completion events.
    $bus->publish('subagent_stop', {
        parent_session_id => $parent->id,
        child_session_id  => $child->id,
        ok                => $result->{ok},
        turns             => $result->{turns},
        error             => $result->{error},
        agent             => $name,
    });

    $bus->publish('agent_end', {
        parent_session_id => $parent->id,
        child_session_id  => $child->id,
        ok                => $result->{ok},
        turns             => $result->{turns},
        error             => $result->{error},
        agent             => $name,
        model             => $provider->{model},
    });

    # Record invocation stats.
    $class->_record_stat($name, $result->{ok}, $result->{turns});

    # Extract output.
    my $output = '';
    if ($result->{ok}) {
        my $leaf = $store->get_message($store->leaf_message($child->id));
        if ($leaf && $leaf->{role} eq 'assistant' && ref $leaf->{content} eq 'HASH') {
            $output = $leaf->{content}{text} // '';
        }
    }

    return {
        ok         => $result->{ok},
        output     => $output,
        session_id => $child->id,
        turns      => $result->{turns},
        error      => $result->{error},
        agent      => $name,
        model      => $provider->{model},
    };
}

# Delegate to another agent from within an agent's execution.
# Publishes agent_delegate event and spawns the target agent.
# Returns the delegate's result hashref.
sub delegate {
    my ($class, %args) = @_;
    my $from   = $args{from}   or die "Agent::delegate requires from\n";
    my $to     = $args{to}     or die "Agent::delegate requires to\n";
    my $prompt = $args{prompt} or die "Agent::delegate requires prompt\n";
    my $loop   = $args{loop}   or die "Agent::delegate requires loop\n";

    my $bus = $loop->_bus;
    $bus->publish('agent_delegate', {
        from_agent => $from,
        to_agent   => $to,
        prompt     => $prompt,
    });

    return $class->spawn(name => $to, prompt => $prompt, loop => $loop);
}

# Invocation statistics. Returns hashref: { $name => { calls, ok, errors, turns } }.
my %STATS;

sub stats {
    my ($class) = @_;
    return { %STATS };
}

sub _record_stat {
    my ($class, $name, $ok, $turns) = @_;
    $STATS{$name} //= { calls => 0, ok => 0, errors => 0, turns => 0 };
    $STATS{$name}{calls}++;
    $STATS{$name}{ok}++ if $ok;
    $STATS{$name}{errors}++ unless $ok;
    $STATS{$name}{turns} += $turns;
}

# Compliance test: spawn an agent and verify only allowed tools were called.
# Args: name (profile), prompt (test scenario), loop, bus (to spy on tool_use).
# Returns: { compliant, allowed_tools, used_tools, violations }.
sub comply {
    my ($class, %args) = @_;
    my $name   = $args{name}   or die "Agent::comply requires name\n";
    my $prompt = $args{prompt} or die "Agent::comply requires prompt\n";
    my $loop   = $args{loop}   or die "Agent::comply requires loop\n";
    my $bus    = $args{bus}    or die "Agent::comply requires bus\n";

    my $profile = $class->load($name);
    die "unknown agent: $name\n" unless $profile;

    my %allowed = map { $_ => 1 } @{ $profile->{tools} // [] };
    my %used;

    # Spy on tool_use events to record which tools were called.
    my $sub_id = $bus->subscribe('tool_use', sub {
        my $tool = $_[0]{payload}{tool_name} // '';
        $used{$tool}++ if $tool;
    }, name => "comply_spy_$name");

    my $result = $class->spawn(
        name   => $name,
        prompt => $prompt,
        loop   => $loop,
    );

    $bus->unsubscribe($sub_id);

    my @violations;
    for my $tool (keys %used) {
        push @violations, $tool unless $allowed{$tool};
    }

    return {
        compliant    => scalar(@violations) == 0,
        allowed_tools => [ sort keys %allowed ],
        used_tools    => [ sort keys %used ],
        violations    => \@violations,
        ok            => $result->{ok},
        turns         => $result->{turns},
    };
}

# Tokenize text for TF scoring. Lowercase, split on non-word, drop stop words.
sub _tokenize {
    my ($text) = @_;
    return () unless defined $text;
    my @tokens = grep { length($_) >= 2 && !$STOP{$_} } split /[^a-z0-9]+/i, lc($text);
    return @tokens;
}

# Read file contents (avoids File::Slurp interference with tool namespace).
sub _slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

# Minimal TOML parser for agent frontmatter.
# Handles: key = "string", key = number, key = ["array"].
sub _parse_toml {
    my ($class, $text) = @_;
    my %result;
    for my $line (split /\n/, $text) {
        $line =~ s/\s*#.*//;          # strip comments
        $line =~ s/^\s+|\s+$//g;      # trim
        next unless $line =~ /^(\w+)\s*=\s*(.+)$/;
        my ($key, $val) = ($1, $2);
        if ($val =~ /^\[(.*)\]$/) {
            # Array of strings: ["a", "b"]
            my @items = map { s/^[\s"]+|[\s"]+$//gr } split /,/, $1;
            $result{$key} = \@items;
        } elsif ($val =~ /^"(.*)"$/) {
            $result{$key} = $1;
        } elsif ($val =~ /^\d+$/) {
            $result{$key} = int($val);
        } else {
            $result{$key} = $val;
        }
    }
    return \%result;
}

1;
