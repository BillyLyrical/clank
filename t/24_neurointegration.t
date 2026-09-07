#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use AI::Clam::Store;
use AI::Clam::Bus;
use AI::Clam::WorldModel;
use AI::Clam::NeuroIntegration;
use AI::Clam::Wit::API;

sub _make_api {
    my ($store, $bus) = @_;
    return AI::Clam::Wit::API->new(bus => $bus, store => $store);
}

# === Test 1: Construction ===

subtest 'Construction' => sub {
    my $store = AI::Clam::Store->new(db => ':memory:');
    my $bus = AI::Clam::Bus->new(store => $store);
    my $wm = AI::Clam::WorldModel->new(store => $store);
    my $api = _make_api($store, $bus);

    my $ni = AI::Clam::NeuroIntegration->new(world_model => $wm);
    $ni->register($api);
    isa_ok($ni, 'AI::Clam::NeuroIntegration');
};

# === Test 2: Phase 1 — context injection ===

subtest 'Phase 1: injects world model facts into context' => sub {
    my $store = AI::Clam::Store->new(db => ':memory:');
    my $bus = AI::Clam::Bus->new(store => $store);
    my $wm = AI::Clam::WorldModel->new(store => $store);
    my $api = _make_api($store, $bus);

    my $id1 = $wm->add_entity(type => 'concept', name => 'Perl', attributes => { language => 'scripting' });
    my $id2 = $wm->add_entity(type => 'concept', name => 'Python', attributes => { language => 'scripting' });

    my $ni = AI::Clam::NeuroIntegration->new(world_model => $wm);
    $ni->register($api);

    my $result = $bus->publish('context', {
        messages => [{ role => 'user', content => 'Tell me about Perl' }],
    });

    my @injected = grep { ref $_ eq 'HASH' && defined $_->{message} } @{$result->{results}};
    if ($store->has_fts) {
        ok(scalar @injected >= 1, 'context hook returned a message');
        like($injected[0]{message}, qr/Perl/, 'injected message mentions Perl');
    } else {
        pass('FTS not available, context injection skipped (expected)');
    }
};

# === Test 3: Phase 1 — no injection for empty query ===

subtest 'Phase 1: no injection for empty conversation' => sub {
    my $store = AI::Clam::Store->new(db => ':memory:');
    my $bus = AI::Clam::Bus->new(store => $store);
    my $wm = AI::Clam::WorldModel->new(store => $store);
    my $api = _make_api($store, $bus);
    $wm->add_entity(type => 'concept', name => 'Perl', attributes => {});

    my $ni = AI::Clam::NeuroIntegration->new(world_model => $wm);
    $ni->register($api);

    my $result = $bus->publish('context', { messages => [] });
    my @injected = grep { ref $_ eq 'HASH' && defined $_->{message} } @{$result->{results}};
    is(scalar @injected, 0, 'no injection for empty messages');
};

# === Test 4: Phase 2 — validation catches contradictions ===

subtest 'Phase 2: validation catches contradictions' => sub {
    my $store = AI::Clam::Store->new(db => ':memory:');
    my $bus = AI::Clam::Bus->new(store => $store);
    my $wm = AI::Clam::WorldModel->new(store => $store);
    my $api = _make_api($store, $bus);

    my $ent_id = $wm->add_entity(type => 'concept', name => 'Perl');
    $wm->assert_fact(entity_id => $ent_id, predicate => 'is', value => 'a scripting language');

    my $ni = AI::Clam::NeuroIntegration->new(world_model => $wm, validate => 1);
    $ni->register($api);

    my $result = $bus->publish('message_end', {
        role    => 'assistant',
        content => { text => 'Perl is not a scripting language', tool_calls => [] },
    });

    my @violations = grep { ref $_ eq 'HASH' && ref $_->{content}{_violations} eq 'ARRAY' } @{$result->{results}};
    ok(scalar @violations >= 1, 'contradiction detected');
};

# === Test 5: Phase 2 — no violation for correct output ===

subtest 'Phase 2: no violation for correct output' => sub {
    my $store = AI::Clam::Store->new(db => ':memory:');
    my $bus = AI::Clam::Bus->new(store => $store);
    my $wm = AI::Clam::WorldModel->new(store => $store);
    my $api = _make_api($store, $bus);

    my $ent_id = $wm->add_entity(type => 'concept', name => 'Perl');
    $wm->assert_fact(entity_id => $ent_id, predicate => 'is', value => 'a scripting language');

    my $ni = AI::Clam::NeuroIntegration->new(world_model => $wm, validate => 1);
    $ni->register($api);

    my $result = $bus->publish('message_end', {
        role    => 'assistant',
        content => { text => 'Perl is a great programming language', tool_calls => [] },
    });

    my @violations = grep { ref $_ eq 'HASH' && ref $_->{content}{_violations} eq 'ARRAY' } @{$result->{results}};
    is(scalar @violations, 0, 'no violation for correct output');
};

