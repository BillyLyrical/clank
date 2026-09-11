# CLANK-WIT: name=Session
# CLANK-WIT: version=1.0
# CLANK-WIT: about=Core REPL commands: session management, help, tools, events
# CLANK-WIT: usage=Loaded automatically by Clank::App. Ships with the harness.
# CLANK-WIT: hint=REPL commands: /help, /new, /sessions, /resume, /compact, /wits, /tools, /model, /events, /agents, /agent, /exit
# CLANK-WIT: author=clank
# CLANK-WIT: license=Artistic-2.0
package Clank::Wit::Session;
use strict;
use warnings;

sub new { bless { wit_name => 'session' }, shift }

sub register {
    my ($self, $api) = @_;

    $api->register_command('help', description => 'list all commands', handler => sub {
        my ($ctx) = @_;
        my %cmds = %{ $ctx->{app}->pm->all_commands };
        my $out = "commands:\n";
        for my $name (sort keys %cmds) {
            $out .= sprintf "  /%-18s %s\n", $name, ($cmds{$name}{description} // '');
        }
        return $out;
    });

    $api->register_command('new', description => 'start a new session', handler => sub {
        my ($ctx) = @_;
        $ctx->{app}->start_session();
        return "new session " . $ctx->{app}->session->id;
    });

    $api->register_command('sessions', description => 'list recent sessions', handler => sub {
        my ($ctx) = @_;
        my @out;
        for my $s (@{ $ctx->{store}->list_sessions(limit => 15) }) {
            push @out, sprintf("%s  %-40s  %s",
                substr($s->{id}, 0, 8),
                $s->{title} // '(untitled)',
                scalar localtime(($s->{updated_at} // 0) / 1000));
        }
        return join("\n", @out) || '(no sessions)';
    });

    $api->register_command('resume', description => 'resume a session by id', handler => sub {
        my ($ctx, $args) = @_;
        my $rid = $args;
        return "usage: /resume <id>" unless defined $rid && length $rid;
        die "no such session: $rid\n" unless $ctx->{store}->get_session($rid);
        $ctx->{app}->start_session(resume => $rid);
        return "resumed $rid";
    });

    $api->register_command('compact', description => 'compact the conversation (optional instructions)', handler => sub {
        my ($ctx, $args) = @_;
        my $session = $ctx->{app}->session;
        my $cid = eval {
            $ctx->{app}->compactor->compact(
                store => $ctx->{store}, session_id => $session->id,
                provider => $ctx->{app}->provider, bus => $ctx->{app}->bus,
                instructions => $args,
            );
        };
        if ($@)      { return "compaction failed: $@" }
        elsif ($cid) { return "compacted (entry $cid)" }
        else         { return "nothing to compact" }
    });

    $api->register_command('wits', description => 'list all discovered wits (DB registry)', handler => sub {
        my ($ctx) = @_;
        my @ws = $ctx->{app}->store->wit_list;
        unless (@ws) { return "(no wits discovered)" }
        my @out;
        for my $w (@ws) {
            push @out, sprintf("%-20s %-9s %s",
                $w->{name}, $w->{state} // 'available', $w->{path} // '');
        }
        return "wits (" . scalar(@ws) . "):\n" . join("\n", @out);
    });

    $api->register_command('tools', description => 'list available tools', handler => sub {
        my ($ctx) = @_;
        return join(', ', sort map { $_->{name} } $ctx->{app}->session->tools);
    });

    $api->register_command('model', description => 'show active provider/model + known providers', handler => sub {
        my ($ctx) = @_;
        require Clank::Providers;
        my $out  = "active: " . $ctx->{app}->provider->log_safe . "\n";
        $out    .= "known:  " . join(', ', Clank::Providers::known());
        return $out;
    });

    $api->register_command('events', description => 'peek at the blackboard journal (last 20)', handler => sub {
        my ($ctx, $args) = @_;
        require Clank::Util;
        my %q = (limit => 20);
        $q{topic} = $args if defined $args && length $args;
        my @out;
        for my $e (@{ $ctx->{store}->query_events(%q) }) {
            push @out, sprintf("%s  %-28s  %s",
                scalar localtime(($e->{created_at} // 0) / 1000),
                $e->{topic},
                substr(Clank::Util::jencode($e->{payload}), 0, 80));
        }
        return join("\n", @out) || '(no events)';
    });

    $api->register_command('stats', description => 'self-improvement metrics: automation ratio, escalation breakdown', handler => sub {
        my ($ctx) = @_;
        my $metrics = $ctx->{app}->metrics;
        unless ($metrics) {
            return "metrics not available (no metrics module loaded)";
        }
        my $s = $metrics->self_stats;
        my $ratio = $s->{automation_ratio};
        my $e = $s->{escalation};

        my $out = "=== Self-Improvement Metrics ===\n\n";
        $out .= sprintf("  Automation ratio:  %.1f%% (%d escalated / %d total)\n",
            $ratio * 100, $s->{total_escalated}, $s->{total_calls});
        $out .= "\n  Escalation breakdown:\n";
        $out .= sprintf("    Crystallized rules:  %d hits\n", $e->{rule_hit});
        $out .= sprintf("    World model facts:   %d hits\n", $e->{wm_hit});
        $out .= sprintf("    Rules engine:        %d hits\n", $e->{engine_hit});
        $out .= sprintf("    LLM fallback:        %d calls\n", $e->{llm_fallback});
        $out .= sprintf("    Rules crystallized:  %d new\n", $e->{crystallized});
        $out .= "\n  The higher the automation ratio, the less you pay for LLM calls.\n";
        return $out;
    });

    $api->register_command('wit', description => 'manage wits: /wit disable|enable NAME', handler => sub {
        my ($ctx, $args) = @_;
        if ($args =~ m{^(disable|enable)\s+(\S+)$}) {
            my ($action, $name) = ($1, $2);
            my $method = $action eq 'disable' ? 'disable_wit' : 'enable_wit';
            return $ctx->{app}->pm->$method($name);
        }
        return "usage: /wit disable|enable NAME";
    });

    $api->register_command('agents', description => 'list available agent profiles', handler => sub {
        my ($ctx) = @_;
        require Clank::Agent;
        my @names = Clank::Agent->list;
        return '(no agent profiles found)' unless @names;
        my @out;
        for my $name (@names) {
            my $p = Clank::Agent->load($name);
            push @out, sprintf("  %-16s %s  (tools: %s)",
                $p->{name}, $p->{description} // '', join(',', @{ $p->{tools} // [] }));
        }
        return "agents:\n" . join("\n", @out);
    });

    $api->register_command('agent', description => 'run an agent: /agent [--model=X] <name> <prompt>', handler => sub {
        my ($ctx, $args) = @_;
        require Clank::Agent;
        if (!defined $args || $args !~ /^(\S+)\s+(.+)$/) {
            my @names = Clank::Agent->list;
            my $list = @names ? "available: " . join(', ', @names) : '(no profiles)';
            return "usage: /agent [--model=tier] <name> <prompt>\n$list";
        }
        my ($name, $prompt) = ($1, $2);
        my %opts;
        while ($name =~ /^--(\w+)=(.+)$/) {
            $opts{$1} = $2;
            ($name, $prompt) = ($prompt =~ /^(\S+)\s+(.+)$/)
                or return "usage: /agent [--model=tier] <name> <prompt>";
        }
        my $loop = $ctx->{app}->loop;
        unless ($loop) {
            return "no active loop — start a session first";
        }
        my $result = eval {
            Clank::Agent->spawn(
                name   => $name,
                prompt => $prompt,
                loop   => $loop,
                (defined $opts{model} ? (model => $opts{model}) : ()),
            );
        };
        if ($@) { return "agent error: $@" }
        my $model_info = $result->{model} ? " model: $result->{model}" : '';
        my $out = "[$result->{agent}] turns: $result->{turns}$model_info\n\n" . ($result->{output} // '(no output)');
        return $out;
    });

    for my $name (qw(exit quit)) {
        $api->register_command($name, description => 'leave', handler => sub {
            my ($ctx) = @_;
            $ctx->{app}->shutdown;
            return { exit => 1 };
        });
    }
}

1;
