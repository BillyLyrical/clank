#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use AI::Clam::Store;
use AI::Clam::Rules;

my $store = AI::Clam::Store->new(db => ':memory:');

# === Test 1: Backward Chaining ===

subtest 'Backward Chaining - prove existing fact' => sub {
    my $engine = AI::Clam::Rules->engine(store => $store, strategy => 'first');
    
    $engine->assert_fact('person', { name => 'Alice', age => 30 });
    
    my $proof = $engine->prove('person', { name => 'Alice' });
    
    ok($proof->{proven}, 'Existing fact is proven');
    is($proof->{steps}, 1, 'Single step proof');
    is($proof->{proof}[0]{action}, 'fact_exists', 'Action is fact_exists');
};

subtest 'Backward Chaining - prove via rule' => sub {
    my $store2 = AI::Clam::Store->new(db => ':memory:');
    my $engine = AI::Clam::Rules->engine(store => $store2, strategy => 'first');
    
    $engine->assert_fact('parent', { parent => 'Bob', child => 'Alice' });
    
    $engine->add(AI::Clam::Rules::Rule->new(
        name       => 'parent_to_relative',
        type       => 'production',
        priority   => 10,
        conditions => [
            { type => 'parent', parent => 'Bob', child => 'Alice' },
        ],
        action     => sub {
            my $ctx = shift;
            my $match = $ctx->{match};
            return {
                type       => 'relative',
                attributes => {
                    person => 'Alice',
                    relation => 'child_of',
                    of => 'Bob',
                },
            };
        },
    ));
    
    my $proof = $engine->prove('relative', { person => 'Alice' });
    
    ok($proof->{proven}, 'Proven via rule');
    ok($proof->{steps} > 1, 'Multiple steps');
};

# === Test 2: Negation as Failure ===

subtest 'Negation as Failure - not_exists' => sub {
    my $store3 = AI::Clam::Store->new(db => ':memory:');
    my $engine = AI::Clam::Rules->engine(store => $store3, strategy => 'first');
    
    $engine->assert_fact('status', { name => 'active' });
    
    ok($engine->not_exists('status', { name => 'inactive' }), 'not_exists returns true for missing');
    ok(!$engine->not_exists('status', { name => 'active' }), 'not_exists returns false for existing');
};

subtest 'Negation as Failure - in production rule' => sub {
    my $store4 = AI::Clam::Store->new(db => ':memory:');
    my $engine = AI::Clam::Rules->engine(store => $store4, strategy => 'first');
    
    $engine->assert_fact('user', { name => 'Bob' });
    
    $engine->add(AI::Clam::Rules::Rule->new(
        name       => 'check_banned',
        type       => 'production',
        priority   => 5,
        conditions => [
            { type => 'user', name => 'Bob' },
            { type => 'ban', name => 'Bob', not_exists => 1 },
        ],
        action     => sub {
            return {
                type       => 'allowed',
                attributes => { user => 'Bob', reason => 'not_banned' },
            };
        },
    ));
    
    my $result = $engine->chain();
    
    ok($result->{facts_asserted} > 0, 'Rule fired with negation');
    my $allowed = $engine->query_facts('allowed');
    ok(@$allowed, 'Allowed fact asserted');
    is($allowed->[0]{attributes}{reason}, 'not_banned', 'Reason is not_banned');
};

# === Test 3: Conflict Resolution ===

subtest 'Conflict Resolution - priority wins' => sub {
    my $store5 = AI::Clam::Store->new(db => ':memory:');
    my $engine = AI::Clam::Rules->engine(store => $store5, strategy => 'first');
    
    $engine->assert_fact('event', { event_type => 'alert' });
    
    $engine->add(AI::Clam::Rules::Rule->new(
        name       => 'low_priority',
        type       => 'production',
        priority   => 1,
        conditions => [{ type => 'event', event_type => 'alert' }],
        action     => sub { return { type => 'response', attributes => { level => 'low' } }; },
    ));
    
    $engine->add(AI::Clam::Rules::Rule->new(
        name       => 'high_priority',
        type       => 'production',
        priority   => 100,
        conditions => [{ type => 'event', event_type => 'alert' }],
        action     => sub { return { type => 'response', attributes => { level => 'high' } }; },
    ));
    
    my $result = $engine->chain_with_resolution();
    
    my $responses = $engine->query_facts('response');
    ok(@$responses == 1, 'Only one response asserted');
    is($responses->[0]{attributes}{level}, 'high', 'High priority rule won');
};

