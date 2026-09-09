#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::WorldModel;

my $store = Clank::Store->new(db => ':memory:');
my $wm    = Clank::WorldModel->new(store => $store);

# === Test 1: Basic counterfactual — query runs, state unchanged after ===

subtest 'Counterfactual query runs and rolls back' => sub {
    $wm->add_entity(id => 'perl', type => 'language', name => 'Perl');
    my $orig_id = $wm->assert_fact(entity_id => 'perl', predicate => 'type', value => 'scripting language', source => 'user');

    my $result = $wm->counterfactual(
        scenario => [
            { op => 'retract_fact', fact_id => $orig_id },
            { op => 'assert_fact', entity_id => 'perl', predicate => 'type', value => 'compiled language' },
        ],
        query => sub {
            my ($wm) = @_;
            return $wm->query_facts(entity_id => 'perl', predicate => 'type');
        },
    );

    is(scalar @$result, 1, 'query returned one result');
    is($result->[0]{value}, 'compiled language', 'counterfactual value seen inside savepoint');

    # After rollback, original value restored.
    my $orig = $wm->query_facts(entity_id => 'perl', predicate => 'type');
    is($orig->[0]{value}, 'scripting language', 'original value restored after rollback');
};

# === Test 2: Retract fact in counterfactual ===

subtest 'Retract fact in counterfactual' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'e1', type => 'thing', name => 'E1');
    my $fid = $wm2->assert_fact(entity_id => 'e1', predicate => 'color', value => 'red');

    my $result = $wm2->counterfactual(
        scenario => [
            { op => 'retract_fact', fact_id => $fid },
        ],
        query => sub {
            my ($wm) = @_;
            return $wm->query_facts(entity_id => 'e1');
        },
    );

    is(scalar @$result, 0, 'fact retracted in counterfactual');

    # Original still there.
    my $orig = $wm2->query_facts(entity_id => 'e1');
    is(scalar @$orig, 1, 'original fact restored');
};

# === Test 3: Add entity in counterfactual ===

subtest 'Add entity in counterfactual' => sub {
    my $result = $wm->counterfactual(
        scenario => [
            { op => 'add_entity', id => 'rust', type => 'language', name => 'Rust' },
        ],
        query => sub {
            my ($wm) = @_;
            return $wm->query_entities(type => 'language');
        },
    );

    my @names = map { $_->{name} } @$result;
    ok(scalar @names >= 2, 'both entities present');
    ok((grep { $_ eq 'Rust' } @names), 'Rust added in counterfactual');

    # Original unchanged.
    my $orig = $wm->query_entities(type => 'language');
    my @orig_names = map { $_->{name} } @$orig;
    ok(!grep { $_ eq 'Rust' } @orig_names, 'Rust not in original');
};

# === Test 4: Remove entity in counterfactual ===

subtest 'Remove entity in counterfactual' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'a', type => 'thing', name => 'A');
    $wm2->add_entity(id => 'b', type => 'thing', name => 'B');

    my $result = $wm2->counterfactual(
        scenario => [
            { op => 'remove_entity', entity_id => 'a' },
        ],
        query => sub {
            my ($wm) = @_;
            return $wm->query_entities(type => 'thing');
        },
    );

    is(scalar @$result, 1, 'only B remains');
    is($result->[0]{id}, 'b', 'B is the remaining entity');

    my $orig = $wm2->query_entities(type => 'thing');
    is(scalar @$orig, 2, 'both entities restored');
};

# === Test 5: Add relation in counterfactual ===

subtest 'Add relation in counterfactual' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'x', type => 'thing', name => 'X');
    $wm2->add_entity(id => 'y', type => 'thing', name => 'Y');

    my $result = $wm2->counterfactual(
        scenario => [
            { op => 'add_relation', source_id => 'x', target_id => 'y', type => 'depends_on' },
        ],
        query => sub {
            my ($wm) = @_;
            return $wm->get_relations(source_id => 'x');
        },
    );

    is(scalar @$result, 1, 'relation exists in counterfactual');
    is($result->[0]{type}, 'depends_on', 'correct relation type');

    my $orig = $wm2->get_relations(source_id => 'x');
    is(scalar @$orig, 0, 'no relations in original');
};

# === Test 6: Add cause in counterfactual ===

