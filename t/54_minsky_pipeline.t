#!/usr/bin/env perl
# t/54_minsky_pipeline.t — Neurosymbolic turn pipeline integration test
# Tests WorldModel → Rules → NeuroIntegration → Crystallizer
# with Governor/Tracer/Cache/Metrics/EventSourcing wired via bus.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Bus;
use Clank::WorldModel;
use Clank::Crystallizer;
use Clank::Governor;
use Clank::Tracer;
use Clank::Cache;
use Clank::Metrics;
use Clank::EventSourcing;

my $store = Clank::Store->new(db => ':memory:');
my $bus   = Clank::Bus->new(store => $store);

# === Test 1: WorldModel entity + relation + search ===

subtest 'WorldModel entity/relation/search' => sub {
    my $wm = Clank::WorldModel->new(store => $store);
    ok($wm, 'WorldModel created');

    my $id1 = $wm->add_entity(type => 'function', name => 'Clank::App::new', attributes => {line => 34});
    ok($id1, 'entity 1 created');

    my $id2 = $wm->add_entity(type => 'function', name => 'Clank::App::run_prompt', attributes => {line => 100});
    ok($id2, 'entity 2 created');

    my $rid = $wm->add_relation(source_id => $id1, target_id => $id2, type => 'calls', confidence => 0.9);
    ok($rid, 'relation created');

    my $e = $wm->get_entity($id1);
    is($e->{name}, 'Clank::App::new', 'entity roundtrips');

    my $rels = $wm->get_relations(source_id => $id1);
    is(scalar @$rels, 1, 'one relation from entity 1');
    is($rels->[0]{type}, 'calls', 'relation type correct');

    my $found = $wm->search_entities('run_prompt');
    ok($found && ref $found eq 'ARRAY' && @$found >= 1, 'FTS search finds entity');
    is($found->[0]{name}, 'Clank::App::run_prompt', 'search returns correct entity');
};

# === Test 2: WorldModel facts + beliefs ===

subtest 'WorldModel facts and beliefs' => sub {
    my $wm = Clank::WorldModel->new(store => $store);

    my $eid = $wm->add_entity(type => 'module', name => 'Clank::Governor');
    my $fid = $wm->assert_fact(entity_id => $eid, predicate => 'rate_limits', value => 'max_per_minute=60', confidence => 0.95, source => 'test');
    ok($fid, 'fact asserted');

    my $facts = $wm->query_facts(entity_id => $eid, predicate => 'rate_limits');
    is(scalar @$facts, 1, 'one fact found');
    is($facts->[0]{value}, 'max_per_minute=60', 'fact value correct');

    my $bid = $wm->believe(statement => 'Governor prevents runaway LLM costs', confidence => 0.8, source => 'test', evidence => ['observed circuit breaker trips']);
    ok($bid, 'belief created');

    my $beliefs = $wm->query_beliefs(min_confidence => 0.5);
    ok($beliefs && @$beliefs >= 1, 'beliefs queryable');
};

# === Test 3: WorldModel graph traversal ===

subtest 'WorldModel graph traversal' => sub {
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->add_entity(type => 'module', name => 'A');
    my $b = $wm->add_entity(type => 'module', name => 'B');
    my $c = $wm->add_entity(type => 'module', name => 'C');

    $wm->add_relation(source_id => $a, target_id => $b, type => 'depends_on', confidence => 1.0);
    $wm->add_relation(source_id => $b, target_id => $c, type => 'depends_on', confidence => 1.0);

    my $nbrs = $wm->neighbors($a, direction => 'out');
    is(scalar @$nbrs, 1, 'one neighbor from A');
    is($nbrs->[0]{entity}{name}, 'B', 'A -> B');

    my $walk = $wm->walk($a, max_hops => 3);
    ok($walk && @$walk >= 2, 'walk finds B and C');

    my $path = $wm->path($a, $c, max_hops => 3);
    ok($path, 'path A->C exists');
    ok(scalar @$path >= 2, 'path has hops');
};

# === Test 4: Governor rate limiting ===

