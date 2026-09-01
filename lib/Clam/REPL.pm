# Interactive REPL (Term::ReadLine, no TUI) on top of Clam::App.
package Clam::REPL;
use strict;
use warnings;
use Term::ReadLine;
use Clam qw(version);
use Clam::Util qw(jencode);
use Clam::App;

sub new { my ($class, %o) = @_; return bless { %o }, $class }

sub run {
    my ($self) = @_;
    my $app     = Clam::App->new(%$self);
    my $session = $app->start_session(resume => $self->{resume});

    # live output: streaming deltas + tool activity
    $app->bus->subscribe('message_update', sub {
        my ($ev) = @_;
        print $ev->{payload}{delta}{text} if defined $ev->{payload}{delta}{text};
    }, name => 'repl.stream');
    $app->bus->subscribe('tool_execution_start', sub {
        my ($ev) = @_;
        my $p = $ev->{payload};
        printf "\n[tool] %s(%s)\n", $p->{name}, substr(jencode($p->{input} // {}), 0, 120);
    }, name => 'repl.tools');

    # banner
    print "clam v" . version() . " — ", $app->provider->log_safe, "\n";
    printf "db: %s | session: %s\n", $app->store->path, $session->id;
    my @wits = $app->wits;
    if (@wits) {
        print "wits: ", join(', ', map { $_->{name} } @wits), "\n";
    } else {
        print "wits: (none loaded)\n";
    }
    warn "[wits] load errors:\n  $_\n" for @{ $app->pm->errors };
    print "type /help for commands\n";

    my $term = Term::ReadLine->new('clam');
    while (1) {
        my $line = $term->read('clam> ');
        last unless defined $line;
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;
        $term->addhistory($line);

        if ($line eq '/exit' || $line eq '/quit') { last }
        elsif ($line eq '/help')     { $self->_help($app) }
        elsif ($line eq '/new')      {
            $session = $app->start_session();
            print "new session ", $session->id, "\n";
        }
        elsif ($line eq '/sessions') { $self->_list_sessions($app) }
        elsif ($line =~ m{^/resume\s+(\S+)$}) {
            my $rid = $1;
            die "no such session: $rid\n" unless $app->store->get_session($rid);
            $session = $app->start_session(resume => $rid);
            print "resumed ", $rid, "\n";
        }
        elsif ($line =~ m{^/compact(?:\s+(.*))?$}) {
            my $cid = eval {
                $app->compactor->compact(
                    store => $app->store, session_id => $session->id,
                    provider => $app->provider, bus => $app->bus, instructions => $1,
                );
            };
            if ($@)      { print "compaction failed: $@" }
            elsif ($cid) { print "compacted (entry $cid)\n" }
            else         { print "nothing to compact\n" }
        }
        elsif ($line eq '/wits')     {
            my @ws = $app->wits;
            printf "%-20s %s  (%s)\n", $_->{name}, $_->{pkg}, $_->{dir} for @ws;
            print "(none loaded)\n" unless @ws;
        }
        elsif ($line eq '/tools')    {
            print join(', ', map { $_->{name} } $session->tools), "\n";
        }
        elsif ($line eq '/model' || $line eq '/providers') {
            require Clam::Providers;
            print "active: ", $app->provider->log_safe, "\n";
            print "known:  ", join(', ', Clam::Providers::known()), "\n";
        }
        elsif ($line =~ m{^/events(?:\s+(\S+))?$}) {
            my %q = (limit => 20);
            $q{topic} = $1 if defined $1;
            for my $e (@{ $app->store->query_events(%q) }) {
                printf "%s  %-28s  %s\n", scalar localtime(($e->{created_at} // 0) / 1000),
                    $e->{topic}, substr(jencode($e->{payload}), 0, 80);
            }
        }
        elsif (my $cmd = $self->_wit_command($app, $line)) {
            my ($name, $args) = ($cmd->{name}, $cmd->{args});
            my $res = eval {
                $cmd->{handler}->({ bus => $app->bus, store => $app->store, session => $session }, $args);
            };
            if ($@) { print "command /$name failed: $@" }
            elsif (defined $res && length "$res") { print "$res\n" }
        }
        else {
            my $result = eval { $app->run_prompt($line) };
            if ($@) { print "error: $@"; next }
            if ($result->{handled}) {
                print "$result->{output}\n" if defined $result->{output};
                next;
            }
            unless ($result->{ok}) { print "agent error: $result->{error}\n"; next }
            unless ($self->{stream}) {
                my $leaf = $app->store->get_message($app->store->leaf_message($session->id));
                if ($leaf && (($leaf->{role} // '') eq 'assistant') && ref $leaf->{content} eq 'HASH') {
                    print "\n", $leaf->{content}{text}, "\n" if length($leaf->{content}{text} // '');
                }
            } else {
                print "\n";
            }
        }
    }

    $app->shutdown;
    print "bye\n";
}

# ---------------------------------------------------------------------------
sub _wit_command {
    my ($self, $app, $line) = @_;
    return undef unless $line =~ m{^/(\S+)(?:\s+(.*))?$};
    my ($name, $args) = ($1, $2 // '');
    my %cmds = %{ $app->pm->all_commands };
    return undef unless exists $cmds{$name};
    # Return a real hashref (an arrayref abused as a hash is fragile).
    return { name => $name, args => $args, %{ $cmds{$name} } };
}

sub _list_sessions {
    my ($self, $app) = @_;
    for my $s (@{ $app->store->list_sessions(limit => 15) }) {
        printf "%s  %-40s  %s\n", substr($s->{id}, 0, 8), $s->{title} // '(untitled)',
            scalar localtime(($s->{updated_at} // 0) / 1000);
    }
}

sub _help {
    my ($self, $app) = @_;
    print <<'EOF';
commands:
  /help              this help
  /new               start a new session
  /sessions          list recent sessions
  /resume <id>       resume a session
  /compact [text]    compact the conversation now (optional instructions)
  /wits              list loaded wits
  /tools             list available tools
  /model             show active provider/model + known providers
  /events [topic]    peek at the blackboard journal (last 20)
  /exit, /quit       leave
EOF
    my %cmds = %{ $app->pm->all_commands };
    if (%cmds) {
        print "wit commands:\n";
        printf "  /%-16s %s\n", $_, ($cmds{$_}{description} // '') for sort keys %cmds;
    }
}

1;
