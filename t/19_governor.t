#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use AI::Clam::Store;
use AI::Clam::Governor;

my $store = AI::Clam::Store->new(db => ':memory:');

# === Test 1: Basic construction ===

subtest 'Construction with defaults' => sub {
    my $gov = AI::Clam::Governor->new(store => $store);
    isa_ok($gov, 'AI::Clam::Governor');
    is($gov->usage->{requests}, 0, 'starts with zero requests');
    is($gov->usage->{circuit_state}, 'closed', 'circuit starts closed');
};

# === Test 2: Rate limiting ===

subtest 'Rate limit - per minute' => sub {
    my $store2 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store2, max_per_minute => 3);

    my ($ok, $reason) = $gov->check(model => 'gpt-4o');
    ok($ok, 'first request allowed');

    $gov->record(model => 'gpt-4o', input_tokens => 100, output_tokens => 50);
    ($ok, $reason) = $gov->check(model => 'gpt-4o');
    ok($ok, 'second request allowed');

    $gov->record(model => 'gpt-4o', input_tokens => 100, output_tokens => 50);
    ($ok, $reason) = $gov->check(model => 'gpt-4o');
    ok($ok, 'third request allowed');

    $gov->record(model => 'gpt-4o', input_tokens => 100, output_tokens => 50);
    ($ok, $reason) = $gov->check(model => 'gpt-4o');
    ok(!$ok, 'fourth request blocked');
    like($reason, qr/rate limit/, 'reason mentions rate limit');
};

subtest 'Rate limit - per hour' => sub {
    my $store3 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store3, max_per_hour => 2);

    $gov->check(model => 'gpt-4o');
    $gov->record(model => 'gpt-4o', input_tokens => 100, output_tokens => 50);
    $gov->check(model => 'gpt-4o');
    $gov->record(model => 'gpt-4o', input_tokens => 100, output_tokens => 50);

    my ($ok, $reason) = $gov->check(model => 'gpt-4o');
    ok(!$ok, 'third request blocked by hourly limit');
    like($reason, qr/hour/, 'reason mentions hourly window');
};

subtest 'Rate limit - tokens per hour' => sub {
    my $store4 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store4, max_tokens_hour => 500);

    $gov->check(model => 'gpt-4o', estimated_tokens => 100);
    $gov->record(model => 'gpt-4o', input_tokens => 200, output_tokens => 100);

    my ($ok, $reason) = $gov->check(model => 'gpt-4o', estimated_tokens => 300);
    ok(!$ok, 'blocked by token limit');
    like($reason, qr/token limit/, 'reason mentions token limit');
};

# === Test 3: Budget cap ===

subtest 'Budget cap' => sub {
    my $store5 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(
        store    => $store5,
        budget   => 0.001,  # $0.001 budget
        session_id => 'test-session-1',
        pricing  => { 'gpt-4o' => { input => 1.0e-3, output => 1.0e-3 } },
    );

    my ($ok) = $gov->check(model => 'gpt-4o');
    ok($ok, 'first request within budget');

    # Spend $0.001 (1000 input tokens * 1e-6 + 0 output)
    $gov->record(model => 'gpt-4o', input_tokens => 1000, output_tokens => 0);

    ($ok, my $reason) = $gov->check(model => 'gpt-4o');
    ok(!$ok, 'second request blocked by budget');
    like($reason, qr/budget/, 'reason mentions budget');
};

# === Test 4: Circuit breaker ===

subtest 'Circuit breaker trips after threshold' => sub {
    my $store6 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store6, cb_threshold => 3, cb_cooldown_ms => 100);

    is($gov->usage->{circuit_state}, 'closed', 'starts closed');

    $gov->record_failure(model => 'gpt-4o', fatal => 1);
    is($gov->usage->{circuit_state}, 'closed', 'still closed after 1 failure');

    $gov->record_failure(model => 'gpt-4o', fatal => 1);
    is($gov->usage->{circuit_state}, 'closed', 'still closed after 2 failures');

    $gov->record_failure(model => 'gpt-4o', fatal => 1);
    is($gov->usage->{circuit_state}, 'open', 'opens after 3 failures');

    my ($ok, $reason) = $gov->check(model => 'gpt-4o');
    ok(!$ok, 'requests blocked when circuit open');
    like($reason, qr/circuit open/, 'reason mentions circuit');
};

subtest 'Circuit breaker half-open after cooldown' => sub {
    my $store7 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store7, cb_threshold => 2, cb_cooldown_ms => 1);

    $gov->record_failure(model => 'gpt-4o', fatal => 1);
    $gov->record_failure(model => 'gpt-4o', fatal => 1);
    is($gov->usage->{circuit_state}, 'open', 'circuit is open');

    select(undef, undef, undef, 0.01);   # sleep 10ms > cooldown
    my ($ok) = $gov->check(model => 'gpt-4o');
    ok($ok, 'request allowed in half-open state');
    is($gov->usage->{circuit_state}, 'half_open', 'state is half_open');
};