subtest 'Add cause in counterfactual' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'rain', type => 'weather', name => 'Rain');
    $wm2->add_entity(id => 'wet', type => 'state', name => 'Wet');

    my $effects = $wm2->counterfactual(
        scenario => [
            { op => 'add_cause', cause_entity => 'rain', effect_entity => 'wet', mechanism => 'water' },
        ],
        query => sub {
            my ($wm) = @_;
            return $wm->predict_effects('rain');
        },
    );

    is(scalar @$effects, 1, 'cause exists in counterfactual');
    is($effects->[0]{effect_entity}, 'wet', 'correct effect');

    my $orig = $wm2->predict_effects('rain');
    is(scalar @$orig, 0, 'no causes in original');
};

# === Test 7: Believe in counterfactual ===

subtest 'Believe in counterfactual' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);

    my $result = $wm2->counterfactual(
        scenario => [
            { op => 'believe', statement => 'Perl is elegant', confidence => 0.9 },
        ],
        query => sub {
            my ($wm) = @_;
            return $wm->query_beliefs();
        },
    );

    is(scalar @$result, 1, 'belief exists in counterfactual');
    like($result->[0]{statement}, qr/elegant/, 'correct statement');

    my $orig = $wm2->query_beliefs();
    is(scalar @$orig, 0, 'no beliefs in original');
};

# === Test 8: Supersede belief in counterfactual ===

subtest 'Supersede belief in counterfactual' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    my $bid = $wm2->believe(statement => 'Old belief', confidence => 0.5);

    my $result = $wm2->counterfactual(
        scenario => [
            { op => 'supersede_belief', belief_id => $bid, statement => 'New belief', confidence => 0.9 },
        ],
        query => sub {
            my ($wm) = @_;
            return $wm->query_beliefs();
        },
    );

    is(scalar @$result, 1, 'one active belief');
    like($result->[0]{statement}, qr/New/, 'new belief active');

    my $orig = $wm2->query_beliefs();
    is($orig->[0]{statement}, 'Old belief', 'original belief restored');
};

# === Test 9: Multiple operations in one scenario ===

subtest 'Multiple operations in scenario' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'a', type => 'thing', name => 'A');

    my $result = $wm2->counterfactual(
        scenario => [
            { op => 'add_entity', id => 'b', type => 'thing', name => 'B' },
            { op => 'add_entity', id => 'c', type => 'thing', name => 'C' },
            { op => 'remove_entity', entity_id => 'a' },
        ],
        query => sub {
            my ($wm) = @_;
            return $wm->query_entities(type => 'thing');
        },
    );

    my @ids = sort map { $_->{id} } @$result;
    is_deeply(\@ids, ['b', 'c'], 'A removed, B and C added');

    my $orig = $wm2->query_entities(type => 'thing');
    is(scalar @$orig, 1, 'only A in original');
};

# === Test 10: counterfactual_diff ===

subtest 'counterfactual_diff' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'e1', type => 'thing', name => 'E1');
    $wm2->assert_fact(entity_id => 'e1', predicate => 'x', value => '1');
    $wm2->assert_fact(entity_id => 'e1', predicate => 'y', value => '2');

    my $diff = $wm2->counterfactual_diff(
        entity_id => 'e1',
        scenario => [
            { op => 'assert_fact', entity_id => 'e1', predicate => 'z', value => '3' },
        ],
    );

    ok(ref $diff eq 'HASH', 'returns hashref');
    ok(ref $diff->{original} eq 'ARRAY', 'has original');
    ok(ref $diff->{counterfactual} eq 'ARRAY', 'has counterfactual');
    ok(ref $diff->{diff} eq 'ARRAY', 'has diff');

    is(scalar @{$diff->{original}}, 2, 'original has 2 facts');
    is(scalar @{$diff->{counterfactual}}, 3, 'counterfactual has 3 facts');

    my @added = grep { $_->{type} eq 'fact_added' } @{$diff->{diff}};
    is(scalar @added, 1, 'one fact added in diff');
};

# === Test 11: counterfactual_diff with retraction ===

subtest 'counterfactual_diff retraction' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'e1', type => 'thing', name => 'E1');
    my $fid = $wm2->assert_fact(entity_id => 'e1', predicate => 'x', value => '1');
    $wm2->assert_fact(entity_id => 'e1', predicate => 'y', value => '2');

    my $diff = $wm2->counterfactual_diff(
        entity_id => 'e1',
        scenario => [
            { op => 'retract_fact', fact_id => $fid },
        ],
    );

    my @removed = grep { $_->{type} eq 'fact_removed' } @{$diff->{diff}};
    is(scalar @removed, 1, 'one fact removed in diff');
};

# === Test 12: counterfactual_causes ===