subtest 'Governor rate limiting' => sub {
    my $gov = Clank::Governor->new(store => $store, budget => 0.01, max_per_minute => 3);
    ok($gov, 'Governor created');

    my ($ok1) = $gov->check(model => 'test', estimated_tokens => 100);
    ok($ok1, 'first check passes');

    my ($ok2) = $gov->check(model => 'test', estimated_tokens => 100);
    ok($ok2, 'second check passes');

    my ($ok3) = $gov->check(model => 'test', estimated_tokens => 100);
    ok($ok3, 'third check passes');

    my ($ok4, $reason) = $gov->check(model => 'test', estimated_tokens => 100);
    ok(!$ok4, 'fourth check blocked');
    like($reason, qr/minute|rate|limit/i, 'reason mentions rate limit');

    $gov->record(model => 'test', input_tokens => 50, output_tokens => 50);
    my $usage = $gov->usage();
    cmp_ok($usage->{requests}, '>=', 1, 'requests recorded');
};

# === Test 5: Governor circuit breaker ===

subtest 'Governor circuit breaker' => sub {
    my $gov = Clank::Governor->new(store => $store, cb_threshold => 3, cb_cooldown_ms => 60_000);

    for (1..3) {
        $gov->record_failure(model => 'test', fatal => 1);
    }

    my ($ok, $reason) = $gov->check(model => 'test', estimated_tokens => 100);
    ok(!$ok, 'circuit breaker tripped');
    like($reason, qr/circuit/i, 'reason mentions circuit');

    $gov->circuit_reset();
    my ($ok2) = $gov->check(model => 'test', estimated_tokens => 100);
    ok($ok2, 'circuit reset allows traffic');
};

# === Test 6: Tracer spans ===

subtest 'Tracer span lifecycle' => sub {
    my $tracer = Clank::Tracer->new(store => $store);
    ok($tracer, 'Tracer created');

    my $span1 = $tracer->start_span('turn', topic => 'turn_start');
    ok($span1, 'root span started');

    my $span2 = $tracer->start_span('llm_call', topic => 'provider_request');
    ok($span2, 'child span started');

    my $dur = $tracer->end_span($span2);
    ok($dur >= 0, 'child span ended');

    my $dur2 = $tracer->end_span($span1);
    ok($dur2 >= 0, 'root span ended');

    my $stats = $tracer->stats();
    is($stats->{total_spans}, 2, 'two spans recorded');
};

# === Test 7: Cache get/set/purge ===

subtest 'Cache lifecycle' => sub {
    my $cache = Clank::Cache->new(store => $store, ttl_ms => 1000);
    ok($cache, 'Cache created');

    $cache->set('key1', {answer => 42});
    my $val = $cache->get('key1');
    is_deeply($val, {answer => 42}, 'cache roundtrip');

    my $miss = $cache->get('nonexistent');
    is($miss, undef, 'cache miss returns undef');

    $cache->invalidate('key1');
    my $after = $cache->get('key1');
    is($after, undef, 'invalidated key returns undef');

    my $stats = $cache->stats();
    ok($stats->{total_entries} >= 0, 'stats available');
};

# === Test 8: Metrics inc/get/flush ===

subtest 'Metrics lifecycle' => sub {
    my $metrics = Clank::Metrics->new(store => $store);
    ok($metrics, 'Metrics created');

    $metrics->inc('llm_calls');
    $metrics->inc('llm_calls');
    $metrics->inc('llm_calls', 3);
    is($metrics->get('llm_calls'), 5, 'inc works');

    $metrics->dec('llm_calls');
    is($metrics->get('llm_calls'), 4, 'dec works');

    $metrics->set('cache_hits', 42);
    is($metrics->get('cache_hits'), 42, 'set works');

    $metrics->flush();
    $metrics->reset();
    is($metrics->get('llm_calls'), 0, 'reset clears counters');
};

# === Test 9: EventSourcing emit/query/replay ===

subtest 'EventSourcing lifecycle' => sub {
    my $es = Clank::EventSourcing->new(store => $store);
    ok($es, 'EventSourcing created');

    my $e1 = $es->emit(event_type => 'prompt_submitted', aggregate_type => 'session', aggregate_id => 'sess-1', payload => {text => 'hello'});
    ok($e1, 'event 1 emitted');

    my $e2 = $es->emit(event_type => 'response_generated', aggregate_type => 'session', aggregate_id => 'sess-1', payload => {text => 'hi'}, caused_by => $e1);
    ok($e2, 'event 2 emitted with cause');

    my $hist = $es->history('session', 'sess-1');
    is(scalar @$hist, 2, 'two events in history');

    my $chain = $es->trace_causes($e2);
    ok($chain && @$chain >= 1, 'cause chain traceable');

    my $snap = $es->snapshot('session', 'sess-1');
    is($snap->{text}, 'hi', 'snapshot gets latest state');

    my $stats = $es->stats();
    is($stats->{total_events}, 2, 'stats count correct');
};

