#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::WorldModel;

# === Test 1: Add and query belief dependencies ===

subtest 'Add and query dependencies' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $id1 = $wm->believe(statement => 'Rain causes wet', confidence => 0.9);
    my $id2 = $wm->believe(statement => 'Wet causes slip', confidence => 0.8);
    my $id3 = $wm->believe(statement => 'Slip causes fall', confidence => 0.7);

    $wm->add_belief_dependency(from_id => $id1, to_id => $id2, weight => 0.8);
    $wm->add_belief_dependency(from_id => $id2, to_id => $id3, weight => 0.6);

    my $deps = $wm->belief_dependents($id1);
    is(scalar @$deps, 1, 'one dependent of id1');
    is($deps->[0]{to_id}, $id2, 'dependent is id2');
    is($deps->[0]{weight}, 0.8, 'weight is 0.8');

    my $sources = $wm->belief_sources($id3);
    is(scalar @$sources, 1, 'one source for id3');
    is($sources->[0]{from_id}, $id2, 'source is id2');
};

# === Test 2: Belief graph (BFS) ===

subtest 'Belief graph' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'A', confidence => 1.0);
    my $b = $wm->believe(statement => 'B', confidence => 0.9);
    my $c = $wm->believe(statement => 'C', confidence => 0.8);
    my $d = $wm->believe(statement => 'D', confidence => 0.7);

    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 1.0);
    $wm->add_belief_dependency(from_id => $b, to_id => $c, weight => 0.5);
    $wm->add_belief_dependency(from_id => $c, to_id => $d, weight => 0.3);

    my $graph = $wm->belief_graph($a);
    is(scalar @$graph, 3, 'graph has 3 edges');

    my @tos = sort map { $_->{to} } @$graph;
    is_deeply(\@tos, [$b, $c, $d], 'reaches all descendants');
};

# === Test 3: Belief graph depth limit ===

subtest 'Belief graph depth limit' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'A', confidence => 1.0);
    my $b = $wm->believe(statement => 'B', confidence => 0.9);
    my $c = $wm->believe(statement => 'C', confidence => 0.8);

    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 1.0);
    $wm->add_belief_dependency(from_id => $b, to_id => $c, weight => 1.0);

    my $graph = $wm->belief_graph($a, max_depth => 1);
    is(scalar @$graph, 1, 'depth 1 only sees direct dependent');
    is($graph->[0]{to}, $b, 'reached b but not c');
};

# === Test 4: Confidence propagation — simple chain ===

subtest 'Confidence propagation simple' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'Source belief', confidence => 0.9);
    my $b = $wm->believe(statement => 'Dependent belief', confidence => 0.8);

    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 1.0);

    # Lower confidence of source from 0.9 to 0.5 (delta = -0.4).
    my $changed = $wm->propagate_confidence(
        belief_id      => $a,
        old_confidence => 0.9,
        new_confidence => 0.5,
    );

    is(scalar @$changed, 1, 'one belief changed');
    is($changed->[0]{id}, $b, 'dependent belief changed');
    ok($changed->[0]{new_confidence} < $changed->[0]{old_confidence}, 'confidence decreased');

    # Verify the new value persisted.
    my $row = $wm->{dbh}->selectrow_hashref(
        'SELECT confidence FROM wm_beliefs WHERE id = ?', undef, $b);
    ok($row->{confidence} < 0.8, 'confidence updated in database');
};

# === Test 5: Confidence propagation with weight ===

subtest 'Confidence propagation weighted' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'Source', confidence => 0.9);
    my $b = $wm->believe(statement => 'Weak dep', confidence => 0.8);

    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 0.3);

    # Lower source from 0.9 to 0.5 (delta = -0.4).
    my $changed = $wm->propagate_confidence(
        belief_id      => $a,
        old_confidence => 0.9,
        new_confidence => 0.5,
    );

    is(scalar @$changed, 1, 'dependent changed');
    # Adjustment = -0.4 * 0.3 = -0.12. New = 0.8 - 0.12 = 0.68.
    my $new_conf = $changed->[0]{new_confidence};
    ok(abs($new_conf - 0.68) < 0.01, "confidence adjusted by weight (got $new_conf, expected ~0.68)");
};

# === Test 6: Confidence propagation chain ===

subtest 'Confidence propagation chain' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'Root', confidence => 0.9);
    my $b = $wm->believe(statement => 'Mid', confidence => 0.8);
    my $c = $wm->believe(statement => 'Leaf', confidence => 0.7);

    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 1.0);
    $wm->add_belief_dependency(from_id => $b, to_id => $c, weight => 0.5);

    # Collapse root from 0.9 to 0.1.
    my $changed = $wm->propagate_confidence(
        belief_id      => $a,
        old_confidence => 0.9,
        new_confidence => 0.1,
    );

    ok(scalar @$changed >= 2, 'chain propagated to at least 2 beliefs');

    # b should drop by delta=-0.8 => 0.8 - 0.8 = 0.0
    my ($b_change) = grep { $_->{id} == $b } @$changed;
    ok($b_change, 'b was changed');
    ok(abs($b_change->{new_confidence}) < 0.01, 'b dropped to ~0');
};

# === Test 7: Confidence propagation clamps to [0,1] ===