subtest 'counterfactual_causes' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'fire', type => 'event', name => 'Fire');
    $wm2->add_entity(id => 'smoke', type => 'event', name => 'Smoke');
    $wm2->add_entity(id => 'heat', type => 'event', name => 'Heat');

    my $effects = $wm2->counterfactual_causes(
        cause_id => 'fire',
        scenario => [
            { op => 'add_cause', cause_entity => 'fire', effect_entity => 'smoke' },
            { op => 'add_cause', cause_entity => 'fire', effect_entity => 'heat' },
        ],
    );

    is(scalar @$effects, 2, 'two effects predicted');
    my @effect_ids = sort map { $_->{effect_entity} } @$effects;
    is_deeply(\@effect_ids, ['heat', 'smoke'], 'correct effects');

    my $orig = $wm2->predict_effects('fire');
    is(scalar @$orig, 0, 'no effects in original');
};

# === Test 13: counterfactual_causes trace ===

subtest 'counterfactual_causes trace' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'x', type => 'thing', name => 'X');
    $wm2->add_entity(id => 'y', type => 'thing', name => 'Y');

    my $causes = $wm2->counterfactual_causes(
        effect_id => 'y',
        scenario => [
            { op => 'add_cause', cause_entity => 'x', effect_entity => 'y' },
        ],
    );

    is(scalar @$causes, 1, 'one cause traced');
    is($causes->[0]{cause_entity}, 'x', 'correct cause');
};

# === Test 14: Scenario failure rolls back cleanly ===

subtest 'Failed scenario rolls back cleanly' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'e1', type => 'thing', name => 'E1');

    eval {
        $wm2->counterfactual(
            scenario => [
                { op => 'assert_fact', entity_id => 'e1', predicate => 'x', value => '1' },
                { op => 'retract_fact', fact_id => 99999 },   # nonexistent
            ],
            query => sub { [] },
        );
    };
    like($@, qr/scenario failed/, 'scenario failure caught');

    my $orig = $wm2->query_facts(entity_id => 'e1');
    is(scalar @$orig, 0, 'no facts leaked from failed scenario');
};

# === Test 15: Query failure rolls back cleanly ===

subtest 'Failed query rolls back cleanly' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'e1', type => 'thing', name => 'E1');

    eval {
        $wm2->counterfactual(
            scenario => [
                { op => 'assert_fact', entity_id => 'e1', predicate => 'x', value => '1' },
            ],
            query => sub { die "query error" },
        );
    };
    like($@, qr/query failed/, 'query failure caught');

    my $orig = $wm2->query_facts(entity_id => 'e1');
    is(scalar @$orig, 0, 'no facts leaked from failed query');
};

# === Test 16: Empty scenario is no-op ===

subtest 'Empty scenario is no-op' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'e1', type => 'thing', name => 'E1');
    $wm2->assert_fact(entity_id => 'e1', predicate => 'x', value => '1');

    my $result = $wm2->counterfactual(
        scenario => [],
        query => sub {
            my ($wm) = @_;
            return $wm->query_facts(entity_id => 'e1');
        },
    );

    is(scalar @$result, 1, 'same facts with empty scenario');
    is($result->[0]{value}, '1', 'value matches');
};

# === Test 17: Nested counterfactuals (savepoint in savepoint) ===

subtest 'Nested counterfactuals' => sub {
    my $store2 = Clank::Store->new(db => ':memory:');
    my $wm2 = Clank::WorldModel->new(store => $store2);
    $wm2->add_entity(id => 'e1', type => 'thing', name => 'E1');

    # Use different predicates to avoid duplicate fact collision.
    my $inner_result;
    my $outer_result = $wm2->counterfactual(
        scenario => [
            { op => 'assert_fact', entity_id => 'e1', predicate => 'outer_pred', value => 'outer_val' },
        ],
        query => sub {
            my ($wm) = @_;
            $inner_result = $wm->counterfactual(
                scenario => [
                    { op => 'assert_fact', entity_id => 'e1', predicate => 'inner_pred', value => 'inner_val' },
                ],
                query => sub {
                    my ($wm2) = @_;
                    return $wm2->query_facts(entity_id => 'e1');
                },
            );
            return $wm->query_facts(entity_id => 'e1');
        },
    );

    # Inner sees both outer and inner facts.
    my @inner_preds = map { $_->{predicate} } @$inner_result;
    ok(scalar @inner_preds >= 2, 'inner sees at least 2 facts');

    # After full rollback, nothing remains.
    my $orig = $wm2->query_facts(entity_id => 'e1');
    is(scalar @$orig, 0, 'original has no facts after nested rollback');
};

done_testing;
