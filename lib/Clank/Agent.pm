# Named agent profiles: load TOML+Markdown, spawn constrained subagents.
package Clank::Agent;
use strict;
use warnings;
use File::Basename ();

my $AGENT_DIR;

sub agent_dir {
    my ($class, $dir) = @_;
    $AGENT_DIR = $dir if defined $dir;
    return $AGENT_DIR // File::Basename::dirname(__FILE__) . '/../../agents';
}

# Load an agent profile by name. Returns undef if not found.
# Profile = { name, description, model, tools, max_turns, prompt, raw_toml }
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
    $child->set_system_prompt($base_prompt . "\n\n" . $agent_prompt);

    # Copy skills and context files.
    $child->{skills}        = [ @{ $parent->{skills}        // [] } ];
    $child->{context_files} = [ @{ $parent->{context_files} // [] } ];

    # Publish lifecycle event.
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

    # Publish completion event.
    $bus->publish('subagent_stop', {
        parent_session_id => $parent->id,
        child_session_id  => $child->id,
        ok                => $result->{ok},
        turns             => $result->{turns},
        error             => $result->{error},
        agent             => $name,
    });

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
