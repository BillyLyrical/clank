# Clam::Driver — programmatic multi-query session driver for the clam harness.
#
# The API wrapper an AI harness (or any Perl script) uses to drive a complex,
# stateful Clam session: many prompts against one persistent session, with
# structured per-turn results and full bus-event observability.  See
# docs/DRIVER.md for the design notes and the clamd NDJSON protocol built on
# top of this module.
#
#   my $d = Clam::Driver->new(provider => 'lmstudio', model => '...', db => ':memory:');
#   $d->start;
#   my $r1 = $d->ask('list the files in this project');
#   my $r2 = $d->ask('now fix the failing test', timeout => 120);
#   # $rN = { ok, response, turns, tools=>[...], events=>[...], messages_added }
#   $d->close;
package Clam::Driver;
use strict;
use warnings;
use Cwd qw(getcwd);
use Clam::App;
use Clam::Session::Messages;
use Clam::Util qw(jencode jdecode);

sub new {
    my ($class, %o) = @_;
    return bless {
        # driver-level options
        events  => 1,     # capture per-turn bus events into ask() results
        timeout => 0,     # default per-ask timeout (0 = none; provider has its own)
        # App pass-through: db, provider (name or object), model, base_url,
        # api_key, stream, wit_paths, compact, workdir (chdir before start)
        %o,
    }, $class;
}

# --- lifecycle ---------------------------------------------------------------

sub started { $_[0]->{session} ? 1 : 0 }

# Build the App (if needed) and start a session.  Pass resume => $id to
# continue an earlier session from the same db file.  Dies if already started.
sub start {
    my ($self, %o) = @_;
    die "Clam::Driver: already started\n" if $self->{session};
    chdir $self->{workdir} if defined $self->{workdir} && length($self->{workdir});

    my $app = Clam::App->new(
        db        => $self->{db},
        provider  => $self->{provider},
        model     => $self->{model},
        base_url  => $self->{base_url},
        api_key   => $self->{api_key},
        stream    => $self->{stream} // 0,
        wit_paths => $self->{wit_paths} // [],
        compact   => $self->{compact},
    );
    $self->{app} = $app;
    my $session = $app->start_session(%o);
    $self->{session} = $session;
    return $self;
}

# Idempotent shutdown.  Also called from DESTROY, so a driver that dies or is
# forgotten still tears down cleanly (no leaked handles, no zombie state).
sub close {
    my ($self) = @_;
    return if $self->{closed};
    $self->{closed} = 1;
    eval { $self->{app}->shutdown } if $self->{app};   # journals session_shutdown
    $self->{session} = undef;
    $self->{app}     = undef;
    return 1;
}

sub DESTROY { my ($s) = @_; eval { $s->close }; }

# --- accessors ---------------------------------------------------------------

sub app       { $_[0]->{app} }
sub store     { $_[0]->{app}->store if $_[0]->{app} }
sub bus       { $_[0]->{app}->bus   if $_[0]->{app} }
sub session   { $_[0]->{session} }
sub provider  { $_[0]->{app}->provider if $_[0]->{app} }
sub session_id { $_[0]->{session}->id if $_[0]->{session} }

# --- the core: one agent turn -------------------------------------------------

