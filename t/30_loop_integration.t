#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Bus;
use Clank::Session;
use Clank::Provider::Mock;
use Clank::Loop;
use Clank::Governor;
use Clank::Tracer;
use Clank::Cache;
use Clank::Metrics;
use Clank::Wit::API;

# === Test 1: Loop with no primitives (backwards compatible) ===

subtest 'Loop without primitives' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus   = Clank::Bus->new(store => $store);
    my $prov  = Clank::Provider::Mock->new(model => 'mock');
    my $session = Clank::Session->new(store => $store, bus => $bus, provider => $prov);

    my $loop = Clank::Loop->new(session => $session);
    isa_ok($loop, 'Clank::Loop');
    ok(!$loop->{governor}, 'no governor');
    ok(!$loop->{tracer}, 'no tracer');
    ok(!$loop->{cache}, 'no cache');
    ok(!$loop->{metrics}, 'no metrics');
};

# === Test 2: Loop with all primitives constructed ===

subtest 'Loop with all primitives' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus   = Clank::Bus->new(store => $store);
    my $prov  = Clank::Provider::Mock->new(model => 'mock');
    my $session = Clank::Session->new(store => $store, bus => $bus, provider => $prov);

    my $gov = Clank::Governor->new(store => $store, bus => $bus, session_id => 'test');
    my $trc = Clank::Tracer->new(store => $store);
    my $cac = Clank::Cache->new(store => $store, namespace => 'llm');
    my $met = Clank::Metrics->new(store => $store);

    my $loop = Clank::Loop->new(
        session  => $session,
        governor => $gov,
        tracer   => $trc,
        cache    => $cac,
        metrics  => $met,
    );

    isa_ok($loop->{governor}, 'Clank::Governor');
    isa_ok($loop->{tracer}, 'Clank::Tracer');
    isa_ok($loop->{cache}, 'Clank::Cache');
    isa_ok($loop->{metrics}, 'Clank::Metrics');
};

# === Test 3: Loop with governor blocks on budget ===

subtest 'Governor blocks on budget' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus   = Clank::Bus->new(store => $store);
    my $prov  = Clank::Provider::Mock->new(model => 'mock');
    my $session = Clank::Session->new(store => $store, bus => $bus, provider => $prov);

    my $gov = Clank::Governor->new(
        store => $store, bus => $bus, session_id => 'test',
        budget => 0.0001,   # tiny budget
        pricing => { mock => { input => 1.0, output => 1.0 } },  # expensive mock
    );

    my $loop = Clank::Loop->new(
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
    my $store = Clank::Store->new(db => ':memory:');
    my $bus   = Clank::Bus->new(store => $store);
    my $prov  = Clank::Provider::Mock->new(model => 'mock');
    my $session = Clank::Session->new(store => $store, bus => $bus, provider => $prov);

    my $met = Clank::Metrics->new(store => $store);

    my $loop = Clank::Loop->new(
        session  => $session,
        metrics  => $met,
    );

    $loop->run_prompt('hello');

    ok($met->get('agent.runs') >= 1, 'agent.runs incremented');
    ok($met->get('agent.turns') >= 1, 'agent.turns incremented');
};

# === Test 5: Tracer creates spans ===

subtest 'Tracer creates spans' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus   = Clank::Bus->new(store => $store);
    my $prov  = Clank::Provider::Mock->new(model => 'mock');
    my $session = Clank::Session->new(store => $store, bus => $bus, provider => $prov);

    my $trc = Clank::Tracer->new(store => $store);

    my $loop = Clank::Loop->new(
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
    my $store = Clank::Store->new(db => ':memory:');
    my $bus   = Clank::Bus->new(store => $store);
    my $prov  = Clank::Provider::Mock->new(model => 'mock');
    my $session = Clank::Session->new(store => $store, bus => $bus, provider => $prov);

    my $cac = Clank::Cache->new(store => $store, namespace => 'llm');

    my $loop = Clank::Loop->new(
        session  => $session,
        cache    => $cac,
    );

    # First call: cache miss.
    $loop->run_prompt('what is 2+2?');
    my $s1 = $cac->stats;
    ok($s1->{misses} >= 1, 'cache miss on first call');

    # Second call with same prompt: cache hit.
    my $session2 = Clank::Session->new(store => $store, bus => $bus, provider => $prov);
    my $loop2 = Clank::Loop->new(
        session  => $session2,
        cache    => $cac,
    );
    $loop2->run_prompt('what is 2+2?');
    my $s2 = $cac->stats;
    ok($s2->{hits} >= 1, 'cache hit on second call');
};

# === Test 7: All primitives together ===