# === Test 6: Phase 3 — knowledge extraction ===

subtest 'Phase 3: extracts entities from conversation' => sub {
    my $store = AI::Clam::Store->new(db => ':memory:');
    my $bus = AI::Clam::Bus->new(store => $store);
    my $wm = AI::Clam::WorldModel->new(store => $store);
    my $api = _make_api($store, $bus);

    my $sid = $store->create_session(title => 'test');
    $store->append_message(session_id => $sid, role => 'user', content => 'I like Tokyo very much');
    $store->append_message(session_id => $sid, role => 'assistant', content => 'Tokyo is a great city in Japan');

    my $ni = AI::Clam::NeuroIntegration->new(world_model => $wm, extract => 1);
    $ni->register($api);

    $bus->publish('agent_end', { session_id => $sid });

    my $entities = $wm->query_entities(type => 'concept');
    ok(scalar @$entities > 0, 'entities extracted');
    my @names = map { $_->{name} } @$entities;
    ok(grep { /Tokyo/ } @names, 'Tokyo was extracted');
};

# === Test 7: Phase 3 — no extraction when disabled ===

subtest 'Phase 3: no extraction when disabled' => sub {
    my $store = AI::Clam::Store->new(db => ':memory:');
    my $bus = AI::Clam::Bus->new(store => $store);
    my $wm = AI::Clam::WorldModel->new(store => $store);
    my $api = _make_api($store, $bus);

    my $ni = AI::Clam::NeuroIntegration->new(world_model => $wm, extract => 0);
    $ni->register($api);

    my $sid = $store->create_session(title => 'test');
    $store->append_message(session_id => $sid, role => 'user', content => 'Hello');
    $bus->publish('agent_end', { session_id => $sid });

    my $entities = $wm->query_entities;
    is(scalar @$entities, 0, 'no extraction when disabled');
};

# === Test 8: Entity extraction helpers ===

subtest 'Entity extraction' => sub {
    my @ents = AI::Clam::NeuroIntegration::_extract_entities(
        'Alice went to Paris with Bob');
    my @names = map { $_->{name} } @ents;

    ok(grep { $_ eq 'Alice' } @names, 'extracted Alice');
    ok(grep { $_ eq 'Paris' } @names, 'extracted Paris');
    ok(grep { $_ eq 'Bob' } @names, 'extracted Bob');
};

subtest 'Fact extraction' => sub {
    my @facts = AI::Clam::NeuroIntegration::_extract_facts(
        'Perl is a scripting language. Python has many libraries.');
    ok(scalar @facts >= 2, 'extracted facts');
    my @values = map { $_->{value} } @facts;
    ok(grep { /Perl/ } @values, 'Perl fact');
    ok(grep { /Python/ } @values, 'Python fact');
};

# === Test 9: Metrics integration ===

subtest 'Metrics tracking' => sub {
    my $store = AI::Clam::Store->new(db => ':memory:');
    my $bus = AI::Clam::Bus->new(store => $store);
    my $wm = AI::Clam::WorldModel->new(store => $store);
    my $api = _make_api($store, $bus);

    require AI::Clam::Metrics;
    my $metrics = AI::Clam::Metrics->new(store => $store);
    $wm->add_entity(type => 'concept', name => 'Test', attributes => {});

    my $ni = AI::Clam::NeuroIntegration->new(
        world_model => $wm, metrics => $metrics);
    $ni->register($api);

    $bus->publish('context', { messages => [{ role => 'user', content => 'Tell me about Test' }] });
    $bus->publish('message_end', { role => 'assistant', content => { text => 'Test is fine', tool_calls => [] } });

    ok($metrics->get('neuro.validations') > 0, 'validations counted');
};

# === Test 10: Graceful degradation without world model ===

subtest 'Works without world model or rules' => sub {
    my $store = AI::Clam::Store->new(db => ':memory:');
    my $bus = AI::Clam::Bus->new(store => $store);
    my $api = _make_api($store, $bus);

    my $ni = AI::Clam::NeuroIntegration->new;
    $ni->register($api);

    $bus->publish('context', { messages => [{ role => 'user', content => 'hello' }] });
    $bus->publish('message_end', { role => 'assistant', content => { text => 'hi', tool_calls => [] } });
    $bus->publish('agent_end', {});

    ok(1, 'survives without world model or rules');
};

done_testing();
