# Clank::Metrics — simple counters for LLM calls, tokens, rules, crystallizations.
#
# In-memory hash counters with periodic flush to SQLite kv table.
# Fast (no DB writes per increment), crash-safe (flush on demand),
# queryable (read from DB after flush).
#
# Usage:
#   $metrics->inc('llm.calls');
#   $metrics->inc('llm.tokens.input', 500);
#   $metrics->flush;
#   my $total = $metrics->get('llm.calls');
package Clank::Metrics;
use strict;
use warnings;

my $FLUSH_KEY = 'metrics.data';

sub new {
    my ($class, %args) = @_;
    my $store = $args{store} // die "Clank::Metrics requires store\n";
    my $self = bless {
        store       => $store,
        bus         => $args{bus},
        flush_ms    => $args{flush_ms} // 60_000,   # flush every 60s
        _counters   => {},    # name => value (in-memory)
        _last_flush => 0,
    }, $class;
    $self->_load;
    return $self;
}

# Increment a counter. $delta defaults to 1.
sub inc {
    my ($self, $name, $delta) = @_;
    $delta //= 1;
    $self->{_counters}{$name} += $delta;
    $self->_maybe_flush;
}

# Decrement a counter.
sub dec {
    my ($self, $name, $delta) = @_;
    $delta //= 1;
    $self->{_counters}{$name} -= $delta;
}

# Set a counter to an absolute value.
sub set {
    my ($self, $name, $value) = @_;
    $self->{_counters}{$name} = $value;
}

# Get a counter value (in-memory; for DB value, call sync first).
sub get {
    my ($self, $name) = @_;
    return $self->{_counters}{$name} // 0;
}

# Get all counters as a hashref.
sub snapshot {
    my ($self) = @_;
    return { %{$self->{_counters}} };
}

# Flush in-memory counters to SQLite kv.
sub flush {
    my ($self) = @_;
    $self->{store}->kv_set($FLUSH_KEY, $self->{_counters});
    $self->{_last_flush} = time();
}

# Load counters from SQLite kv.
sub sync {
    my ($self) = @_;
    $self->_load;
}

# Reset a counter or all counters.
sub reset {
    my ($self, $name) = @_;
    if (defined $name) {
        delete $self->{_counters}{$name};
    } else {
        $self->{_counters} = {};
    }
}

# LLM-specific convenience methods.

sub llm_call {
    my ($self, %args) = @_;
    my $model = $args{model} // 'unknown';
    $self->inc('llm.calls');
    $self->inc("llm.calls.$model");
    $self->inc('llm.tokens.input', $args{input_tokens} // 0);
    $self->inc('llm.tokens.output', $args{output_tokens} // 0);
    $self->inc("llm.tokens.input.$model", $args{input_tokens} // 0);
    $self->inc("llm.tokens.output.$model", $args{output_tokens} // 0);
    $self->inc('llm.cost', $args{cost} // 0);
}

sub rule_fired {
    my ($self, $rule_name) = @_;
    $self->inc('rules.fired');
    $self->inc("rules.fired.$rule_name") if defined $rule_name;
}

sub crystallize {
    my ($self, $rule_name) = @_;
    $self->inc('crystallizations');
    $self->inc("crystallizations.$rule_name") if defined $rule_name;
}

# === INTERNAL ===

sub _load {
    my ($self) = @_;
    my $data = $self->{store}->kv_get($FLUSH_KEY);
    $self->{_counters} = ref $data eq 'HASH' ? { %$data } : {};
}

sub _maybe_flush {
    my ($self) = @_;
    return if time() - $self->{_last_flush} < $self->{flush_ms};
    $self->flush;
}

1;
