#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clam::Store;
use Clam::Metrics;

my $store = Clam::Store->new(db => ':memory:');

# === Test 1: Construction ===

subtest 'Construction' => sub {
    my $m = Clam::Metrics->new(store => $store);
    isa_ok($m, 'Clam::Metrics');
    is($m->get('anything'), 0, 'unknown counter returns 0');
};

# === Test 2: Inc/dec/get ===

subtest 'Increment and decrement' => sub {
    my $m = Clam::Metrics->new(store => Clam::Store->new(db => ':memory:'));

    $m->inc('counter');
    is($m->get('counter'), 1, 'inc default 1');

    $m->inc('counter', 5);
    is($m->get('counter'), 6, 'inc by 5');

    $m->dec('counter', 2);
    is($m->get('counter'), 4, 'dec by 2');

    $m->dec('counter');
    is($m->get('counter'), 3, 'dec default 1');
};

# === Test 3: Set ===

subtest 'Set absolute value' => sub {
    my $m = Clam::Metrics->new(store => Clam::Store->new(db => ':memory:'));

    $m->set('gauge', 100);
    is($m->get('gauge'), 100, 'set to 100');

    $m->set('gauge', 50);
    is($m->get('gauge'), 50, 'set overwrites');
};

# === Test 4: Snapshot ===

subtest 'Snapshot returns all counters' => sub {
    my $m = Clam::Metrics->new(store => Clam::Store->new(db => ':memory:'));

    $m->inc('a');
    $m->inc('b', 3);
    my $snap = $m->snapshot;
    is($snap->{a}, 1, 'snapshot a');
    is($snap->{b}, 3, 'snapshot b');
};

# === Test 5: Flush and sync ===

subtest 'Flush persists to SQLite, sync loads' => sub {
    my $store2 = Clam::Store->new(db => ':memory:');
    my $m1 = Clam::Metrics->new(store => $store2);

    $m1->inc('x', 42);
    $m1->flush;

    my $m2 = Clam::Metrics->new(store => $store2);
    is($m2->get('x'), 42, 'new instance loads from SQLite via constructor');
};

# === Test 6: Reset ===

subtest 'Reset counter' => sub {
    my $m = Clam::Metrics->new(store => Clam::Store->new(db => ':memory:'));

    $m->inc('a', 10);
    $m->inc('b', 20);

    $m->reset('a');
    is($m->get('a'), 0, 'a reset');
    is($m->get('b'), 20, 'b untouched');

    $m->reset;
    is($m->get('b'), 0, 'all reset');
};

# === Test 7: LLM convenience ===

subtest 'llm_call increments counters' => sub {
    my $m = Clam::Metrics->new(store => Clam::Store->new(db => ':memory:'));

    $m->llm_call(model => 'gpt-4o', input_tokens => 100, output_tokens => 50, cost => 0.005);
    $m->llm_call(model => 'gpt-4o', input_tokens => 200, output_tokens => 80, cost => 0.01);

    is($m->get('llm.calls'), 2, 'total calls');
    is($m->get('llm.calls.gpt-4o'), 2, 'calls per model');
    is($m->get('llm.tokens.input'), 300, 'total input tokens');
    is($m->get('llm.tokens.output'), 130, 'total output tokens');
    is($m->get('llm.tokens.input.gpt-4o'), 300, 'input tokens per model');
    is($m->get('llm.cost'), 0.015, 'total cost');
};

# === Test 8: Rule/crystallize convenience ===

subtest 'rule_fired and crystallize' => sub {
    my $m = Clam::Metrics->new(store => Clam::Store->new(db => ':memory:'));

    $m->rule_fired('ancestor');
    $m->rule_fired('ancestor');
    $m->rule_fired('capital_of');
    $m->crystallize('ancestor');

    is($m->get('rules.fired'), 3, 'total rules fired');
    is($m->get('rules.fired.ancestor'), 2, 'ancestor fired twice');
    is($m->get('crystallizations'), 1, 'total crystallizations');
    is($m->get('crystallizations.ancestor'), 1, 'ancestor crystallized');
};

# === Test 9: Auto-flush on interval ===

subtest 'Auto-flush when interval exceeded' => sub {
    my $store3 = Clam::Store->new(db => ':memory:');
    my $m = Clam::Metrics->new(store => $store3, flush_ms => 1);

    $m->inc('test', 99);
    select(undef, undef, undef, 0.01);   # sleep 10ms > 1ms
    $m->inc('test');   # triggers auto-flush

    my $m2 = Clam::Metrics->new(store => $store3);
    $m2->sync;
    ok($m2->get('test') >= 99, 'auto-flushed to SQLite');
};

# === Test 10: Bus events (optional) ===

subtest 'Works without bus' => sub {
    my $m = Clam::Metrics->new(store => Clam::Store->new(db => ':memory:'));
    $m->inc('no_bus');
    is($m->get('no_bus'), 1, 'works without bus');
};

done_testing();
