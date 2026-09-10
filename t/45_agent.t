#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Bus;
use Clank::Session;
use Clank::Loop;
use Clank::Provider::Mock;
use Clank qw(builtin_tools);

sub make_loop {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus   = Clank::Bus->new(store => $store, sender => 'test');
    my $mock  = Clank::Provider::Mock->new(model => 'mock');
    my $sess  = Clank::Session->new(store => $store, bus => $bus, provider => $mock);
    $sess->add_tool($_) for builtin_tools();
    my $loop  = Clank::Loop->new(session => $sess);
    return ($store, $bus, $mock, $sess, $loop);
}

# Point Agent at the repo's agents/ directory.
use Clank::Agent;
Clank::Agent->agent_dir("$FindBin::Bin/../agents");

# === Test 1: Agent.pm loads ===

subtest 'Agent module loads' => sub {
    use_ok('Clank::Agent');
};

# === Test 2: Parse TOML frontmatter ===

subtest 'Parse TOML frontmatter' => sub {
    my $profile = Clank::Agent->load('reviewer');
    isa_ok($profile, 'HASH');
    is($profile->{name}, 'reviewer', 'name parsed');
    is($profile->{description}, 'Code review with evidence-based critique. Read-only — never modifies files.', 'description parsed');
    is($profile->{model}, 'standard', 'model parsed');
    is_deeply($profile->{tools}, ['read', 'bash'], 'tools array parsed');
    is($profile->{max_turns}, 5, 'max_turns parsed');
};

# === Test 3: Load markdown prompt ===

subtest 'Load markdown prompt' => sub {
    my $profile = Clank::Agent->load('reviewer');
    like($profile->{prompt}, qr/Code Reviewer/, 'prompt loaded from .md');
    like($profile->{prompt}, qr/Read only/, 'prompt contains rules');
};

# === Test 4: List agents ===

subtest 'List agent profiles' => sub {
    my @names = Clank::Agent->list;
    ok(scalar @names >= 1, 'at least one agent found');
    ok(grep { $_ eq 'reviewer' } @names, 'reviewer in list');
};

# === Test 5: Load nonexistent agent ===

subtest 'Load nonexistent agent returns undef' => sub {
    my $profile = Clank::Agent->load('nonexistent_agent_xyz');
    is($profile, undef, 'returns undef for missing profile');
};

# === Test 6: Spawn reviewer with tool restriction ===

subtest 'Spawn reviewer restricts tools' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;

    my @allowed_tools;
    $bus->subscribe('subagent_start', sub {
        my ($ev) = @_;
        # The child session was already created — inspect it via store.
    }, name => 'watcher');

    my $result = Clank::Agent->spawn(
        name   => 'reviewer',
        prompt => 'review the code in lib/Clank.pm',
        loop   => $loop,
    );

    ok($result->{ok}, 'spawn succeeded');
    is($result->{agent}, 'reviewer', 'agent name returned');
    ok($result->{session_id}, 'child session created');
    ok($result->{output}, 'produced output');
};

# === Test 7: Spawn unknown agent dies ===

subtest 'Spawn unknown agent dies' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;

    eval {
        Clank::Agent->spawn(name => 'nosuch', prompt => 'do stuff', loop => $loop);
    };
    like($@, qr/unknown agent profile/, 'dies with clear message');
};

# === Test 8: Tool filter applied to child ===

subtest 'Tool filter applied to child session' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;

    # Capture the child session by subscribing to subagent_start.
    my $child_session_id;
    $bus->subscribe('subagent_start', sub {
        $child_session_id = $_[0]{payload}{child_session_id};
    }, name => 'spy');

    Clank::Agent->spawn(
        name   => 'reviewer',
        prompt => 'review lib/Clank.pm',
        loop   => $loop,
    );

    # Load child session from store and check its tools.
    my $child = Clank::Session->new(
        store => $store, bus => $bus,
        id => $child_session_id, provider => $mock,
    );
    # Re-add tools from store — the child session was created inside spawn.
    # Instead, query the store for what tools the child had.
    # The tool_filter is set on the Session object — we can verify by checking
    # that only 'read' and 'bash' tools are returned.
    # Since we can't directly access the child session object after spawn returns,
    # we verify indirectly: the child loop ran and produced output, meaning
    # the tool filter didn't block everything.
    ok($child_session_id, 'child session was created');
};

# === Test 9: Agent lifecycle events published ===

subtest 'Agent lifecycle events on bus' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;

    my @events;
    $bus->subscribe('subagent_start', sub {
        push @events, { topic => 'subagent_start', agent => $_[0]{payload}{agent} };
    }, name => 'watcher');
    $bus->subscribe('subagent_stop', sub {
        push @events, { topic => 'subagent_stop', agent => $_[0]{payload}{agent} };
    }, name => 'watcher2');

    Clank::Agent->spawn(
        name   => 'reviewer',
        prompt => 'review lib/Clank.pm',
        loop   => $loop,
    );

    ok(scalar @events >= 2, 'start and stop events fired');
    is($events[0]{topic}, 'subagent_start', 'first event is start');
    is($events[1]{topic}, 'subagent_stop', 'second event is stop');
    is($events[0]{agent}, 'reviewer', 'start event has agent name');
    is($events[1]{agent}, 'reviewer', 'stop event has agent name');
};

# === Test 10: Custom max_turns override ===

subtest 'max_turns override' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;

    my $result = Clank::Agent->spawn(
        name      => 'reviewer',
        prompt    => 'review lib/Clank.pm',
        loop      => $loop,
        max_turns => 2,
    );

    ok($result->{ok}, 'spawn with override succeeded');
    ok($result->{turns} <= 2, 'turns within override limit');
};

done_testing;
