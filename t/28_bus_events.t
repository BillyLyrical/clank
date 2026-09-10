#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Bus;
use Clank::Bus::Events qw(event_info event_topic %EVENTS %ALIASES);

# === Test 1: Event catalog has all topics ===

subtest 'Event catalog completeness' => sub {
    my @expected = qw(
        session_start session_end user_prompt_submit
        before_agent_start agent_start agent_end agent_settled
        turn_start turn_end
        pre_tool_use post_tool_use post_tool_use_failure
        tool_execution_start tool_execution_end observation
        context context_knowledge_request context_procedural_guidance
        before_provider_request after_provider_response
        message_end message_update
        pre_compact post_compact
        subagent_start subagent_stop
        escalation_check
        mesh_broadcast director_done band_discover metrics_self_stats
    );

    for my $topic (@expected) {
        ok(exists $EVENTS{$topic}, "catalog has $topic");
        ok(defined $EVENTS{$topic}{description}, "$topic has description");
        ok(defined $EVENTS{$topic}{category}, "$topic has category");
        ok(ref $EVENTS{$topic}{payload} eq 'HASH', "$topic has payload hash");
    }
};

# === Test 2: Aliases map old names to canonical ===

subtest 'Alias mapping' => sub {
    is(event_topic('tool_call'), 'pre_tool_use', 'tool_call -> pre_tool_use');
    is(event_topic('tool_result'), 'post_tool_use', 'tool_result -> post_tool_use');
    is(event_topic('context.knowledge_request'), 'context_knowledge_request', 'dot notation -> underscore');
    is(event_topic('context.procedural_guidance'), 'context_procedural_guidance', 'dot notation -> underscore');
    is(event_topic('session_before_compact'), 'pre_compact', 'session_before_compact -> pre_compact');
    is(event_topic('session_compact'), 'post_compact', 'session_compact -> post_compact');
    is(event_topic('subagent.spawn'), 'subagent_start', 'subagent.spawn -> subagent_start');
    is(event_topic('subagent.done'), 'subagent_stop', 'subagent.done -> subagent_stop');
    is(event_topic('escalation.check'), 'escalation_check', 'escalation.check -> escalation_check');
    is(event_topic('mesh.broadcast'), 'mesh_broadcast', 'mesh.broadcast -> mesh_broadcast');
};

# === Test 3: Canonical names resolve to themselves ===

subtest 'Canonical names are identity' => sub {
    is(event_topic('pre_tool_use'), 'pre_tool_use', 'pre_tool_use stays');
    is(event_topic('post_tool_use'), 'post_tool_use', 'post_tool_use stays');
    is(event_topic('session_start'), 'session_start', 'session_start stays');
    is(event_topic('agent_end'), 'agent_end', 'agent_end stays');
};

# === Test 4: event_info returns schema for canonical and alias ===

subtest 'event_info works for both' => sub {
    my $info1 = event_info('tool_call');
    ok(defined $info1, 'event_info for alias');
    is($info1->{category}, 'tool', 'correct category');

    my $info2 = event_info('pre_tool_use');
    ok(defined $info2, 'event_info for canonical');
    is($info2->{category}, 'tool', 'same category');
};

# === Test 5: Bus alias resolution dispatches to canonical subscribers ===

subtest 'Bus aliases dispatch correctly' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);
    $bus->add_aliases(%ALIASES);

    # Subscribe to canonical name.
    my @received;
    $bus->subscribe('pre_tool_use', sub {
        my ($ev) = @_;
        push @received, { topic => $ev->{topic}, payload => $ev->{payload} };
        return undef;
    });

    # Publish under old name.
    $bus->publish('tool_call', { name => 'bash' });

    is(scalar @received, 1, 'subscriber received event');
    is($received[0]{topic}, 'tool_call', 'topic is the published name (not rewritten)');
    is($received[0]{payload}{name}, 'bash', 'payload intact');
};

# === Test 6: Bus aliases dispatch to old-name subscribers from canonical publish ===

subtest 'Bus aliases reverse dispatch' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);
    $bus->add_aliases(%ALIASES);

    # Subscribe to old name.
    my @received;
    $bus->subscribe('tool_call', sub {
        my ($ev) = @_;
        push @received, $ev->{topic};
        return undef;
    });

    # Publish under canonical name.
    $bus->publish('pre_tool_use', { name => 'read' });

    is(scalar @received, 1, 'old-name subscriber received canonical event');
    is($received[0], 'pre_tool_use', 'topic is canonical');
};

# === Test 7: No double-dispatch when alias = canonical ===

subtest 'No double dispatch' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);
    $bus->add_aliases(%ALIASES);

    my $count = 0;
    $bus->subscribe('pre_tool_use', sub { $count++; return undef });

    # Publish under canonical — should only fire once.
    $bus->publish('pre_tool_use', {});
    is($count, 1, 'no double dispatch for canonical');
};

# === Test 8: Existing subscribers still work without alias registration ===

subtest 'Backward compatible without aliases' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);
    # No add_aliases call.

    my @received;
    $bus->subscribe('tool_call', sub {
        push @received, $_[0]{topic};
        return undef;
    });

    $bus->publish('tool_call', { name => 'bash' });
    is(scalar @received, 1, 'works without aliases');
};

# === Test 9: Categories are consistent ===

subtest 'Category groups' => sub {
    my %categories;
    for my $topic (keys %EVENTS) {
        push @{ $categories{ $EVENTS{$topic}{category} } }, $topic;
    }

    ok(exists $categories{session}, 'has session category');
    ok(exists $categories{agent}, 'has agent category');
    ok(exists $categories{tool}, 'has tool category');
    ok(exists $categories{context}, 'has context category');
    ok(exists $categories{compaction}, 'has compaction category');
    ok(exists $categories{subagent}, 'has subagent category');
};

done_testing();
