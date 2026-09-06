#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clam::Store;
use Clam::WorldModel;
use Clam::Logic::GoalPlanner;

my $store = Clam::Store->new(db => ':memory:');
my $wm    = Clam::WorldModel->new(store => $store);

# === Test 1: Construction ===

subtest 'Construction' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => $wm);
    isa_ok($gp, 'Clam::Logic::GoalPlanner');
};

# === Test 2: Set and get goal ===

subtest 'Set and get goal' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $id = $gp->set_goal(statement => 'Build a compiler', priority => 3);
    ok($id, 'goal created');

    my $goal = $gp->get_goal($id);
    is($goal->{statement}, 'Build a compiler', 'statement matches');
    is($goal->{priority}, 3, 'priority matches');
    is($goal->{status}, 'active', 'status is active');
};

# === Test 3: Query goals ===

subtest 'Query goals' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    $gp->set_goal(statement => 'Goal A', priority => 1);
    $gp->set_goal(statement => 'Goal B', priority => 5);
    $gp->set_goal(statement => 'Goal C', priority => 3);

    my $all = $gp->query_goals;
    is(scalar @$all, 3, 'all goals returned');

    # Should be ordered by priority ASC.
    is($all->[0]{priority}, 1, 'highest priority first');
    is($all->[2]{priority}, 5, 'lowest priority last');

    my $active = $gp->query_goals(status => 'active');
    is(scalar @$active, 3, 'all active');
};

# === Test 4: Complete and abandon goals ===

subtest 'Complete and abandon goals' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $id1 = $gp->set_goal(statement => 'Do this');
    my $id2 = $gp->set_goal(statement => 'Do that');

    $gp->complete_goal($id1);
    $gp->abandon_goal($id2);

    my $g1 = $gp->get_goal($id1);
    my $g2 = $gp->get_goal($id2);
    is($g1->{status}, 'completed', 'goal completed');
    is($g2->{status}, 'abandoned', 'goal abandoned');
};

# === Test 5: Add subgoals ===

subtest 'Add subgoals' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $gid = $gp->set_goal(statement => 'Build compiler');
    my $s1 = $gp->add_subgoal(goal_id => $gid, statement => 'Write lexer');
    my $s2 = $gp->add_subgoal(goal_id => $gid, statement => 'Write parser', depends_on => [$s1]);
    my $s3 = $gp->add_subgoal(goal_id => $gid, statement => 'Write codegen', depends_on => [$s1, $s2]);

    my $subs = $gp->subgoals_for_goal($gid);
    is(scalar @$subs, 3, 'three subgoals');

    my $sg2 = $gp->get_subgoal($s2);
    is_deeply($sg2->{depends_on}, [$s1], 'parser depends on lexer');
};

# === Test 6: Plan generation (topological sort) ===

subtest 'Plan generation' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $gid = $gp->set_goal(statement => 'Build compiler');
    my $s1 = $gp->add_subgoal(goal_id => $gid, statement => 'Write lexer');
    my $s2 = $gp->add_subgoal(goal_id => $gid, statement => 'Write parser', depends_on => [$s1]);
    my $s3 = $gp->add_subgoal(goal_id => $gid, statement => 'Write codegen', depends_on => [$s1, $s2]);

    my $plan = $gp->plan($gid);
    is(scalar @$plan, 3, 'plan has 3 steps');

    # Lexer must come before parser, parser before codegen.
    my %order = map { $plan->[$_]{statement} => $_ } 0..$#$plan;
    ok($order{'Write lexer'} < $order{'Write parser'}, 'lexer before parser');
    ok($order{'Write parser'} < $order{'Write codegen'}, 'parser before codegen');

    # First step should be ready (no dependencies).
    is($plan->[0]{effective_status}, 'ready', 'first step is ready');
};

# === Test 7: Plan with subgoals in reverse order ===

