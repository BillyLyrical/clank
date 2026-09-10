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
            # History re-run: dispatch the rerun target.
            if ($result->{rerun}) {
                my $rerun = delete $result->{rerun};
                push @{ $self->{history} }, $rerun;
                my $rr = $sigil->dispatch($rerun);
                if ($rr) {
                    if (ref $rr eq 'HASH' && $rr->{exit}) { last }
                    if (defined $rr->{output} && length "$rr->{output}") { print "$rr->{output}\n" }
                    next;
                }
                # Bare text rerun: send to LLM.
                my $resp = eval { $app->run_prompt($rerun) };
                if ($@) { print "error: $@"; next }
                unless ($resp->{ok}) { print "agent error: $resp->{error}\n"; next }
                my $leaf = $app->store->get_message($app->store->leaf_message($app->session->id));
                if ($leaf && $leaf->{role} eq 'assistant' && ref $leaf->{content} eq 'HASH') {
                    print "\n", $leaf->{content}{text}, "\n" if length($leaf->{content}{text} // '');
                }
                next;
            }
            push @{ $self->{history} }, $line;
            if (ref $result eq 'HASH' && $result->{exit}) {
                last;
            }
            if (defined $result->{output} && length "$result->{output}") {
                print "$result->{output}\n";
            }
            next;
        }

        # No sigil match: send to agent loop (bare text = LLM prompt).
        push @{ $self->{history} }, $line;
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

    # ? — Query: informational LLM query (no tools).
    $sigil->register('?', sub {
        my ($app, $args) = @_;
        return { output => 'usage: ? <question>' } unless length $args;
        my $wrapped = "[Informational query — answer from your knowledge of Clank. "
                    . "Do not use tools unless explicitly asked.]\n\n$args";
        my $resp = eval { $app->run_prompt($wrapped) };
        if ($@) { return { output => "query error: $@" } }
        unless ($resp->{ok}) { return { output => "query failed: $resp->{error}" } }
        my $leaf = $app->store->get_message($app->store->leaf_message($app->session->id));
        if ($leaf && $leaf->{role} eq 'assistant' && ref $leaf->{content} eq 'HASH') {
            return { output => $leaf->{content}{text} // '' };
        }
        return { output => '(no response)' };
    });

    # $ — Eval: Perl expression in harness context.
    $sigil->register('$', sub {
        my ($app, $args) = @_;
        return { output => 'usage: $ <perl expression>' } unless length $args;
        my $store   = $app->store;
        my $bus     = $app->bus;
        my $session = $app->session;
        my $result  = eval "no warnings; $args";
        if ($@) { return { output => "eval error: $@" } }
        return { output => defined $result ? "$result" : '(undef)' };
    });

    # @ — Agent: dispatch agent operations.
    $sigil->register('@', sub {
        my ($app, $args) = @_;
        require Clank::Agent;
        my ($sub, $rest) = $args =~ /^(\S+)(?:\s+(.*))?$/;
        $sub //= '';

        if ($sub eq 'list' || $sub eq '') {
            my @names = Clank::Agent->list;
            return { output => 'usage: @list | @status | @<name> <prompt>' } unless @names;
            my @out;
            for my $name (@names) {
                my $p = Clank::Agent->load($name);
                push @out, sprintf("  %-16s %s", $p->{name}, $p->{description} // '');
            }
            return { output => "agents:\n" . join("\n", @out) };
        }

        if ($sub eq 'status') {
            my $stats = Clank::Agent->stats;
            my @out;
            for my $name (sort keys %$stats) {
                my $s = $stats->{$name};
                push @out, sprintf("  %-16s calls:%d ok:%d errors:%d turns:%d",
                    $name, $s->{calls}, $s->{ok}, $s->{errors}, $s->{turns});
            }
            return { output => @out ? "agent stats:\n" . join("\n", @out) : '(no agents invoked yet)' };
        }

        # @<name> <prompt> — run an agent.
        my $prompt = $rest // '';
        return { output => "usage: @<agent-name> <prompt>" } unless length $prompt;
        my $loop = $app->loop;
        return { output => 'no active loop — start a session first' } unless $loop;
        my $result = eval {
            Clank::Agent->spawn(name => $sub, prompt => $prompt, loop => $loop);
        };
        if ($@) { return { output => "agent error: $@" } }
        my $out = "[$result->{agent}] turns: $result->{turns}\n\n" . ($result->{output} // '(no output)');
        return { output => $out };
    });

    # % — Pipeline: run named pipeline.
    $sigil->register('%', sub {
        my ($app, $args) = @_;
        return 'usage: % <pipeline-name> | % list' unless length $args;
        if ($args eq 'list') {
            my $dir = "$ENV{HOME}/.clank/pipelines";
            opendir my $dh, $dir or return { output => '(no pipelines directory)' };
            my @files = sort map { s/\.clank$//r } grep { /\.clank$/ } readdir $dh;
            closedir $dh;
            return { output => @files ? "pipelines:\n  " . join("\n  ", @files) : '(no pipelines found)' };
        }
        return { output => "pipeline '$args' not yet implemented — use /agent instead" };
    });

    # > — Pipe: inline pipeline construction.
    $sigil->register('>', sub {
        my ($app, $args) = @_;
        return { output => 'usage: > stage1 | stage2 | stage3' } unless length $args;
        return { output => "inline pipes not yet implemented — use /agent instead" };
    });

    # : — Topic: bus publish/subscribe.
    $sigil->register(':', sub {
        my ($app, $args) = @_;
        return { output => 'usage: : <topic> | : listen <topic> | : publish <topic> <json>' } unless length $args;
        my $bus = $app->bus;

        if ($args =~ /^listen\s+(\S+)/) {
            my $topic = $1;
            my @seen;
            my $sub_id = $bus->subscribe($topic, sub {
                push @seen, $_[0]{payload} if @seen < 10;
            }, name => 'sigil_listen');
            # Publish a probe to collect any immediate events.
            select(undef, undef, undef, 0.1);
            $bus->unsubscribe($sub_id);
            if (@seen) {
                require Clank::Util;
                my @out = map { '  ' . Clank::Util::jencode($_) } @seen;
                return { output => "events on $topic:\n" . join("\n", @out) };
            }
            return { output => "(no recent events on $topic)" };
        }

        if ($args =~ /^publish\s+(\S+)\s+(.+)$/) {
            my ($topic, $payload_str) = ($1, $2);
            my $payload = eval { Clank::Util::jdecode($payload_str) };
            if ($@) { return { output => "invalid JSON: $@" } }
            $bus->publish($topic, $payload);
            return { output => "published to $topic" };
        }

        # Bare : <topic> — publish empty event.
        $bus->publish($args, {});
        return { output => "published to $args" };
    });

    # ~ — Wit: wit lifecycle management.
    $sigil->register('~', sub {
        my ($app, $args) = @_;
        my ($sub, $rest) = $args =~ /^(\S+)(?:\s+(.*))?$/;
        $sub //= '';
        my $pm = $app->pm;

        if ($sub eq 'list' || $sub eq '') {
            my @ws = $app->wits;
            return { output => '(no wits loaded)' } unless @ws;
            my @out;
            for my $w (@ws) {
                push @out, sprintf("  %-20s %-9s %s", $w->{name}, $w->{state} // 'active', $w->{dir});
            }
            return { output => "wits:\n" . join("\n", @out) };
        }

        if ($sub eq 'load') {
            return { output => 'usage: ~ load <directory-path>' } unless defined $rest && length $rest;
            my @loaded = eval { $pm->load_all(extra_paths => [$rest]) };
            if ($@) { return { output => "load error: $@" } }
            return { output => "loaded " . scalar(@loaded) . " wit(s) from $rest" };
        }

        if ($sub eq 'unload') {
            return { output => 'usage: ~ unload <wit-name>' } unless defined $rest && length $rest;
            my $ok = eval { $pm->disable_wit($rest) };
            if ($@) { return { output => "unload error: $@" } }
            return { output => $ok ? "unloaded $rest" : "wit '$rest' not found" };
        }

        if ($sub eq 'inspect') {
            return { output => 'usage: ~ inspect <wit-name>' } unless defined $rest && length $rest;
            my @ws = $app->wits;
            for my $w (@ws) {
                if ($w->{name} eq $rest) {
                    my @out = ("$rest:");
                    push @out, "  state: " . ($w->{state} // 'active');
                    push @out, "  dir:   $w->{dir}";
                    push @out, "  pkg:   $w->{pkg}";
                    return { output => join("\n", @out) };
                }
            }
            return { output => "wit '$rest' not found" };
        }

        if ($sub eq 'status') {
            my @ws = $app->wits;
            my $active = grep { !($_->{state} // '') eq 'disabled' } @ws;
            return { output => "wits: $active active, " . scalar(@ws) . " total" };
        }

        return { output => "usage: ~ list | ~ load <path> | ~ unload <name> | ~ inspect <name> | ~ status" };
    });

    # ! — History: re-run previous command.
    $sigil->register('!', sub {
        my ($app, $args) = @_;
        my $history = $self->{history} // [];
        return { output => '(no history yet)' } unless @$history;

        if ($args eq 'last' || $args eq '') {
            my $last = $history->[-1];
            return { output => "re-running: $last" , rerun => $last };
        }

        if ($args =~ /^-?(\d+)$/) {
            my $idx = $1;
            if ($args =~ /^-/) {
                $idx = $#$history - $idx + 1;
            } else {
                $idx--;   # 1-indexed
            }
            if ($idx < 0 || $idx > $#$history) {
                return { output => "history: out of range (have " . scalar(@$history) . " entries)" };
            }
            my $cmd = $history->[$idx];
            return { output => "!$args => $cmd", rerun => $cmd };
        }

        return { output => 'usage: ! [N] | ! -N | ! last' };
    });
}

1;
