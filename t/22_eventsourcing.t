#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clam::Store;
use Clam::EventSourcing;

my $store = Clam::Store->new(db => ':memory:');

# === Test 1: Construction ===

subtest 'Construction' => sub {
    my $es = Clam::EventSourcing->new(store => $store);
    isa_ok($es, 'Clam::EventSourcing');
    my $s = $es->stats;
    is($s->{total_events}, 0, 'starts with zero events');
};

# === Test 2: Emit and retrieve ===

subtest 'Emit and retrieve event' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    my $id = $es->emit(
        event_type     => 'created',
        aggregate_type => 'entity',
        aggregate_id   => 'e1',
        payload        => { name => 'Alice', type => 'person' },
        metadata       => { source => 'test' },
    );
    ok(defined $id, 'emit returns id');

    my $history = $es->history('entity', 'e1');
    is(scalar @$history, 1, 'one event in history');
    is($history->[0]{event_type}, 'created', 'event type');
    is($history->[0]{payload}{name}, 'Alice', 'payload preserved');
    is($history->[0]{metadata}{source}, 'test', 'metadata preserved');
};

# === Test 3: Append-only (no updates) ===

subtest 'Events are immutable' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { name => 'Alice' });
    $es->emit(event_type => 'updated', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { name => 'Alice', age => 30 });
    $es->emit(event_type => 'updated', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { name => 'Alice', age => 31 });

    my $history = $es->history('entity', 'e1');
    is(scalar @$history, 3, 'all events preserved');
    is($history->[2]{payload}{age}, 31, 'latest state has age 31');
};

# === Test 4: Aggregate isolation ===

subtest 'Aggregates are isolated' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { name => 'Alice' });
    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e2',
              payload => { name => 'Bob' });
    $es->emit(event_type => 'created', aggregate_type => 'fact', aggregate_id => 'f1',
              payload => { predicate => 'knows', value => 'Alice knows Bob' });

    my $h1 = $es->history('entity', 'e1');
    is(scalar @$h1, 1, 'e1 has 1 event');

    my $h2 = $es->history('entity', 'e2');
    is(scalar @$h2, 1, 'e2 has 1 event');

    my $hf = $es->history('fact', 'f1');
    is(scalar @$hf, 1, 'f1 has 1 event');
};

# === Test 5: Delete/retract ===

subtest 'Delete events remove from replay' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { name => 'Alice' });
    $es->emit(event_type => 'deleted', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { reason => 'obsolete' });

    my $state = $es->replay(aggregate_type => 'entity');
    is($state->{entity}{e1}, undef, 'deleted entity absent from replay');

    # History still shows both events.
    my $history = $es->history('entity', 'e1');
    is(scalar @$history, 2, 'history preserves delete event');
};

# === Test 6: Causal chain ===

subtest 'Causal chain tracing' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    my $e1 = $es->emit(event_type => 'created', aggregate_type => 'fact',
                       aggregate_id => 'f1', payload => { predicate => 'rains' });
    my $e2 = $es->emit(event_type => 'created', aggregate_type => 'rule',
                       aggregate_id => 'r1', payload => { name => 'rain_rule' },
                       caused_by => $e1);
    my $e3 = $es->emit(event_type => 'crystallized', aggregate_type => 'rule',
                       aggregate_id => 'r1', payload => { confidence => 0.9 },
                       caused_by => $e2);

    # Trace back from e3.
    my $chain = $es->trace_causes($e3);
    is(scalar @$chain, 3, 'chain has 3 events');
    is($chain->[0]{event_type}, 'created', 'root cause is created');
    is($chain->[2]{event_type}, 'crystallized', 'leaf is crystallized');

    # Trace forward from e1.
    my $effects = $es->trace_effects($e1);
    is(scalar @$effects, 1, 'e1 has 1 downstream effect');
    is($effects->[0]{id}, $e2, 'effect is e2');
};

# === Test 7: Replay ===

