# Clam::Governor — rate limiter, budget cap, and circuit breaker for LLM
# providers. Prevents cost blowouts and cascade failures.
#
# Three mechanisms:
#   1. Rate limiter  — sliding window counters (requests/min, tokens/hour)
#   2. Budget cap    — hard dollar limit per session
#   3. Circuit breaker — open on repeated failures, probe on cooldown
#
# State is persisted in SQLite via Clam::Store. Rate-limit windows are
# in-memory (reset on restart is acceptable for a safety mechanism).
#
# Integration: Loop calls governor->check before each provider call and
# governor->record after. The governor publishes bus events so wits can
# react to throttling.
package Clam::Governor;
use strict;
use warnings;
use Clam::Util qw(jencode jdecode);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

# Default pricing: per-token cost (USD) for known models.
# Input and output tokens often differ in price.
my %DEFAULT_PRICING = (
    'gpt-4o'       => { input => 2.50e-6, output => 10.00e-6 },
    'gpt-4o-mini'  => { input => 0.15e-6, output => 0.60e-6 },
    'gpt-4-turbo'  => { input => 10.00e-6, output => 30.00e-6 },
    'claude-3.5-sonnet' => { input => 3.00e-6, output => 15.00e-6 },
    'claude-3-haiku'    => { input => 0.25e-6, output => 1.25e-6 },
);

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} // die "Clam::Governor requires store\n";
    my $self = bless {
        store    => $store,
        bus      => $args{bus},

        # --- rate limits (sliding window) ---
        max_per_minute  => $args{max_per_minute}  // 60,
        max_per_hour    => $args{max_per_hour}    // 1000,
        max_tokens_hour => $args{max_tokens_hour} // 500_000,
        _window         => {},   # { minute => [...ms], hour => [...ms] }
        _token_window   => [],   # [ {ms, tokens}, ... ]

        # --- budget cap ---
        budget          => $args{budget},          # undef = unlimited
        session_id      => $args{session_id},

        # --- circuit breaker ---
        cb_threshold    => $args{cb_threshold}    // 5,    # failures to trip
        cb_cooldown_ms  => $args{cb_cooldown_ms}  // 60_000,
        cb_state        => 'closed',               # closed|open|half_open
        cb_failures     => 0,
        cb_opened_at    => 0,

        # --- pricing ---
        pricing         => { %DEFAULT_PRICING, %{ $args{pricing} // {} } },

        # --- stats (in-memory, not persisted) ---
        total_requests  => 0,
        total_tokens    => 0,
        total_cost      => 0,
    }, $class;
    $self->_init_schema;
    return $self;
}

# Monotonic millisecond clock (immune to wall-clock jumps).
sub _now_ms { int(clock_gettime(CLOCK_MONOTONIC) * 1000) }

sub _dbh { $_[0]->{store}->dbh }

sub _init_schema {
    my ($self) = @_;
    my $db = $self->_dbh;
    $db->do(qq{
CREATE TABLE IF NOT EXISTS governor_usage (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT,
  model TEXT,
  input_tokens INTEGER DEFAULT 0,
  output_tokens INTEGER DEFAULT 0,
  cost REAL DEFAULT 0,
  created_at INTEGER
)});
    $db->do(qq{CREATE INDEX IF NOT EXISTS idx_governor_session
        ON governor_usage(session_id, created_at)});
}

# === PUBLIC API ===

# Check if a request is allowed. Returns (ok, reason).
# If ok is false, the caller should abort the provider call.
sub check {
    my ($self, %args) = @_;
    my $model = $args{model} // '';
    my $estimated_tokens = $args{estimated_tokens} // 1000;

    # Circuit breaker: if open, reject immediately.
    if ($self->{cb_state} eq 'open') {
        my $elapsed = _now_ms() - $self->{cb_opened_at};
        if ($elapsed >= $self->{cb_cooldown_ms}) {
            $self->{cb_state} = 'half_open';
        } else {
            my $wait = int(($self->{cb_cooldown_ms} - $elapsed) / 1000) + 1;
            $self->_publish('governor.circuit_open', {
                model => $model, retry_after_s => $wait,
            });
            return (0, "circuit open, retry in ${wait}s");
        }
    }

    # Budget cap.
    if (defined $self->{budget}) {
        my $spent = $self->_session_cost;
        if ($spent >= $self->{budget}) {
            $self->_publish('governor.budget_exceeded', {
                model => $model, spent => $spent, budget => $self->{budget},
            });
            return (0, sprintf("budget exhausted (\$%.2f / \$%.2f)", $spent, $self->{budget}));
        }
    }

    # Rate limit: requests per minute.
    my $now = _now_ms();
    my $window = $self->{_window};
    $window->{minute} //= [];
    push @{$window->{minute}}, $now;
    @{$window->{minute}} = grep { $now - $_ < 60_000 } @{$window->{minute}};
    if (scalar @{$window->{minute}} > $self->{max_per_minute}) {
        $self->_publish('governor.rate_limited', {
            model => $model, window => 'minute',
            current => scalar @{$window->{minute}}, max => $self->{max_per_minute},
        });
        return (0, "rate limit: ${\scalar @{$window->{minute}}} requests/min (max $self->{max_per_minute})");
    }

    # Rate limit: requests per hour.
    $window->{hour} //= [];
    push @{$window->{hour}}, $now;
    @{$window->{hour}} = grep { $now - $_ < 3_600_000 } @{$window->{hour}};
    if (scalar @{$window->{hour}} > $self->{max_per_hour}) {
        $self->_publish('governor.rate_limited', {
            model => $model, window => 'hour',
            current => scalar @{$window->{hour}}, max => $self->{max_per_hour},
        });
        return (0, "rate limit: ${\scalar @{$window->{hour}}} requests/hour (max $self->{max_per_hour})");
    }

    # Token limit: tokens per hour.
    my $token_window = $self->{_token_window};
    @$token_window = grep { $now - $_->{ms} < 3_600_000 } @$token_window;
    my $tokens_hour = 0;
    $tokens_hour += $_->{tokens} for @$token_window;
    if ($tokens_hour + $estimated_tokens > $self->{max_tokens_hour}) {
        $self->_publish('governor.rate_limited', {
            model => $model, window => 'tokens_hour',
            current => $tokens_hour, max => $self->{max_tokens_hour},
        });
        return (0, "token limit: ${tokens_hour} tokens/hour (max $self->{max_tokens_hour})");
    }

    return (1, undef);
}

# Record actual usage after a successful provider call.
sub record {
    my ($self, %args) = @_;
    my $model         = $args{model}         // '';
    my $input_tokens  = $args{input_tokens}  // 0;
    my $output_tokens = $args{output_tokens} // 0;

    my $cost = $self->_calc_cost($model, $input_tokens, $output_tokens);
    my $total_tokens = $input_tokens + $output_tokens;
    my $now = _now_ms();

    # Persist to SQLite.
    $self->_dbh->prepare(
        'INSERT INTO governor_usage (session_id,model,input_tokens,output_tokens,cost,created_at) VALUES (?,?,?,?,?,?)'
    )->execute($self->{session_id}, $model, $input_tokens, $output_tokens, $cost, $now);

    # Update in-memory token window.
    push @{$self->{_token_window}}, { ms => $now, tokens => $total_tokens };

    # Update stats.
    $self->{total_requests}++;
    $self->{total_tokens} += $total_tokens;
    $self->{total_cost}   += $cost;

    # Reset circuit breaker on success.
    if ($self->{cb_state} eq 'half_open') {
        $self->{cb_state} = 'closed';
        $self->{cb_failures} = 0;
        $self->_publish('governor.circuit_closed', { model => $model });
    } elsif ($self->{cb_state} eq 'closed') {
        $self->{cb_failures} = 0;
    }

    $self->_publish('governor.record', {
        model         => $model,
        input_tokens  => $input_tokens,
        output_tokens => $output_tokens,
        cost          => $cost,
        session_cost  => $self->_session_cost,
        total_cost    => $self->{total_cost},
    });

    return $cost;
}

# Record a failure (for circuit breaker). Does NOT record token usage.
sub record_failure {
    my ($self, %args) = @_;
    my $model = $args{model} // '';
    my $fatal = $args{fatal} // 0;   # 429, 5xx, timeout
    return unless $fatal;

    $self->{cb_failures}++;
    if ($self->{cb_failures} >= $self->{cb_threshold} && $self->{cb_state} ne 'open') {
        $self->{cb_state} = 'open';
        $self->{cb_opened_at} = _now_ms();
        $self->_publish('governor.circuit_open', {
            model     => $model,
            failures  => $self->{cb_failures},
            cooldown_ms => $self->{cb_cooldown_ms},
        });
    }
}

# Get current usage summary.
sub usage {
    my ($self) = @_;
    return {
        requests      => $self->{total_requests},
        tokens        => $self->{total_tokens},
        cost          => $self->{total_cost},
        session_cost  => $self->_session_cost,
        budget        => $self->{budget},
        circuit_state => $self->{cb_state},
        cb_failures   => $self->{cb_failures},
    };
}

# Reset circuit breaker manually.
sub circuit_reset {
    my ($self) = @_;
    $self->{cb_state}    = 'closed';
    $self->{cb_failures} = 0;
    $self->{cb_opened_at} = 0;
}

# === INTERNAL ===

sub _session_cost {
    my ($self) = @_;
    return 0 unless defined $self->{session_id};
    my $sth = $self->_dbh->prepare(
        'SELECT COALESCE(SUM(cost),0) FROM governor_usage WHERE session_id=?');
    $sth->execute($self->{session_id});
    return $sth->fetchrow_array;
}

sub _calc_cost {
    my ($self, $model, $input_tokens, $output_tokens) = @_;
    my $p = $self->{pricing}{$model};
    return 0 unless $p;
    return ($input_tokens * ($p->{input} // 0)) + ($output_tokens * ($p->{output} // 0));
}

sub _publish {
    my ($self, $topic, $payload) = @_;
    return unless $self->{bus};
    eval { $self->{bus}->publish($topic, $payload, sender => 'governor') };
}

1;

__END__

=encoding utf-8

=head1 NAME

Clam::Governor — rate limiter, budget cap, and circuit breaker for LLM
providers. Prevents cost blowouts and cascade failures.

=head1 SYNOPSIS

  use Clam::Governor;

  my $gov = Clam::Governor->new(
      store          => $store,          # required: Clam::Store
      bus            => $bus,            # optional: Clam::Bus for events
      session_id     => $session_id,
      budget         => 5.00,            # $5 max per session
      max_per_minute => 30,              # 30 requests/min
      max_per_hour   => 1000,            # 1000 requests/hour
      max_tokens_hour => 500_000,        # 500k tokens/hour
      cb_threshold   => 5,               # 5 failures trips circuit
      cb_cooldown_ms => 60_000,          # open for 60 seconds
      pricing        => { 'my-model' => { input => 1e-6, output => 2e-6 } },
  );

  # Before each provider call:
  my ($ok, $reason) = $gov->check(model => $model, estimated_tokens => $est);
  die "throttled: $reason" unless $ok;

  # After each successful call:
  $gov->record(model => $model, input_tokens => $in, output_tokens => $out);

  # After a fatal failure (429, 5xx, timeout):
  $gov->record_failure(model => $model, fatal => 1);

  # Usage summary:
  my $u = $gov->usage;
  # { requests, tokens, cost, session_cost, budget, circuit_state, cb_failures }

=head1 DESCRIPTION

Clam::Governor is the Watt's centrifugal governor for LLM providers. It
monitors throughput and cost, and throttles or rejects requests when
configurable thresholds are breached. Three mechanisms work together:

=over 4

=item Rate limiter — sliding window counters for requests/minute, requests/hour,
and tokens/hour.

=item Budget cap — hard dollar limit per session. Once exceeded, all requests
are rejected until the session ends.

=item Circuit breaker — if the provider returns fatal errors (429, 5xx,
timeout) N times in a row, the circuit opens and rejects requests for
C<cb_cooldown_ms> milliseconds. After cooldown, one probe request is
allowed (half-open). Success closes the circuit; failure reopens it.

=back

State is persisted in SQLite via Clam::Store (C<governor_usage> table).
Rate-limit windows and circuit breaker state are in-memory — a restart
resets them, which is acceptable for a safety mechanism.

When a bus is provided, the governor publishes events:

  governor.record           — after each successful call (with cost)
  governor.rate_limited     — when a rate limit is hit
  governor.budget_exceeded  — when session budget is exhausted
  governor.circuit_open     — when circuit trips or rejects during open
  governor.circuit_closed   — when circuit closes after probe success

=head1 PRICING

Default per-token costs are included for known models (GPT-4o, GPT-4o-mini,
Claude 3.5 Sonnet, Claude 3 Haiku). Pass custom pricing to override or add:

  pricing => { 'local-model' => { input => 0, output => 0 } }

Cost is calculated as: C< input_tokens * input_rate + output_tokens * output_rate >.

=head1 METHODS

=head2 new(%args)

Constructor. Required: C<store>. Optional: C<budget>, C<session_id>,
C<bus>, C<max_per_minute>, C<max_per_hour>, C<max_tokens_hour>,
C<cb_threshold>, C<cb_cooldown_ms>, C<pricing>.

=head2 check(model => $m, estimated_tokens => $n)

Returns C<($ok, $reason)>. If C<$ok> is false, the caller should abort
the provider call. Checks circuit state, budget, and rate limits in
that order.

=head2 record(model => $m, input_tokens => $in, output_tokens => $out)

Records actual usage after a successful provider call. Returns the
calculated cost. Resets circuit breaker on success.

=head2 record_failure(model => $m, fatal => $bool)

Records a provider failure. Only C<fatal> failures (429, 5xx, timeout)
increment the circuit breaker counter.

=head2 usage()

Returns a hashref with C<requests>, C<tokens>, C<cost>, C<session_cost>,
C<budget>, C<circuit_state>, C<cb_failures>.

=head2 circuit_reset()

Manually reset the circuit breaker to closed state.

=head1 SEE ALSO

L<Clam::Provider>, L<Clam::Loop>, L<Clam::Store>

=cut
