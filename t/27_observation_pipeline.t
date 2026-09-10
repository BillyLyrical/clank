#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Clank::Store;
use Clank::Bus;
use Clank::Util qw(now_ms);

# Mock tool that simulates a real tool execution
package MockTool {
    sub new { bless { name => $_[1] }, shift }
    sub name { $_[0]->{name} }
    sub schema { { type => 'object', properties => {} } }
    sub openai_schema {
        my ($self) = @_;
        return {
            type => 'function',
            function => {
                name        => $self->{name},
                description => "Mock tool: $self->{name}",
                parameters  => { type => 'object', properties => {} },
            },
        };
    }
    sub run {
        my ($self, $args) = @_;
        return { output => "MockTool executed: $self->{name}", isError => 0 };
    }
}

package MockProvider {
    sub new { bless { model => 'mock', _call_count => 0 }, shift }
    sub chat_payload {
        my ($self, %args) = @_;
        return {
            model    => $self->{model},
            messages => $args{messages},
            tools    => $args{tools},
        };
    }
    sub post_json {
        my ($self, $path, $payload) = @_;
        $self->{_call_count}++;
        if ($self->{_call_count} == 1) {
            return {
                choices => [{
                    message => {
                        content => '',
                        tool_calls => [{
                            id => 'call_1',
                            function => { name => 'mock_read', arguments => '{"path":"t/test.t"}' },
                        }],
                    },
                    finish_reason => 'stop',
                }],
                usage => { prompt_tokens => 10, completion_tokens => 5 },
            };
        }
        return {
            choices => [{ message => { content => 'Done' }, finish_reason => 'stop' }],
            usage => { prompt_tokens => 10, completion_tokens => 5 },
        };
    }
}

package main;

require Clank::Session;
require Clank::Loop;
require Clank::Crystallizer;

# === Test 1: Observation fires on tool execution ===

subtest 'Tool execution publishes observation' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);

    # Track observation events.
    my @observations;
    $bus->subscribe('observation', sub {
        my ($ev) = @_;
        push @observations, $ev->{payload};
        return undef;
    });

    # Create a session with a mock tool and provider.
    my $provider = MockProvider->new();
    my $session = Clank::Session->new(store => $store, bus => $bus, provider => $provider);
    my $tool = MockTool->new('mock_read');
    $session->add_tool($tool);

    # Create a loop.
    my $loop = Clank::Loop->new(
        session   => $session,
        stream    => 0,
        max_turns => 5,
    );

    # Run the loop — this should trigger tool execution → observation.
    $session->add_user_message("read t/test.t");
    my $result = $loop->run_prompt("read t/test.t");

    ok($result->{ok}, 'loop completed');

    # Verify observation was published.
    ok(scalar @observations > 0, 'observation was published');
    is($observations[0]{tool}, 'mock_read', 'observation has tool name');
    is($observations[0]{success}, 1, 'observation reports success');
    ok(defined $observations[0]{input}, 'observation has input');
    ok(defined $observations[0]{output}, 'observation has output');
};

# === Test 2: Crystallizer receives observations ===

subtest 'Crystallizer observes tool calls via bus' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);
    require Clank::Wit::API;
    my $api = Clank::Wit::API->new(bus => $bus, store => $store);

    my $c = Clank::Crystallizer->new(store => $store);
    $c->register($api);

    # Insert a rule that matches 'bash' tool.
    $store->dbh->do(
        "INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, scope, project_id, domain, created_at, last_observed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        undef, 'fact_bash_terminal', 'fact', 'bash', 'use bash for terminal', 0.8, 'crystallized', 'global', '', 'terminal', now_ms(), 0);

    my $rule_before = $c->get_rule('fact_bash_terminal');
    is($rule_before->{last_observed}, 0, 'last_observed is 0 before observation');

    # Simulate what Loop.pm does: publish observation after tool execution.
    $bus->publish('observation', {
        tool    => 'bash',
        input   => { command => 'ls' },
        output  => "file1.txt\nfile2.txt",
        success => 1,
    });

    my $rule_after = $c->get_rule('fact_bash_terminal');
    ok($rule_after->{last_observed} > 0, 'last_observed updated after observation');
    is($rule_after->{use_count}, 1, 'use_count incremented');
};

# === Test 3: Failed tool calls also produce observations ===

subtest 'Failed tool calls produce observations' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);

    my @observations;
    $bus->subscribe('observation', sub {
        my ($ev) = @_;
        push @observations, $ev->{payload};
        return undef;
    });

    # Simulate a failed tool call (what Loop.pm publishes).
    $bus->publish('observation', {
        tool    => 'bash',
        input   => { command => 'rm -rf /' },
        output  => 'Permission denied',
        success => 0,
    });

    is(scalar @observations, 1, 'observation published for failed tool');
    is($observations[0]{success}, 0, 'observation reports failure');
};

# === Test 4: Subagent tool calls feed same Crystallizer ===

subtest 'Subagent observations reach parent Crystallizer' => sub {
    my $store = Clank::Store->new(db => ':memory:');
    my $bus = Clank::Bus->new(store => $store);
    require Clank::Wit::API;
    my $api = Clank::Wit::API->new(bus => $bus, store => $store);

    my $c = Clank::Crystallizer->new(store => $store);
    $c->register($api);

    # Insert a rule matching 'grep'.
    $store->dbh->do(
        "INSERT INTO crystallized_rules (name, rule_type, condition_def, action_def, confidence, source, scope, project_id, domain, created_at, last_observed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        undef, 'fact_grep_search', 'fact', 'grep', 'use grep for search', 0.8, 'crystallized', 'global', '', 'search', now_ms(), 0);

    # Simulate subagent publishing observation on the shared bus.
    $bus->publish('observation', {
        tool    => 'grep',
        input   => { pattern => 'subroutine' },
        output  => "lib/Foo.pm:42: sub foo {",
        success => 1,
    });

    my $rule = $c->get_rule('fact_grep_search');
    ok($rule->{last_observed} > 0, 'subagent observation reached Crystallizer');
    is($rule->{use_count}, 1, 'use_count incremented by subagent tool call');
};

done_testing();
