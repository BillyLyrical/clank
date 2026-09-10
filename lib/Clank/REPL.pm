# Interactive REPL (Term::ReadLine, no TUI) on top of Clank::App.
# Pure interface layer: reads input, dispatches commands, displays output.
# Command dispatch uses Clank::Sigil — the same parser shared with clankd.
package Clank::REPL;
use strict;
use warnings;
use Term::ReadLine;
use Clank qw(version);
use Clank::Util qw(jencode);
use Clank::App;

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
    my $app = Clank::App->new(%$self);
    $app->start_session(resume => $self->{resume});

    # Create sigil dispatcher and register handlers.
    require Clank::Sigil;
    my $sigil = Clank::Sigil->new(app => $app);
    $self->_register_handlers($sigil, $app);

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
    print "clank v" . version() . " — ", $app->provider->log_safe, "\n";
    printf "db: %s | session: %s\n", $app->store->path, $app->session->id;
    my @wits = $app->wits;
    if (@wits) {
        print "wits: ", join(', ', map { $_->{name} } @wits), "\n";
    } else {
        print "wits: (none loaded)\n";
    }
    warn "[wits] load errors:\n  $_\n" for @{ $app->pm->errors };
    print "type /help for commands\n";

    my $term = Term::ReadLine->new('clank');
    while (1) {
        my $line = $term->read('clank> ');
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

        # Sigil dispatch: parse first character, route to handler.
        my $result = $sigil->dispatch($line);
        if ($result) {
            if (ref $result eq 'HASH' && $result->{exit}) {
                last;
            }
            if (defined $result->{output} && length "$result->{output}") {
                print "$result->{output}\n";
            }
            next;
        }

        # No sigil match: send to agent loop (bare text = LLM prompt).
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
# Register sigil handlers. Each handler receives ($app, $content) and
# returns {output => '...'} or undef.
sub _register_handlers {
    my ($self, $sigil, $app) = @_;

    # / — Command: delegate to wit-registered command handlers.
    $sigil->register('/', sub {
        my ($app, $args) = @_;
        my ($name, $rest) = $args =~ /^(\S+)(?:\s+(.*))?$/;
        return { output => "usage: /<command> [args]" } unless defined $name;
        my %cmds = %{ $app->pm->all_commands };
        return { output => "unknown command: /$name" } unless exists $cmds{$name};
        my $cmd = $cmds{$name};
        my $res = eval {
            $cmd->{handler}->({
                bus     => $app->bus,
                store   => $app->store,
                session => $app->session,
                app     => $app,
            }, $rest // '');
        };
        if ($@) { return { output => "command /$name failed: $@" } }
        if (ref $res eq 'HASH') { return $res }
        return { output => defined $res ? "$res" : undef };
    });

    # # — Comment: no-op.
    $sigil->register('#', sub { { output => '' } });

    # ? — Query: informational LLM query (stub).
    $sigil->register('?', sub {
        my ($app, $args) = @_;
        return { output => 'usage: ? <question>' } unless length $args;
        return { output => "(query mode not yet implemented: $args)" };
    });

    # $ — Eval: Perl expression (stub).
    $sigil->register('$', sub {
        my ($app, $args) = @_;
        return { output => 'usage: $ <perl expression>' } unless length $args;
        return { output => "(eval mode not yet implemented: $args)" };
    });

    # @ — Agent: agent dispatch (stub).
    $sigil->register('@', sub {
        my ($app, $args) = @_;
        return { output => "(agent mode not yet implemented: $args)" };
    });

    # % — Pipeline: run named pipeline (stub).
    $sigil->register('%', sub {
        my ($app, $args) = @_;
        return { output => "(pipeline mode not yet implemented: $args)" };
    });

    # > — Pipe: inline pipeline (stub).
    $sigil->register('>', sub {
        my ($app, $args) = @_;
        return { output => "(pipe mode not yet implemented: $args)" };
    });

    # : — Topic: bus publish/subscribe (stub).
    $sigil->register(':', sub {
        my ($app, $args) = @_;
        return { output => "(topic mode not yet implemented: $args)" };
    });

    # ~ — Wit: wit management (stub).
    $sigil->register('~', sub {
        my ($app, $args) = @_;
        return { output => "(wit mode not yet implemented: $args)" };
    });

    # ! — History: re-run previous command (stub).
    $sigil->register('!', sub {
        my ($app, $args) = @_;
        return { output => "(history mode not yet implemented: $args)" };
    });
}

1;