subtest 'All primitives together' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus   = Clank::Bus->new(store => $store);
    my $prov  = Clank::Provider::Mock->new(model => 'mock');
    my $session = Clank::Session->new(store => $store, bus => $bus, provider => $prov);

    my $gov = Clank::Governor->new(store => $store, bus => $bus, session_id => 'test');
    my $trc = Clank::Tracer->new(store => $store);
    my $cac = Clank::Cache->new(store => $store, namespace => 'llm');
    my $met = Clank::Metrics->new(store => $store);

    my $loop = Clank::Loop->new(
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

# === Test 5: Knowledge request pipeline ===

subtest 'Knowledge request pipeline' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus   = Clank::Bus->new(store => $store);
    my $prov  = Clank::Provider::Mock->new(model => 'mock');
    my $session = Clank::Session->new(store => $store, bus => $bus, provider => $prov);

    # Set up world model with some facts.
    require Clank::WorldModel;
    my $wm = Clank::WorldModel->new(store => $store);
    $wm->add_entity(id => 'perl', type => 'language', name => 'Perl');
    $wm->assert_fact(entity_id => 'perl', predicate => 'is', value => 'a scripting language', confidence => 0.9);
    $wm->believe(statement => 'Perl is good for text processing', confidence => 0.8);

    # Register world model on the bus.
    my $api = Clank::Wit::API->new(bus => $bus, store => $store);
    $wm->register($api);

    # Publish a knowledge request.
    my $kr = $bus->publish('context.knowledge_request', { prompt => 'tell me about Perl' });
    ok(scalar @{ $kr->{results} }, 'knowledge request got results');

    # Check that facts were returned.
    my $got_facts = 0;
    for my $r (@{ $kr->{results} }) {
        next unless ref $r eq 'HASH';
        if ($r->{facts} && ref $r->{facts} eq 'ARRAY' && @{ $r->{facts} }) {
            $got_facts = 1;
            my @types = map { $_->{type} // '' } @{ $r->{facts} };
            ok(grep { $_ eq 'entity' || $_ eq 'fact' } @types,
               'knowledge results contain entities or facts');
        }
    }
    ok($got_facts, 'world model contributed facts to knowledge request');
};

# === Test 6: Context-aware pruning ===

subtest 'Context-aware pruning' => sub {
    require Clank::Session::Messages;

    # Build a chain with 30 messages.
    my @chain;
    for my $i (1..30) {
        push @chain, {
            id      => "msg_$i",
            role    => $i % 2 ? 'user' : 'assistant',
            content => $i % 2 ? "question $i" : "answer $i",
        };
    }

    # Prune: keep last 20.
    my $pruned = Clank::Session::Messages::prune_context(\@chain, keep_recent => 20);
    ok(scalar @$pruned < 30, 'pruning reduced message count');
    ok(scalar @$pruned >= 20, 'pruning kept at least keep_recent messages');

    # Last message should still be there.
    is($pruned->[-1]{id}, 'msg_30', 'most recent message preserved');

    # First message should be dropped.
    my @ids = map { $_->{id} } @$pruned;
    ok(!grep { $_ eq 'msg_1' } @ids, 'oldest message pruned');
};

# === Test 7: Pruning preserves compaction entries ===

subtest 'Pruning preserves compaction entries' => sub {
    require Clank::Session::Messages;

    my @chain;
    # Add a compaction entry at position 5.
    for my $i (1..30) {
        if ($i == 5) {
            push @chain, { id => "comp_5", role => 'compaction', content => { summary => 'old stuff' } };
        } else {
            push @chain, {
                id      => "msg_$i",
                role    => $i % 2 ? 'user' : 'assistant',
                content => $i % 2 ? "question $i" : "answer $i",
            };
        }
    }

    my $pruned = Clank::Session::Messages::prune_context(\@chain, keep_recent => 20);
    my @ids = map { $_->{id} } @$pruned;
    ok(grep { $_ eq 'comp_5' } @ids, 'compaction entry preserved');
};

# === Test 8: ContextRules evaluates correctly ===

subtest 'ContextRules evaluation' => sub {
    require Clank::ContextRules;

    my $cr = Clank::ContextRules->new();

    # Perl edit should inject strict/warnings rule.
    my $inj = $cr->evaluate(prompt => 'edit Foo.pm to add a function');
    ok(grep { /strict and warnings/ } @$inj, 'Perl file triggers strict/warnings rule');

    # Database prompt should inject db context.
    $inj = $cr->evaluate(prompt => 'query the database for users');
    ok(grep { /Database tools/ } @$inj, 'database prompt triggers db context');

    # Git prompt should inject git context.
    $inj = $cr->evaluate(prompt => 'commit my changes to git');
    ok(grep { /Git tools/ } @$inj, 'git prompt triggers git context');

    # Unrelated prompt should not inject anything.
    $inj = $cr->evaluate(prompt => 'hello world');
    ok(!@$inj, 'unrelated prompt gets no injections');

    # format_for_prompt returns a block.
    my $block = $cr->format_for_prompt(prompt => 'edit test.pm');
    like($block, qr/^Rules for this task:/m, 'format_for_prompt returns rules block');
    like($block, qr/- /, 'format_for_prompt has bullet points');
};

done_testing;
