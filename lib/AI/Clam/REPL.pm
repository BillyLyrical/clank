# Interactive REPL (Term::ReadLine, no TUI) on top of AI::Clam::App.
# Pure interface layer: reads input, dispatches commands, displays output.
# All command handling lives in wits (especially AI::Clam::Wit::Session).
package AI::Clam::REPL;
use strict;
use warnings;
use Term::ReadLine;
use AI::Clam qw(version);
use AI::Clam::Util qw(jencode);
use AI::Clam::App;

sub new { my ($class, %o) = @_; return bless { %o }, $class }

# Open $EDITOR with a temp file containing optional initial text.
# Returns the edited text, or undef if the user cancelled.
sub _edit_in_editor {
    my ($initial) = @_;
    require File::Temp;
    my ($fh, $tmpfile) = File::Temp::tempfile(SUFFIX => '.pl', UNLINK => 0);
    print $fh $initial if defined $initial && length $initial;
    close $fh;
    my $editor = $ENV{EDITOR} || $ENV{VISUAL} || 'vi';
    system($editor, $tmpfile);
    open my $in, '<', $tmpfile or do { unlink $tmpfile; return undef };
    local $/;
    my $text = <$in>;
    close $in;
    unlink $tmpfile;
    return defined $text ? $text : '';
}

sub run {
    my ($self) = @_;
    my $app = AI::Clam::App->new(%$self);
    $app->start_session(resume => $self->{resume});

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
    printf "db: %s | session: %s\n", $app->store->path, $app->session->id;
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

        # Ctrl+X Ctrl+E or Alt+E: open $EDITOR for multi-line input
        if ($line eq "\x18\x05" || $line eq "\x1b\x65") {
            my $edited = _edit_in_editor();
            if (defined $edited) {
                $edited =~ s/^\n+|\n+$//g;
                next unless length $edited;
                $term->addhistory($edited);
                $line = $edited;
            } else {
                next;
            }
        }

        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;
        $term->addhistory($line);

        # Single dispatch path: all commands go through wit-registered handlers.
        my $result = $self->_dispatch($app, $line);
        if ($result) {
            if (ref $result eq 'HASH' && $result->{exit}) {
                last;
            }
            if (defined $result->{output} && length "$result->{output}") {
                print "$result->{output}\n";
            }
            next;
        }

        # Not a command: send to agent loop.
        my $resp = eval { $app->run_prompt($line) };
        if ($@) { print "error: $@"; next }
        if ($resp->{handled}) {
            print "$resp->{output}\n" if defined $resp->{output};
            next;
        }
        unless ($resp->{ok}) { print "agent error: $resp->{error}\n"; next }
        unless ($self->{stream}) {
            my $leaf = $app->store->get_message($app->store->leaf_message($app->session->id));
            if ($leaf && (($leaf->{role} // '') eq 'assistant') && ref $leaf->{content} eq 'HASH') {
                print "\n", $leaf->{content}{text}, "\n" if length($leaf->{content}{text} // '');
            }
        } else {
            print "\n";
        }
    }

    $app->shutdown;
    print "bye\n";
}

# ---------------------------------------------------------------------------
# Unified command dispatch. Parses /command [args], looks up the handler
# from all registered wit commands, calls it, returns the result.
# Returns undef when the line is not a command (agent prompt territory).
sub _dispatch {
    my ($self, $app, $line) = @_;
    return undef unless $line =~ m{^/(\S+)(?:\s+(.*))?$};
    my ($name, $args) = ($1, $2 // '');
    my %cmds = %{ $app->pm->all_commands };
    return undef unless exists $cmds{$name};
    my $cmd = $cmds{$name};
    my $res = eval {
        $cmd->{handler}->({
            bus     => $app->bus,
            store   => $app->store,
            session => $app->session,
            app     => $app,
        }, $args);
    };
    if ($@) {
        return { output => "command /$name failed: $@" };
    }
    if (ref $res eq 'HASH') {
        return $res;
    }
    return { output => defined $res ? "$res" : undef };
}

1;
