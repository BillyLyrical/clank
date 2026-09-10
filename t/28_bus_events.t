#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Bus;
use Clank::Bus::Events qw(event_info event_topic %EVENTS);

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

# === Test 2: event_info returns correct schema ===

subtest 'event_info returns schema' => sub {
    my $info = event_info('pre_tool_use');
    ok(defined $info, 'event_info for known topic');
    is($info->{category}, 'tool', 'correct category');
    ok(defined $info->{description}, 'has description');
    ok(ref $info->{payload} eq 'HASH', 'has payload hash');

    my $unknown = event_info('nonexistent_topic');
    ok(!defined $unknown, 'event_info returns undef for unknown');
};

# === Test 3: event_topic is identity ===

subtest 'event_topic returns topic unchanged' => sub {
    is(event_topic('pre_tool_use'), 'pre_tool_use', 'canonical stays');
    is(event_topic('agent_end'), 'agent_end', 'agent_end stays');
    is(event_topic('session_start'), 'session_start', 'session_start stays');
};

# === Test 4: Bus publish/subscribe with canonical names ===

subtest 'Bus dispatch with canonical names' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);

    my @received;
    $bus->subscribe('pre_tool_use', sub {
        my ($ev) = @_;
        push @received, { topic => $ev->{topic}, payload => $ev->{payload} };
        return undef;
    });

    $bus->publish('pre_tool_use', { name => 'bash' });

    is(scalar @received, 1, 'subscriber received event');
    is($received[0]{topic}, 'pre_tool_use', 'topic matches');
    is($received[0]{payload}{name}, 'bash', 'payload intact');
};

# === Test 5: Bus glob matching still works ===

subtest 'Bus glob matching' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);

    my $count = 0;
    $bus->subscribe('tool_execution_*', sub { $count++; return undef });

    $bus->publish('tool_execution_start', { name => 'bash' });
    $bus->publish('tool_execution_end', { name => 'bash' });
    $bus->publish('pre_tool_use', { name => 'bash' });

    is($count, 2, 'glob matched two tool_execution events, not pre_tool_use');
};

# === Test 6: Categories are consistent ===

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