# Run one prompt through the full agent loop and return a structured result.
# Never dies for ordinary failures (errors come back in the hashref).
#
#   ask($text, timeout => 120)
#
# Result keys:
#   ok             1/0
#   error          message when !ok
#   timed_out      1 when the driver-level timeout fired
#   handled/output set when an input hook short-circuited the turn
#   response       final assistant text (undef if none, e.g. tool-only turns)
#   turns          provider round-trips this prompt took
#   tools          [ {id,name,input,isError}, ... ] in execution order
#   events         every bus event during the turn: {topic,sender,payload}
#                  (dispatch order; disabled with new(events => 0))
#   messages_added delta of session message count for this turn
sub ask {
    my ($self, $text, %o) = @_;
    die "Clam::Driver: not started\n" unless $self->{session};
    defined $text or return { ok => 0, error => 'no prompt text' };

    my $bus     = $self->bus;
    my $store   = $self->store;
    my $sid     = $self->session_id;
    my $timeout = $o{timeout} // $self->{timeout};

    # Per-turn event capture.  The collector MUST return undef: publish()
    # gathers defined handler results as hook responses, and a stray hashref
    # here could be misread by input/tool_call/message_end hooks.
    my (@events, $sub_id);
    if ($self->{events}) {
        $sub_id = $bus->subscribe('*', sub {
            my ($ev) = @_;
            push @events, { topic => $ev->{topic}, sender => $ev->{sender}, payload => $ev->{payload} };
            return;
        }, name => 'driver.capture');
    }

    my $before = scalar @{ Clam::Session::Messages::chain($store, $sid) };

    my ($res, $timed_out);
    if ($timeout > 0) {
        # Same alarm pattern as WitLoader: local handler at sub scope.  Note a
        # wit or provider that sets its own alarm mid-turn replaces this one —
        # the timeout is best-effort protection, not a guarantee.
        # Time::HiRes::ualarm (not core alarm): core alarm() truncates to whole
        # seconds, so sub-second timeouts would silently become "no timeout".
        require Time::HiRes;
        local $SIG{ALRM} = sub { die "driver: ask timed out after ${timeout}s\n" };
        Time::HiRes::ualarm(int($timeout * 1_000_000));
        eval { $res = $self->app->run_prompt($text) };
        my $err = $@;
        Time::HiRes::ualarm(0);
        # The timeout die may escape to this eval, or it may be caught inside
        # the loop (which wraps provider calls in its own eval) and returned as
        # a plain {ok=>0,error} result - detect either shape.
        $res = { ok => 0, error => "$err" } if $err && !$res;
        my $errtext = "$err " . ((ref($res) eq 'HASH') ? ($res->{error} // '') : '');
        if ($errtext =~ /timed out/) { $timed_out = 1; $res->{ok} = 0 }
    } else {
        eval { $res = $self->app->run_prompt($text) };
        my $err = $@;
        $res = { ok => 0, error => "$err" } if $err && !$res;
    }

    $res //= { ok => 0, error => 'no result from run_prompt' };

    $bus->unsubscribe($sub_id) if defined $sub_id;

    # Tool summary from this turn's execution events (paired by toolCallId).
    my (%open, @tools);
    for my $e (@events) {
        my ($topic, $p) = ($e->{topic}, $e->{payload} // {});
        if ($topic eq 'tool_execution_start') {
            $open{ $p->{toolCallId} } = { id => $p->{toolCallId}, name => $p->{name}, input => $p->{input} };
        } elsif ($topic eq 'tool_execution_end' && exists $open{ $p->{toolCallId} }) {
            my $t = delete $open{ $p->{toolCallId} };
            $t->{isError} = $p->{isError} ? 1 : 0;
            push @tools, $t;
        }
    }

    # Final assistant text (leaf of the session chain).
    my ($response);
    my $leaf = eval { $store->get_message($store->leaf_message($sid)) };
    if (!$@ && ref $leaf eq 'HASH' && ($leaf->{role} // '') eq 'assistant' && ref $leaf->{content} eq 'HASH') {
        $response = $leaf->{content}{text};
    }

    my %r = (
        ok             => $res->{ok} ? 1 : 0,
        turns          => $res->{turns},
        response       => $response,
        tools          => \@tools,
        messages_added => scalar @{ Clam::Session::Messages::chain($store, $sid) } - $before,
    );
    $r{error}     = $res->{error} if !$r{ok};
    $r{timed_out} = 1             if $timed_out;
    $r{handled}   = 1, $r{output} = $res->{output} if $res->{handled};
    $r{events}    = \@events      if $self->{events};
    return \%r;
}

# --- introspection -------------------------------------------------------------

# Session message chain (newest last); limit => N returns the last N.
sub messages {
    my ($self, %o) = @_;
    die "Clam::Driver: not started\n" unless $self->{session};
    my @chain = @{ Clam::Session::Messages::chain($self->store, $self->session_id) };
    @chain = @chain[-$o{limit} .. -1] if $o{limit} && @chain > $o{limit};
    return \@chain;
}

# Journal query across the whole session (or since driver start on :memory:).
# topic => glob with subscription semantics ('.' = segment separator, '*' =
# within-segment wildcard): 'tool_*' matches tool_call/tool_result; 'search.*'
# matches search.results.  limit => N.  Payloads arrive already decoded from
# the store.  Returns an arrayref of {id,correlation_id,topic,sender,payload,created_at}.
sub events {
    my ($self, %o) = @_;
    die "Clam::Driver: not started\n" unless $self->{session};
    # SQLite LIKE cannot express glob patterns, so filter in Perl with the
    # same matcher subscriptions use; fetch a wider window when filtering.
    my $want  = $o{limit} // 200;
    my $fetch = defined $o{topic} ? ($want > 500 ? 500 : $want * 10) : $want;
    my @rows  = @{ $self->store->query_events(limit => $fetch) };
    if (defined $o{topic}) {
        require Clam::Bus;
        @rows = grep { Clam::Bus::topic_matches($o{topic}, $_->{topic} // '') } @rows;
        @rows = @rows[0 .. $want - 1] if @rows > $want;
    }
    return \@rows;
}

sub tool_names  { $_[0]->{session}->tool_names if $_[0]->{session} }

# Derived names of all loaded declarative wits (aliases collapsed).
sub wit_names {
    my ($self) = @_;
    my $pm = $self->{app} && $self->{app}->pm or return ();
    my (%seen, @n);
    for my $rec (values %{ $pm->dwits }) { push @n, $rec->{name} unless $seen{ $rec->{name} }++ }
    return sort @n;
}

sub skipped_wits { $_[0]->{app}->pm->skipped if $_[0]->{app} && $_[0]->{app}->pm }
sub load_errors  { $_[0]->{app}->pm->errors  if $_[0]->{app} && $_[0]->{app}->pm }

# Compact session summary (used by clamd's session_info command).
sub info {
    my ($self) = @_;
    die "Clam::Driver: not started\n" unless $self->{session};
    my $skipped = $self->skipped_wits;   # arrayref from PluginManager (may be [])
    return {
        ok           => 1,
        session_id   => $self->session_id,
        messages     => scalar @{ Clam::Session::Messages::chain($self->store, $self->session_id) },
        tools        => [ sort $self->tool_names ],
        wits         => [ $self->wit_names ],
        skipped_wits => (ref($skipped) eq 'ARRAY') ? $skipped : [],
        provider     => eval { $self->provider->log_safe } // undef,
    };
}

1;