subtest 'Replay rebuilds state' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { name => 'Alice' });
    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e2',
              payload => { name => 'Bob' });
    $es->emit(event_type => 'updated', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { name => 'Alice', age => 30 });
    $es->emit(event_type => 'deleted', aggregate_type => 'entity', aggregate_id => 'e2',
              payload => {});

    my $state = $es->replay;
    is($state->{entity}{e1}{name}, 'Alice', 'e1 replayed');
    is($state->{entity}{e1}{age}, 30, 'e1 updated');
    is($state->{entity}{e2}, undef, 'e2 deleted');
};

# === Test 8: Snapshot ===

subtest 'Snapshot of aggregate state' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { name => 'Alice' });
    $es->emit(event_type => 'updated', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => { name => 'Alice', age => 30 });

    my $snap = $es->snapshot('entity', 'e1');
    is($snap->{name}, 'Alice', 'snapshot has name');
    is($snap->{age}, 30, 'snapshot has latest state');

    is($es->snapshot('entity', 'nonexistent'), undef, 'nonexistent returns undef');
};

# === Test 9: History since/until ===

subtest 'History with since/until' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    my $e1 = $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e1',
                        payload => { v => 1 });
    my $e2 = $es->emit(event_type => 'updated', aggregate_type => 'entity', aggregate_id => 'e1',
                        payload => { v => 2 });
    my $e3 = $es->emit(event_type => 'updated', aggregate_type => 'entity', aggregate_id => 'e1',
                        payload => { v => 3 });

    my $since_e1 = $es->history('entity', 'e1', since => $e1);
    is(scalar @$since_e1, 2, 'events after e1');
    is($since_e1->[0]{payload}{v}, 2, 'first after e1');

    my $until_e2 = $es->history('entity', 'e1', until => $e2);
    is(scalar @$until_e2, 2, 'events up to e2');
    is($until_e2->[1]{payload}{v}, 2, 'last is e2');
};

# === Test 10: Events by type ===

subtest 'Query by event type' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e1',
              payload => {});
    $es->emit(event_type => 'crystallized', aggregate_type => 'rule', aggregate_id => 'r1',
              payload => {});
    $es->emit(event_type => 'crystallized', aggregate_type => 'rule', aggregate_id => 'r2',
              payload => {});

    my $cryst = $es->events_by_type('crystallized');
    is(scalar @$cryst, 2, 'two crystallization events');
};

# === Test 11: Stats ===

subtest 'Stats' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e1', payload => {});
    $es->emit(event_type => 'created', aggregate_type => 'fact', aggregate_id => 'f1', payload => {});
    $es->emit(event_type => 'crystallized', aggregate_type => 'rule', aggregate_id => 'r1', payload => {});

    my $s = $es->stats;
    is($s->{total_events}, 3, 'total events');
    ok(scalar @{$s->{by_type}} > 0, 'by_type populated');
    ok(scalar @{$s->{aggregates}} > 0, 'aggregates populated');
};

# === Test 12: Bus events ===

subtest 'Bus integration' => sub {
    my $store2 = Clam::Store->new(db => ':memory:');
    require Clam::Bus;
    my $bus = Clam::Bus->new(store => $store2);

    my $es = Clam::EventSourcing->new(store => $store2, bus => $bus);
    my @events;
    $bus->subscribe('event.*', sub { push @events, $_[0]{topic} }, name => 'test');

    $es->emit(event_type => 'created', aggregate_type => 'entity', aggregate_id => 'e1', payload => {});

    ok(grep { $_ eq 'event.emitted' } @events, 'event.emitted published');
};

# === Test 13: Max depth on causal chain ===

subtest 'Causal chain respects max_depth' => sub {
    my $es = Clam::EventSourcing->new(store => Clam::Store->new(db => ':memory:'));

    my $prev;
    for my $i (1..10) {
        $prev = $es->emit(event_type => 'updated', aggregate_type => 'entity',
                          aggregate_id => 'e1', payload => { step => $i },
                          caused_by => $prev);
    }

    my $chain = $es->trace_causes($prev, max_depth => 3);
    ok(scalar @$chain <= 3, 'chain limited by max_depth');
};

done_testing();
