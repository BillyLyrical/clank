#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clam::Store;
use Clam::Bus;
use Clam::Session;
use Clam::Provider::Mock;
use Clam::Loop;
use Clam::Governor;
use Clam::Tracer;
use Clam::Cache;
use Clam::Metrics;

# === Test 1: Loop with no primitives (backwards compatible) ===

subtest 'Loop without primitives' => sub {
    my $store = Clam::Store->new(db => ':memory:');
    my $bus   = Clam::Bus->new(store => $store);
    my $prov  = Clam::Provider::Mock->new(model => 'mock');
    my $session = Clam::Session->new(store => $store, bus => $bus, provider => $prov);

    my $loop = Clam::Loop->new(session => $session);
    isa_ok($loop, 'Clam::Loop');
    ok(!$loop->{governor}, 'no governor');
    ok(!$loop->{tracer}, 'no tracer');
    ok(!$loop->{cache}, 'no cache');
    ok(!$loop->{metrics}, 'no metrics');
};

# === Test 2: Loop with all primitives constructed ===

subtest 'Loop with all primitives' => sub {
    my $store = Clam::Store->new(db => ':memory:');
    my $bus   = Clam::Bus->new(store => $store);
    my $prov  = Clam::Provider::Mock->new(model => 'mock');
    my $session = Clam::Session->new(store => $store, bus => $bus, provider => $prov);

    my $gov = Clam::Governor->new(store => $store, bus => $bus, session_id => 'test');
    my $trc = Clam::Tracer->new(store => $store);
    my $cac = Clam::Cache->new(store => $store, namespace => 'llm');
    my $met = Clam::Metrics->new(store => $store);

    my $loop = Clam::Loop->new(
        session  => $session,
        governor => $gov,
        tracer   => $trc,
        cache    => $cac,
        metrics  => $met,
    );

    isa_ok($loop->{governor}, 'Clam::Governor');
    isa_ok($loop->{tracer}, 'Clam::Tracer');
    isa_ok($loop->{cache}, 'Clam::Cache');
    isa_ok($loop->{metrics}, 'Clam::Metrics');
};

# === Test 3: Loop with governor blocks on budget ===

subtest 'Governor blocks on budget' => sub {
    my $store = Clam::Store->new(db => ':memory:');
    my $bus   = Clam::Bus->new(store => $store);
    my $prov  = Clam::Provider::Mock->new(model => 'mock');
    my $session = Clam::Session->new(store => $store, bus => $bus, provider => $prov);

    my $gov = Clam::Governor->new(
        store => $store, bus => $bus, session_id => 'test',
        budget => 0.0001,   # tiny budget
        pricing => { mock => { input => 1.0, output => 1.0 } },  # expensive mock
    );

    my $loop = Clam::Loop->new(
        session  => $session,
        governor => $gov,
    );

    # Spend the budget manually (Mock provider has no usage in response).
    $gov->record(model => 'mock', input_tokens => 1, output_tokens => 1);

    my $result = $loop->run_prompt('hello');
    ok(!$result->{ok}, 'loop returned error');
    like($result->{error}, qr/throttled|budget/, 'error mentions throttled or budget');
};

# === Test 4: Metrics increments on run ===

subtest 'Metrics increments on run' => sub {
    my $store = Clam::Store->new(db => ':memory:');
    my $bus   = Clam::Bus->new(store => $store);
    my $prov  = Clam::Provider::Mock->new(model => 'mock');
    my $session = Clam::Session->new(store => $store, bus => $bus, provider => $prov);

    my $met = Clam::Metrics->new(store => $store);

    my $loop = Clam::Loop->new(
        session  => $session,
        metrics  => $met,
    );

    $loop->run_prompt('hello');

    ok($met->get('agent.runs') >= 1, 'agent.runs incremented');
    ok($met->get('agent.turns') >= 1, 'agent.turns incremented');
};

# === Test 5: Tracer creates spans ===

subtest 'Tracer creates spans' => sub {
    my $store = Clam::Store->new(db => ':memory:');
    my $bus   = Clam::Bus->new(store => $store);
    my $prov  = Clam::Provider::Mock->new(model => 'mock');
    my $session = Clam::Session->new(store => $store, bus => $bus, provider => $prov);

    my $trc = Clam::Tracer->new(store => $store);

    my $loop = Clam::Loop->new(
        session  => $session,
        tracer   => $trc,
    );

    $loop->run_prompt('hello');

    my $spans = $trc->query_spans(name_like => 'agent%');
    ok(scalar @$spans >= 1, 'agent span created');

    my $turns = $trc->query_spans(name_like => 'turn%');
    ok(scalar @$turns >= 1, 'turn span created');
};

# === Test 6: Cache stores and retrieves ===

subtest 'Cache integration' => sub {
    my $store = Clam::Store->new(db => ':memory:');
    my $bus   = Clam::Bus->new(store => $store);
    my $prov  = Clam::Provider::Mock->new(model => 'mock');
    my $session = Clam::Session->new(store => $store, bus => $bus, provider => $prov);

    my $cac = Clam::Cache->new(store => $store, namespace => 'llm');

    my $loop = Clam::Loop->new(
        session  => $session,
        cache    => $cac,
    );

    # First call: cache miss.
    $loop->run_prompt('what is 2+2?');
    my $s1 = $cac->stats;
    ok($s1->{misses} >= 1, 'cache miss on first call');

    # Second call with same prompt: cache hit.
    my $session2 = Clam::Session->new(store => $store, bus => $bus, provider => $prov);
    my $loop2 = Clam::Loop->new(
        session  => $session2,
        cache    => $cac,
    );
    $loop2->run_prompt('what is 2+2?');
    my $s2 = $cac->stats;
    ok($s2->{hits} >= 1, 'cache hit on second call');
};

# === Test 7: All primitives together ===

subtest 'All primitives together' => sub {
    my $store = Clam::Store->new(db => ':memory:');
    my $bus   = Clam::Bus->new(store => $store);
    my $prov  = Clam::Provider::Mock->new(model => 'mock');
    my $session = Clam::Session->new(store => $store, bus => $bus, provider => $prov);

    my $gov = Clam::Governor->new(store => $store, bus => $bus, session_id => 'test');
    my $trc = Clam::Tracer->new(store => $store);
    my $cac = Clam::Cache->new(store => $store, namespace => 'llm');
    my $met = Clam::Metrics->new(store => $store);

    my $loop = Clam::Loop->new(
        session  => $session,
        governor => $gov,
        tracer   => $trc,
        cache    => $cac,
        metrics  => $met,
    );

    my $result = $loop->run_prompt('hello');
    ok($result->{ok}, 'loop succeeded');

    # All primitives recorded something.
    ok($met->get('agent.runs') >= 1, 'metrics recorded runs');
    my $spans = $trc->query_spans(name_like => 'agent%');
    ok(scalar @$spans >= 1, 'tracer recorded agent span');
    # Governor records only when resp has usage (mock doesn't), so just verify it's functional.
    my $usage = $gov->usage;
    ok(ref $usage eq 'HASH', 'governor usage returns hashref');
};

done_testing;
