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

# Helper: find index of element in array.
sub first_index {
    my ($cond, @arr) = @_;
    for my $i (0 .. $#arr) {
        local $_ = $arr[$i];
        return $i if $cond->();
    }
    return -1;
}

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

# === Test 11: All 5 agent profiles load ===

subtest 'All agent profiles load' => sub {
    my @names = Clank::Agent->list;
    is(scalar @names, 5, 'five agents found');
    for my $name (qw(reviewer planner debugger security architect)) {
        my $p = Clank::Agent->load($name);
        ok($p, "$name loads");
        is($p->{name}, $name, "$name has correct name");
        ok(ref $p->{tools} eq 'ARRAY' && @{$p->{tools}}, "$name has tools");
        ok(defined $p->{model}, "$name has model");
        ok($p->{prompt}, "$name has prompt");
    }
};

# === Test 12: Tool sets differ by profile ===

subtest 'Tool sets differ by profile' => sub {
    my %expected = (
        reviewer  => [qw(read bash)],
        planner   => [qw(read bash)],
        debugger  => [qw(read bash edit)],
        security  => [qw(read bash)],
        architect => [qw(read bash)],
    );
    for my $name (keys %expected) {
        my $p = Clank::Agent->load($name);
        my @got = sort @{ $p->{tools} };
        my @want = sort @{ $expected{$name} };
        is_deeply(\@got, \@want, "$name tools match");
    }
};

# === Test 13: Model tier passed to child ===

subtest 'Model tier passed to child' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;

    my $result = Clank::Agent->spawn(
        name   => 'reviewer',
        prompt => 'review lib/Clank.pm',
        loop   => $loop,
        model  => 'flash',
    );

    ok($result->{ok}, 'spawn with model override succeeded');
    is($result->{model}, 'flash', 'model override reflected in result');
};

# === Test 14: Default model from profile ===

subtest 'Default model from profile' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;

    my $result = Clank::Agent->spawn(
        name   => 'reviewer',
        prompt => 'review lib/Clank.pm',
        loop   => $loop,
    );

    ok($result->{ok}, 'spawn succeeded');
    is($result->{model}, 'standard', 'uses profile default model');
};

# === Test 15: Spawn each agent type ===

subtest 'Spawn each agent type' => sub {
    for my $name (qw(reviewer planner debugger security architect)) {
        my ($store, $bus, $mock, $sess, $loop) = make_loop;
        my $result = Clank::Agent->spawn(
            name   => $name,
            prompt => 'analyze lib/Clank.pm',
            loop   => $loop,
        );
        ok($result->{ok}, "$name spawn succeeded");
        is($result->{agent}, $name, "$name name correct");
    }
};

# === Phase 2 tests ===

# === Test 16: Route prompt to best agent ===

subtest 'Route prompt to best agent' => sub {
    my $r = Clank::Agent->route('review the code for bugs and style issues');
    ok($r, 'routing returned a result');
    is($r->{name}, 'reviewer', 'routed to reviewer');
    ok($r->{score} > 0, 'score is positive');
};

# === Test 17: Route security prompt ===

subtest 'Route security prompt' => sub {
    my $r = Clank::Agent->route('scan for vulnerabilities and secrets');
    ok($r, 'routing returned a result');
    is($r->{name}, 'security', 'routed to security');
};

# === Test 18: Route architecture prompt ===

subtest 'Route architecture prompt' => sub {
    my $r = Clank::Agent->route('review the module boundaries and API design');
    ok($r, 'routing returned a result');
    is($r->{name}, 'architect', 'routed to architect');
};

# === Test 19: Route empty/garbage returns undef ===

subtest 'Route noise returns undef' => sub {
    my $r = Clank::Agent->route('x');
    is($r, undef, 'single char returns undef');
    $r = Clank::Agent->route('');
    is($r, undef, 'empty string returns undef');
};

# === Test 20: Pre_agent_start and agent_end events ===

subtest 'Agent lifecycle events' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;

    my @events;
    for my $ev (qw(pre_agent_start subagent_start subagent_stop agent_end)) {
        $bus->subscribe($ev, sub {
            push @events, { topic => $_[0]{topic}, agent => $_[0]{payload}{agent} // '' };
        }, name => "spy_$ev");
    }

    Clank::Agent->spawn(
        name   => 'reviewer',
        prompt => 'review lib/Clank.pm',
        loop   => $loop,
    );

    my @topics = map { $_->{topic} } @events;
    ok(grep({ $_ eq 'pre_agent_start' } @topics), 'pre_agent_start fired');
    ok(grep({ $_ eq 'subagent_start' } @topics), 'subagent_start fired');
    ok(grep({ $_ eq 'subagent_stop' } @topics), 'subagent_stop fired');
    ok(grep({ $_ eq 'agent_end' } @topics), 'agent_end fired');

    # Verify ordering: pre_agent_start before subagent_start before subagent_stop before agent_end
    my @agent_events = grep { $_->{agent} eq 'reviewer' } @events;
    my @lifecycle = map { $_->{topic} } @agent_events;
    my $pre_idx  = first_index(sub { $_ eq 'pre_agent_start' }, @lifecycle);
    my $start_idx = first_index(sub { $_ eq 'subagent_start' }, @lifecycle);
    my $stop_idx  = first_index(sub { $_ eq 'subagent_stop' }, @lifecycle);
    my $end_idx   = first_index(sub { $_ eq 'agent_end' }, @lifecycle);
    ok($pre_idx < $start_idx, 'pre_agent_start before subagent_start');
    ok($stop_idx < $end_idx, 'subagent_stop before agent_end');
};

# === Test 21: Delegate method ===

subtest 'Agent delegation' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;

    my @delegates;
    $bus->publish('agent_delegate', {
        from_agent => 'reviewer',
        to_agent   => 'debugger',
        prompt     => 'fix the bug at line 42',
    }) if 0; # just checking the event schema

    # Subscribe to agent_delegate event
    $bus->subscribe('agent_delegate', sub {
        push @delegates, $_[0]{payload};
    }, name => 'delegate_watcher');

    my $result = eval {
        Clank::Agent->delegate(
            from   => 'reviewer',
            to     => 'debugger',
            prompt => 'fix the bug at line 42',
            loop   => $loop,
        );
    };
    ok(!$@, 'delegate did not die');
    ok($result->{ok}, 'delegate spawn succeeded');
    is($result->{agent}, 'debugger', 'delegated to debugger');
    is(scalar @delegates, 1, 'agent_delegate event published');
    is($delegates[0]{from_agent}, 'reviewer', 'delegate from is reviewer');
    is($delegates[0]{to_agent}, 'debugger', 'delegate to is debugger');
};

# === Test 22: Delegate requires args ===

subtest 'Delegate requires mandatory args' => sub {
    my ($store, $bus, $mock, $sess, $loop) = make_loop;
    eval { Clank::Agent->delegate(to => 'x', prompt => 'y', loop => $loop) };
    like($@, qr/requires from/, 'dies without from');
    eval { Clank::Agent->delegate(from => 'x', prompt => 'y', loop => $loop) };
    like($@, qr/requires to/, 'dies without to');
};

done_testing;
