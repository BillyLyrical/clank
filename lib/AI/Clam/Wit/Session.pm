# CLAM-WIT: name=Session
# CLAM-WIT: version=1.0
# CLAM-WIT: about=Core REPL commands: session management, help, tools, events
# CLAM-WIT: usage=Loaded automatically by AI::Clam::App. Ships with the harness.
# CLAM-WIT: hint=REPL commands: /help, /new, /sessions, /resume, /compact, /wits, /tools, /model, /events, /exit
# CLAM-WIT: author=clam
# CLAM-WIT: license=Artistic-2.0
package AI::Clam::Wit::Session;
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

    $api->register_command('wits', description => 'list loaded wits (with state)', handler => sub {
        my ($ctx) = @_;
        my @ws = $ctx->{app}->wits;
        unless (@ws) { return "(none loaded)" }
        my @out;
        for my $w (@ws) {
            push @out, sprintf("%-20s %-9s %s  (%s)",
                $w->{name}, $w->{state} // 'active', $w->{dir}, $w->{pkg});
        }
        return join("\n", @out);
    });

    $api->register_command('tools', description => 'list available tools', handler => sub {
        my ($ctx) = @_;
        return join(', ', sort map { $_->{name} } $ctx->{app}->session->tools);
    });

    $api->register_command('model', description => 'show active provider/model + known providers', handler => sub {
        my ($ctx) = @_;
        require AI::Clam::Providers;
        my $out  = "active: " . $ctx->{app}->provider->log_safe . "\n";
        $out    .= "known:  " . join(', ', AI::Clam::Providers::known());
        return $out;
    });

    $api->register_command('events', description => 'peek at the blackboard journal (last 20)', handler => sub {
        my ($ctx, $args) = @_;
        require AI::Clam::Util;
        my %q = (limit => 20);
        $q{topic} = $args if defined $args && length $args;
        my @out;
        for my $e (@{ $ctx->{store}->query_events(%q) }) {
            push @out, sprintf("%s  %-28s  %s",
                scalar localtime(($e->{created_at} // 0) / 1000),
                $e->{topic},
                substr(AI::Clam::Util::jencode($e->{payload}), 0, 80));
        }
        return join("\n", @out) || '(no events)';
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

    for my $name (qw(exit quit)) {
        $api->register_command($name, description => 'leave', handler => sub {
            my ($ctx) = @_;
            $ctx->{app}->shutdown;
            return { exit => 1 };
        });
    }
}

1;