subtest 'Confidence propagation clamping' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'Source', confidence => 0.1);
    my $b = $wm->believe(statement => 'Dep', confidence => 0.8);

    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 1.0);

    # Increase source from 0.1 to 1.0 (delta = +0.9).
    my $changed = $wm->propagate_confidence(
        belief_id      => $a,
        old_confidence => 0.1,
        new_confidence => 1.0,
    );

    is(scalar @$changed, 1, 'dependent changed');
    ok($changed->[0]{new_confidence} <= 1.0, 'clamped to max 1.0');
};

# === Test 8: revise_belief — supersede and propagate ===

subtest 'revise_belief' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'Old belief', confidence => 0.9, source => 'llm');
    my $b = $wm->believe(statement => 'Dependent', confidence => 0.8);
    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 0.7);

    my $result = $wm->revise_belief($a,
        confidence => 0.3,
        statement  => 'Revised belief',
        reason     => 'new evidence',
    );

    ok($result->{new_id}, 'new belief created');
    ok(scalar @{$result->{propagated}} >= 1, 'propagated to dependents');

    # Old belief superseded.
    my $old = $wm->{dbh}->selectrow_hashref(
        'SELECT superseded_by FROM wm_beliefs WHERE id = ?', undef, $a);
    is($old->{superseded_by}, $result->{new_id}, 'old belief superseded');

    # New belief has correct values.
    my $new = $wm->query_beliefs(statement_like => 'Revised');
    is(scalar @$new, 1, 'new belief found');
    ok(abs($new->[0]{confidence} - 0.3) < 0.01, 'new confidence is 0.3');
};

# === Test 9: revise_belief without confidence change — no propagation ===

subtest 'revise_belief no change' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'A', confidence => 0.5);
    my $b = $wm->believe(statement => 'B', confidence => 0.8);
    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 1.0);

    my $result = $wm->revise_belief($a, confidence => 0.5, statement => 'A revised');
    is(scalar @{$result->{propagated}}, 0, 'no propagation when confidence unchanged');

    my $b_row = $wm->{dbh}->selectrow_hashref(
        'SELECT confidence FROM wm_beliefs WHERE id = ?', undef, $b);
    ok(abs($b_row->{confidence} - 0.8) < 0.01, 'dependent unchanged');
};

# === Test 10: Remove dependency ===

subtest 'Remove dependency' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'A', confidence => 0.9);
    my $b = $wm->believe(statement => 'B', confidence => 0.8);
    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 1.0);

    my $deps = $wm->belief_dependents($a);
    is(scalar @$deps, 1, 'has dependency');

    $wm->remove_belief_dependency(from_id => $a, to_id => $b);
    $deps = $wm->belief_dependents($a);
    is(scalar @$deps, 0, 'dependency removed');
};

# === Test 11: Dead dependents skipped ===

subtest 'Dead dependents skipped' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'A', confidence => 0.9);
    my $b = $wm->believe(statement => 'B', confidence => 0.0);  # dead
    my $c = $wm->believe(statement => 'C', confidence => 0.7);

    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 1.0);
    $wm->add_belief_dependency(from_id => $a, to_id => $c, weight => 1.0);

    my $changed = $wm->propagate_confidence(
        belief_id      => $a,
        old_confidence => 0.9,
        new_confidence => 0.5,
    );

    my @changed_ids = map { $_->{id} } @$changed;
    ok(!grep { $_ eq $b } @changed_ids, 'dead belief b not changed');
    ok(grep { $_ eq $c } @changed_ids, 'live belief c changed');
};

# === Test 12: Multiple dependents ===

subtest 'Multiple dependents' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $a = $wm->believe(statement => 'Cause', confidence => 0.9);
    my $b = $wm->believe(statement => 'Effect1', confidence => 0.8);
    my $c = $wm->believe(statement => 'Effect2', confidence => 0.7);
    my $d = $wm->believe(statement => 'Effect3', confidence => 0.6);

    $wm->add_belief_dependency(from_id => $a, to_id => $b, weight => 1.0);
    $wm->add_belief_dependency(from_id => $a, to_id => $c, weight => 0.5);
    $wm->add_belief_dependency(from_id => $a, to_id => $d, weight => 0.2);

    my $changed = $wm->propagate_confidence(
        belief_id      => $a,
        old_confidence => 0.9,
        new_confidence => 0.1,
    );

    is(scalar @$changed, 3, 'all three dependents changed');
    my %by_id = map { $_->{id} => $_ } @$changed;
    ok(abs($by_id{$b}{new_confidence}) < 0.01, 'b ~0');
    ok(abs($by_id{$c}{new_confidence} - 0.3) < 0.01, 'c ~0.3');
    ok(abs($by_id{$d}{new_confidence} - 0.44) < 0.01, 'd ~0.44');
};

# === Test 13: beliefs_temporal and fact_history still work ===

subtest 'Existing belief queries unaffected' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $wm = Clank::WorldModel->new(store => $store);

    my $id1 = $wm->believe(statement => 'Old', confidence => 0.5);
    $wm->supersede_belief($id1, statement => 'New', confidence => 0.9);

    my $active = $wm->query_beliefs();
    is(scalar @$active, 1, 'one active belief');
    is($active->[0]{statement}, 'New', 'new belief active');

    my $history = $wm->belief_history();
    is(scalar @$history, 2, 'both beliefs in history');

    my $lineage = $wm->belief_lineage($id1);
    is(scalar @$lineage, 2, 'lineage has 2 entries');
};

done_testing;