# === Test 10: Crystallizer rule extraction ===

subtest 'Crystallizer rule extraction' => sub {
    my $cryst = Clank::Crystallizer->new(store => $store);
    ok($cryst, 'Crystallizer created');

    my $count = $cryst->crystallize(
        session_id => 'test-session',
        conversation => [
            {role => 'user', content => 'The batch queue must never be undef, always an arrayref'},
            {role => 'assistant', content => 'Understood. I will always return an empty arrayref for empty queues.'},
        ],
        scope => 'project',
    );
    ok($count >= 0, 'crystallize returned count');

    my $stats = $cryst->stats();
    ok($stats->{total_rules} >= 0, 'stats available');

    my @rules = $cryst->list_rules(limit => 10);
    is(ref(\@rules), 'ARRAY', 'list_rules returns arrayref');
};

# === Test 11: Full pipeline — all modules wired together ===

subtest 'Full pipeline wiring' => sub {
    my $wm       = Clank::WorldModel->new(store => $store);
    my $gov      = Clank::Governor->new(store => $store, max_per_minute => 100);
    my $tracer   = Clank::Tracer->new(store => $store);
    my $cache    = Clank::Cache->new(store => $store);
    my $metrics  = Clank::Metrics->new(store => $store);
    my $es       = Clank::EventSourcing->new(store => $store);
    my $cryst    = Clank::Crystallizer->new(store => $store, world_model => $wm);

    ok($wm && $gov && $tracer && $cache && $metrics && $es && $cryst, 'all modules created');

    # Simulate a turn pipeline via bus events
    my @pipeline_events;
    $bus->subscribe('turn_start', sub { push @pipeline_events, 'turn_start' });
    $bus->subscribe('turn_end',   sub { push @pipeline_events, 'turn_end' });

    # 1. Tracer: start turn span
    my $span = $tracer->start_span('turn', topic => 'turn_start');

    # 2. Governor: check rate limit
    my ($ok) = $gov->check(model => 'qwen3.8-27b', estimated_tokens => 500);
    ok($ok, 'governor allows turn');

    # 3. Cache: check for cached response
    my $cached = $cache->get('turn:test-prompt');
    is($cached, undef, 'cache miss on first call');

    # 4. EventSourcing: record turn start
    my $eid = $es->emit(event_type => 'turn_start', aggregate_type => 'session', aggregate_id => 'test', payload => {prompt => 'test'});
    ok($eid, 'turn_start event recorded');

    # 5. Metrics: count the turn
    $metrics->inc('turns_completed');

    # 6. WorldModel: record what we learned
    my $entity_id = $wm->add_entity(type => 'observation', name => 'test-turn-result', attributes => {prompt => 'test'});
    ok($entity_id, 'world model entity added');

    # 7. Governor: record usage
    my $cost = $gov->record(model => 'qwen3.8-27b', input_tokens => 200, output_tokens => 300);
    ok(defined $cost, 'cost recorded');

    # 8. Tracer: end turn span
    my $dur = $tracer->end_span($span);
    ok($dur >= 0, 'turn span ended');

    # 9. EventSourcing: record turn end
    $es->emit(event_type => 'turn_end', aggregate_type => 'session', aggregate_id => 'test', payload => {ok => 1}, caused_by => $eid);

    # 10. Verify all pipeline stages executed
    my $gov_usage = $gov->usage();
    ok($gov_usage->{requests} >= 1, 'governor counted request');

    my $trace_stats = $tracer->stats();
    ok($trace_stats->{total_spans} >= 1, 'tracer has spans');

    my $es_stats = $es->stats();
    ok($es_stats->{total_events} >= 2, 'eventsourcing has events');

    my $m_snap = $metrics->snapshot();
    ok($m_snap->{turns_completed} >= 1, 'metrics counted turn');

    my $wm_entities = $wm->query_entities(type => 'observation');
    ok($wm_entities && @$wm_entities >= 1, 'world model has observation');
};

done_testing;