subtest 'Plan reverse order' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $gid = $gp->set_goal(statement => 'Test');
    my $s1 = $gp->add_subgoal(goal_id => $gid, statement => 'Step C', depends_on => ['s2']);
    my $s2 = $gp->add_subgoal(goal_id => $gid, statement => 'Step B', depends_on => ['s3']);
    my $s3 = $gp->add_subgoal(goal_id => $gid, statement => 'Step A');

    my $plan = $gp->plan($gid);
    my @names = map { $_->{statement} } @$plan;

    # Step A has no deps, Step B depends on Step A's ID, etc.
    ok((grep { $_ eq 'Step A' } @names), 'Step A in plan');
    ok((grep { $_ eq 'Step B' } @names), 'Step B in plan');
    ok((grep { $_ eq 'Step C' } @names), 'Step C in plan');
};

# === Test 8: Complete subgoal makes dependents ready ===

subtest 'Subgoal completion unlocks dependents' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $gid = $gp->set_goal(statement => 'Test');
    my $s1 = $gp->add_subgoal(goal_id => $gid, statement => 'First');
    my $s2 = $gp->add_subgoal(goal_id => $gid, statement => 'Second', depends_on => [$s1]);

    # Initially second is blocked.
    my $plan = $gp->plan($gid);
    my ($second) = grep { $_->{statement} eq 'Second' } @$plan;
    is($second->{effective_status}, 'blocked', 'second blocked before first completes');

    # Complete first.
    $gp->complete_subgoal($s1);

    # Now second should be ready.
    $plan = $gp->plan($gid);
    ($second) = grep { $_->{statement} eq 'Second' } @$plan;
    is($second->{effective_status}, 'ready', 'second ready after first completes');
};

# === Test 9: Goal auto-completes when all subgoals done ===

subtest 'Goal auto-completion' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $gid = $gp->set_goal(statement => 'Test');
    my $s1 = $gp->add_subgoal(goal_id => $gid, statement => 'A');
    my $s2 = $gp->add_subgoal(goal_id => $gid, statement => 'B');

    $gp->complete_subgoal($s1);
    my $g = $gp->get_goal($gid);
    is($g->{status}, 'active', 'still active after one subgoal');

    $gp->complete_subgoal($s2);
    $g = $gp->get_goal($gid);
    is($g->{status}, 'completed', 'goal auto-completed');
};

# === Test 10: Relevance scoring ===

subtest 'Relevance scoring' => sub {
    my $wm2 = Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:'));

    # Create beliefs with a dependency chain.
    my $b1 = $wm2->believe(statement => 'Foundational knowledge', confidence => 1.0);
    my $b2 = $wm2->believe(statement => 'Derived knowledge', confidence => 0.8);
    my $b3 = $wm2->believe(statement => 'Advanced knowledge', confidence => 0.6);
    my $b4 = $wm2->believe(statement => 'Unrelated knowledge', confidence => 0.9);

    $wm2->add_belief_dependency(from_id => $b1, to_id => $b2, weight => 0.9);
    $wm2->add_belief_dependency(from_id => $b2, to_id => $b3, weight => 0.7);

    my $gp = Clam::Logic::GoalPlanner->new(world_model => $wm2);
    my $gid = $gp->set_goal(statement => 'Master the domain');

    # Link foundational belief to goal.
    $gp->link_belief(goal_id => $gid, belief_id => $b1);

    # Score all beliefs.
    my $scores = $gp->score_beliefs_for_goal($gid);
    ok(scalar @$scores >= 1, 'at least one belief scored');

    # Foundational belief should score highest (closest to goal).
    my %by_bid = map { $_->{belief_id} => $_ } @$scores;
    ok($by_bid{$b1}{relevance} > 0, 'foundational belief has relevance');
};

# === Test 11: Relevance scoring with confidence ===

subtest 'Relevance considers confidence' => sub {
    my $wm2 = Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:'));

    my $high = $wm2->believe(statement => 'High confidence', confidence => 0.95);
    my $low  = $wm2->believe(statement => 'Low confidence', confidence => 0.2);

    $wm2->add_belief_dependency(from_id => $high, to_id => $low, weight => 0.5);

    my $gp = Clam::Logic::GoalPlanner->new(world_model => $wm2);
    my $gid = $gp->set_goal(statement => 'Test');
    $gp->link_belief(goal_id => $gid, belief_id => $high);

    my $scores = $gp->score_beliefs_for_goal($gid);
    my %by_bid = map { $_->{belief_id} => $_ } @$scores;

    ok($by_bid{$high}{relevance} > $by_bid{$low}{relevance},
       'high confidence belief scores higher');
};

