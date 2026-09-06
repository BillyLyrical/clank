#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clam::Store;
use Clam::Bus;
use Clam::Session;
use Clam::Loop;
use Clam::Provider::Mock;
use Clam::Director;
use Clam::WorldModel;
use Clam qw(builtin_tools);

sub make_env {
    my $store = Clam::Store->new(db => ':memory:');
    my $bus   = Clam::Bus->new(store => $store, sender => 'test');
    my $mock  = Clam::Provider::Mock->new(model => 'mock');
    my $sess  = Clam::Session->new(store => $store, bus => $bus, provider => $mock);
    $sess->add_tool($_) for builtin_tools();
    my $loop  = Clam::Loop->new(session => $sess);
    my $wm    = Clam::WorldModel->new(store => $store);
    return ($store, $bus, $mock, $sess, $loop, $wm);
}

# === Test 1: Construction ===

subtest 'Construction' => sub {
    my ($store, $bus, $mock, $sess, $loop, $wm) = make_env;
    my $dir = Clam::Director->new(loop => $loop, world_model => $wm);
    isa_ok($dir, 'Clam::Director');
    ok($dir->{planner}, 'goal planner created');
};

# === Test 2: Execute single goal ===

subtest 'Execute single goal' => sub {
    my ($store, $bus, $mock, $sess, $loop, $wm) = make_env;
    my $dir = Clam::Director->new(loop => $loop, world_model => $wm);

    my $result = $dir->execute(goal => 'Say hello');
    ok($result->{ok}, 'goal executed');
    ok($result->{goal_id}, 'goal ID created');
    is(scalar @{$result->{results}}, 1, 'one result');
    ok($result->{turns} > 0, 'turns consumed');
};

# === Test 3: Execute with subgoals ===

subtest 'Execute with subgoals' => sub {
    my ($store, $bus, $mock, $sess, $loop, $wm) = make_env;
    my $dir = Clam::Director->new(loop => $loop, world_model => $wm);

    my $result = $dir->execute(
        goal => 'Multi-step task',
        subgoals => [
            { statement => 'Step one' },
            { statement => 'Step two' },
        ],
    );
    ok($result->{ok}, 'goal executed');
    is(scalar @{$result->{results}}, 2, 'two results');
};

# === Test 4: Goal created in planner ===

subtest 'Goal created in planner' => sub {
    my ($store, $bus, $mock, $sess, $loop, $wm) = make_env;
    my $dir = Clam::Director->new(loop => $loop, world_model => $wm);

    my $result = $dir->execute(goal => 'Test goal');
    ok($result->{goal_id}, 'goal ID returned');

    my $goal = $dir->{planner}->get_goal($result->{goal_id});
    is($goal->{statement}, 'Test goal', 'goal stored correctly');
    is($goal->{status}, 'completed', 'goal marked completed');
};

# === Test 5: Director publishes events ===

subtest 'Director publishes events' => sub {
    my ($store, $bus, $mock, $sess, $loop, $wm) = make_env;
    my $dir = Clam::Director->new(loop => $loop, world_model => $wm);

    my @events;
    $bus->subscribe('director.done', sub { push @events, $_[0]{payload} }, name => 'watcher');

    $dir->execute(goal => 'Event test');

    ok(scalar @events >= 1, 'director.done event published');
    ok($events[0]{goal_id}, 'event has goal_id');
    ok($events[0]{ok}, 'event reports success');
};

# === Test 6: Works without world model ===

subtest 'Works without world model' => sub {
    my ($store, $bus, $mock, $sess, $loop, $wm) = make_env;
    my $dir = Clam::Director->new(loop => $loop);

    my $result = $dir->execute(goal => 'No planner');
    ok($result->{ok}, 'executes without planner');
    ok(!$result->{goal_id}, 'no goal_id without planner');
};

# === Test 7: Metrics tracking ===

subtest 'Metrics tracking' => sub {
    my ($store, $bus, $mock, $sess, $loop, $wm) = make_env;
    require Clam::Metrics;
    my $metrics = Clam::Metrics->new(store => $store);

    my $dir = Clam::Director->new(loop => $loop, world_model => $wm, metrics => $metrics);
    $dir->execute(goal => 'Metrics test');

    ok($metrics->get('director.goals') >= 1, 'goals counted');
    ok($metrics->get('director.turns') >= 1, 'turns counted');
};

done_testing;