subtest 'Conflict Resolution - random strategy' => sub {
    my $store6 = AI::Clam::Store->new(db => ':memory:');
    my $engine = AI::Clam::Rules->engine(store => $store6, strategy => 'random');
    
    $engine->assert_fact('trigger', { id => 1 });
    
    for my $i (1..3) {
        $engine->add(AI::Clam::Rules::Rule->new(
            name       => "rule_$i",
            type       => 'production',
            priority   => $i,
            conditions => [{ type => 'trigger', id => 1 }],
            action     => sub { return { type => 'result', attributes => { from => "rule_$i" } }; },
        ));
    }
    
    # Run multiple times and collect results.
    my %winners;
    for my $try (1..20) {
        my $store_try = AI::Clam::Store->new(db => ':memory:');
        my $engine_try = AI::Clam::Rules->engine(store => $store_try, strategy => 'random');
        $engine_try->assert_fact('trigger', { id => 1 });
        for my $i (1..3) {
            $engine_try->add(AI::Clam::Rules::Rule->new(
                name       => "rule_$i",
                type       => 'production',
                priority   => $i,
                conditions => [{ type => 'trigger', id => 1 }],
                action     => sub { return { type => 'result', attributes => { from => "rule_$i" } }; },
            ));
        }
        $engine_try->chain_with_resolution();
        my $results = $engine_try->query_facts('result');
        $winners{$results->[0]{attributes}{from}}++ if @$results;
    }
    
    ok(scalar(keys %winners) > 1, 'Multiple winners over runs');
};

# === Test 4: Rule Composition ===

subtest 'Rule Composition - pipeline' => sub {
    my $store7 = AI::Clam::Store->new(db => ':memory:');
    my $engine = AI::Clam::Rules->engine(store => $store7, strategy => 'first');
    
    $engine->add(AI::Clam::Rules::Rule->new(
        name   => 'step1',
        type   => 'pattern',
        match  => qr/.*/,
        action => sub { return { input => 'hello world', words => ['hello', 'world'] }; },
    ));
    
    $engine->add(AI::Clam::Rules::Rule->new(
        name   => 'step2',
        type   => 'pattern',
        match  => qr/.*/,
        action => sub {
            my $ctx = shift;
            my $words = $ctx->{words} // [];
            return { uppercase => [ map { uc($_) } @$words ] };
        },
    ));
    
    my $pipeline = $engine->chain_rules('step1', 'step2');
    
    is($pipeline->{steps}, 2, 'Two steps executed');
    is_deeply($pipeline->{final}{uppercase}, ['HELLO', 'WORLD'], 'Pipeline result correct');
};

# === Test 5: Incremental Re-evaluation ===

subtest 'Incremental Re-evaluation' => sub {
    my $store8 = AI::Clam::Store->new(db => ':memory:');
    my $engine = AI::Clam::Rules->engine(store => $store8, strategy => 'first');
    
    $engine->add(AI::Clam::Rules::Rule->new(
        name       => 'process_sensor',
        type       => 'production',
        priority   => 10,
        conditions => [{ type => 'sensor', name => 'temp' }],
        action     => sub {
            my $ctx = shift;
            my $sensor = $ctx->{match};
            return {
                type       => 'reading',
                attributes => { value => $sensor->{attributes}{value} * 2 },
            };
        },
    ));
    
    $engine->assert_fact('sensor', { name => 'temp', value => 25 });
    $engine->chain();
    
    my $readings = $engine->query_facts('reading');
    ok(@$readings, 'Initial reading exists');
    
    # Change sensor value and re-evaluate only sensor-dependent rules.
    $engine->retract_fact($engine->query_facts('sensor')->[0]{id});
    $engine->assert_fact('sensor', { name => 'temp', value => 30 });
    
    my $reeval = $engine->re_evaluate(['sensor']);
    
    ok(grep { $_ eq 'process_sensor' } @{$reeval->{affected}}, 'Correct rule affected');
    ok($reeval->{count} > 0, 'Rule re-evaluated');
};

# === Test 6: Enhanced _match_condition with negation ===

subtest '_match_condition_with_negation' => sub {
    my $store9 = AI::Clam::Store->new(db => ':memory:');
    my $engine = AI::Clam::Rules->engine(store => $store9, strategy => 'first');
    
    my $result = $engine->_match_condition_with_negation({
        type => 'ban',
        name => 'Alice',
        not_exists => 1,
    });
    
    ok($result->{_negation}, 'Negation flag set');
    ok($result->{_result}, 'Negation is true when fact missing');
};

done_testing();