subtest 'Circuit breaker closes on success from half-open' => sub {
    my $store8 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store8, cb_threshold => 1, cb_cooldown_ms => 1);

    $gov->record_failure(model => 'gpt-4o', fatal => 1);
    is($gov->usage->{circuit_state}, 'open', 'circuit is open');

    select(undef, undef, undef, 0.01);
    $gov->check(model => 'gpt-4o');   # moves to half_open
    $gov->record(model => 'gpt-4o', input_tokens => 10, output_tokens => 5);

    is($gov->usage->{circuit_state}, 'closed', 'circuit closed after success');
    is($gov->usage->{cb_failures}, 0, 'failure count reset');
};

subtest 'Non-fatal failures do not trip circuit' => sub {
    my $store9 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store9, cb_threshold => 2);

    $gov->record_failure(model => 'gpt-4o', fatal => 0);
    $gov->record_failure(model => 'gpt-4o', fatal => 0);
    is($gov->usage->{circuit_state}, 'closed', 'non-fatal failures ignored');
};

# === Test 5: Cost calculation ===

subtest 'Cost calculation with known model' => sub {
    my $store10 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store10, session_id => 'cost-test');

    # gpt-4o: input $2.50/M, output $10.00/M
    # 1000 input + 200 output = $0.0025 + $0.002 = $0.0045
    my $cost = $gov->record(model => 'gpt-4o', input_tokens => 1000, output_tokens => 200);
    is($cost, 0.0045, 'correct cost calculation');
    is($gov->usage->{cost}, 0.0045, 'total cost updated');
};

subtest 'Cost zero for unknown model' => sub {
    my $store11 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store11);

    my $cost = $gov->record(model => 'local-model', input_tokens => 1000, output_tokens => 500);
    is($cost, 0, 'unknown model has zero cost');
};

# === Test 6: Custom pricing ===

subtest 'Custom pricing overrides defaults' => sub {
    my $store12 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(
        store   => $store12,
        pricing => { 'my-local' => { input => 0, output => 0 } },
    );

    my $cost = $gov->record(model => 'my-local', input_tokens => 10000, output_tokens => 5000);
    is($cost, 0, 'custom zero-cost model');
};

# === Test 7: Usage summary ===

subtest 'Usage tracking' => sub {
    my $store13 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store13, budget => 10.00, session_id => 'usage-test');

    $gov->record(model => 'gpt-4o', input_tokens => 500, output_tokens => 100);
    $gov->record(model => 'gpt-4o', input_tokens => 300, output_tokens => 200);

    my $u = $gov->usage;
    is($u->{requests}, 2, 'request count');
    is($u->{tokens}, 1100, 'total tokens');
    ok($u->{cost} > 0, 'cost accumulated');
    is($u->{budget}, 10.00, 'budget exposed');
};

# === Test 8: Circuit reset ===

subtest 'Manual circuit reset' => sub {
    my $store14 = AI::Clam::Store->new(db => ':memory:');
    my $gov = AI::Clam::Governor->new(store => $store14, cb_threshold => 1);

    $gov->record_failure(model => 'gpt-4o', fatal => 1);
    is($gov->usage->{circuit_state}, 'open', 'circuit open');

    $gov->circuit_reset;
    is($gov->usage->{circuit_state}, 'closed', 'circuit manually reset');
    is($gov->usage->{cb_failures}, 0, 'failures reset');
};

# === Test 9: Persistence across instances ===

subtest 'Session cost persists in SQLite' => sub {
    my $store15 = AI::Clam::Store->new(db => ':memory:');

    my $gov1 = AI::Clam::Governor->new(store => $store15, session_id => 'persist-test');
    $gov1->record(model => 'gpt-4o', input_tokens => 1000, output_tokens => 500);

    my $gov2 = AI::Clam::Governor->new(store => $store15, session_id => 'persist-test');
    ok($gov2->usage->{session_cost} > 0, 'session cost persists across instances');
};

# === Test 10: Bus integration ===

subtest 'Events published to bus' => sub {
    my $store16 = AI::Clam::Store->new(db => ':memory:');
    require AI::Clam::Bus;
    my $bus = AI::Clam::Bus->new(store => $store16);

    my @events;
    $bus->subscribe('governor.*', sub {
        my ($ev) = @_;
        push @events, $ev->{topic};
    }, name => 'test');

    my $gov = AI::Clam::Governor->new(
        store => $store16, bus => $bus,
        max_per_minute => 1, cb_threshold => 1, cb_cooldown_ms => 1,
        budget => 0.0001, session_id => 'bus-test',
        pricing => { 'gpt-4o' => { input => 1.0, output => 1.0 } },
    );

    $gov->record(model => 'gpt-4o', input_tokens => 100, output_tokens => 0);
    $gov->record_failure(model => 'gpt-4o', fatal => 1);
    $gov->record_failure(model => 'gpt-4o', fatal => 1);

    ok(grep { $_ eq 'governor.record' } @events, 'record event published');
    ok(grep { $_ eq 'governor.circuit_open' } @events, 'circuit_open event published');
};

done_testing();