# === Test 12: next_subgoal returns ready subgoal ===

subtest 'next_subgoal' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $gid = $gp->set_goal(statement => 'Test');
    my $s1 = $gp->add_subgoal(goal_id => $gid, statement => 'First');
    my $s2 = $gp->add_subgoal(goal_id => $gid, statement => 'Second', depends_on => [$s1]);

    my $next = $gp->next_subgoal($gid);
    ok($next, 'next subgoal exists');
    is($next->{statement}, 'First', 'first subgoal is next');

    $gp->complete_subgoal($s1);
    $next = $gp->next_subgoal($gid);
    is($next->{statement}, 'Second', 'second subgoal is next after first completes');
};

# === Test 13: Linked beliefs ===

subtest 'Linked beliefs' => sub {
    my $wm2 = Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:'));
    my $bid = $wm2->believe(statement => 'Important fact', confidence => 0.9);

    my $gp = Clam::Logic::GoalPlanner->new(world_model => $wm2);
    my $gid = $gp->set_goal(statement => 'Test');
    $gp->link_belief(goal_id => $gid, belief_id => $bid);

    my $linked = $gp->linked_beliefs($gid);
    is(scalar @$linked, 1, 'one linked belief');
    is($linked->[0]{belief_id}, $bid, 'correct belief linked');
    ok($linked->[0]{relevance} > 0, 'has relevance score');
};

# === Test 14: Rescore subgoals ===

subtest 'Rescore subgoals' => sub {
    my $wm2 = Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:'));
    my $bid = $wm2->believe(statement => 'Fact', confidence => 0.5);

    my $gp = Clam::Logic::GoalPlanner->new(world_model => $wm2);
    my $gid = $gp->set_goal(statement => 'Test');
    my $sid = $gp->add_subgoal(goal_id => $gid, statement => 'Do something', belief_id => $bid);

    # Initial score.
    my $sg = $gp->get_subgoal($sid);
    my $old_score = $sg->{relevance_score};

    # Update belief confidence.
    $wm2->dbh->do('UPDATE wm_beliefs SET confidence = ? WHERE id = ?', undef, 0.95, $bid);

    # Rescore.
    $gp->rescore_subgoals($gid);
    $sg = $gp->get_subgoal($sid);
    ok($sg->{relevance_score} > $old_score, 'relevance increased after confidence update');
};

# === Test 15: Hierarchical goals ===

subtest 'Hierarchical goals' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $parent = $gp->set_goal(statement => 'Master programming');
    my $child1 = $gp->set_goal(statement => 'Learn Perl', parent_id => $parent);
    my $child2 = $gp->set_goal(statement => 'Learn Python', parent_id => $parent);

    my $children = $gp->query_goals(parent_id => $parent);
    is(scalar @$children, 2, 'two child goals');
};

# === Test 16: Empty goal plan ===

subtest 'Empty plan' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $gid = $gp->set_goal(statement => 'Empty goal');
    my $plan = $gp->plan($gid);
    is(scalar @$plan, 0, 'empty plan for goal with no subgoals');
};

# === Test 17: Disconnected subgoals in plan ===

subtest 'Disconnected subgoals' => sub {
    my $gp = Clam::Logic::GoalPlanner->new(world_model => Clam::WorldModel->new(store => Clam::Store->new(db => ':memory:')));

    my $gid = $gp->set_goal(statement => 'Test');
    my $s1 = $gp->add_subgoal(goal_id => $gid, statement => 'Independent A');
    my $s2 = $gp->add_subgoal(goal_id => $gid, statement => 'Independent B');

    my $plan = $gp->plan($gid);
    is(scalar @$plan, 2, 'both independent subgoals in plan');
    my @statuses = map { $_->{effective_status} } @$plan;
    ok(grep { $_ eq 'ready' } @statuses, 'at least one ready');
};

done_testing;
