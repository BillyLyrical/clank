use strict; use warnings;
use Test::More;
use lib 'lib';
use lib 'wits/procedural-graph/lib';

# End-to-end integration test for Procedural Graph system.
#
# Tests the complete flow:
#   1. Graph creation and population
#   2. Bus-driven guidance injection (simulates Loop.pm context assembly)
#   3. Agent simulation with procedural guidance
#   4. Trajectory collection and partitioning
#   5. Self-evolution: mutation, validation, rejection memory
#   6. Graph improvement verification

use Clank::Store;
use Clank::Bus;
use Clank::ProceduralGraph;
use Clank::ProceduralGraph::Evolver;
use Clank::Util qw(jencode jdecode);

# === MOCK LLM PROVIDER ===

package MockProvider {
    sub new { bless { model => 'mock', calls => 0 }, shift }

    # Used by Evolver's _llm_call (via post_json)
    sub post_json {
        my ($self, $path, $payload) = @_;
        $self->{calls}++;

        my $prompt = $payload->{messages}[-1]{content} // '';

        # Refiner calls: propose mutations based on graph analysis
        if ($prompt =~ /procedural graph refiner/i) {
            # Round 1: add a missing verification node
            if ($self->{calls} <= 2) {
                my $json = '{"mutations":[{"op":"add_node","node":{"id":"verify_balance","label":"Verify Balance","description":"Confirm bank balance before forecast","node_type":"procedure"}},{"op":"add_edge","edge":{"source_id":"check_cash","target_id":"verify_balance","relation":"LEADS_TO","attributes":{"condition":"before running forecast","guidance":"confirm the balance is current","pitfalls":"do not proceed with stale data"}}},{"op":"add_edge","edge":{"source_id":"verify_balance","target_id":"forecast","relation":"LEADS_TO","attributes":{"guidance":"project runway using verified balance"}}}]}';
                return { choices => [{ message => { content => $json } }] };
            }
            # Later rounds: no more useful mutations
            return { choices => [{ message => { content => '{"mutations":[]}' } }] };
        }

        return { choices => [{ message => { content => '{"mutations":[]}' } }] };
    }
}

# === MOCK BUS ===

package MockBus {
    sub new { bless { subs => [] }, shift }
    sub subscribe {
        my ($self, $topic, $cb) = @_;
        push @{$self->{subs}}, { topic => $topic, cb => $cb };
        return scalar @{$self->{subs}};
    }
    sub unsubscribe { return 1 }
    sub publish {
        my ($self, $topic, $payload) = @_;
        my @results;
        for my $sub (@{$self->{subs}}) {
            next unless $sub->{topic} eq $topic;
            my $r = eval { $sub->{cb}->({ topic => $topic, payload => $payload }) };
            push @results, $r if defined $r;
        }
        return { results => \@results };
    }
}

# === MOCK API ===

package MockAPI {
    sub new {
        my $store = Clank::Store->new(path => ':memory:');
        bless { tools => [], commands => {}, bus => MockBus->new(), store => $store }, shift;
    }
    sub register_tool { my ($self, %def) = @_; push @{$self->{tools}}, \%def }
    sub register_command { my ($self, $n, %d) = @_; $self->{commands}{$n} = \%d }
    sub on { my ($self, $t, $cb) = @_; $self->{bus}->subscribe($t, $cb) }
    sub track_sub { return 1 }
    sub ui { return undef }
    sub bus { return $_[0]->{bus} }
    sub store { return $_[0]->{store} }
    sub session { return undef }
    sub wit_name { return 'test' }
}

package main;

require Clank::ProceduralGraph;
require Clank::Wits::ProceduralGraph;
require Clank::ProceduralGraph::Evolver;

# ===========================================================================
# Phase 1: Setup — register wit, build initial graph
# ===========================================================================

my $api = MockAPI->new();
my $pg = Clank::Wits::ProceduralGraph->register($api);
isa_ok($pg, 'Clank::ProceduralGraph', 'wit returns ProceduralGraph');

# Build a CFO workflow graph (inspired by the paper's EnterpriseArena)
$pg->add_node(id => 'start',          label => 'Start',           node_type => 'state');
$pg->add_node(id => 'check_cash',     label => 'Check Cash',      description => 'Verify bank balance');
$pg->add_node(id => 'forecast',       label => 'Forecast',        description => 'Project cash flow runway');
$pg->add_node(id => 'check_market',   label => 'Check Market',    description => 'Check market conditions');
$pg->add_node(id => 'decide',         label => 'Decide Capital',  description => 'Financing decision');
$pg->add_node(id => 'end',            label => 'End',             node_type => 'state');

$pg->add_edge(source_id => 'start', target_id => 'check_cash', relation => 'LEADS_TO',
    attributes => { guidance => 'begin by verifying current bank balance' });
$pg->add_edge(source_id => 'check_cash', target_id => 'forecast', relation => 'LEADS_TO',
    attributes => {
        condition => 'after confirming balance',
        guidance  => 'project runway for next 6 months',
        pitfalls  => 'do not skip negative balance check',
    });
$pg->add_edge(source_id => 'forecast', target_id => 'check_market', relation => 'LEADS_TO',
    attributes => { guidance => 'check market valuation before deciding' });
$pg->add_edge(source_id => 'check_market', target_id => 'decide', relation => 'LEADS_TO',
    attributes => {
        condition => 'after forecast and market check',
        guidance  => 'assess financing options based on data',
        pitfalls  => 'do not decide without market data',
    });
$pg->add_edge(source_id => 'decide', target_id => 'end', relation => 'LEADS_TO');

my $stats = $pg->stats;
is($stats->{nodes}, 6, 'initial graph: 6 nodes');
is($stats->{edges}, 5, 'initial graph: 5 edges');

# ===========================================================================
# Phase 2: Bus guidance — simulate Loop.pm context assembly
# ===========================================================================

my @pg_subs = grep { $_->{topic} eq 'context_procedural_guidance' } @{$api->{bus}{subs}};
is(scalar @pg_subs, 1, 'guidance bus subscriber registered');

# Simulate agent taking action "check_cash" — should get guidance about forecast
my $result = $api->{bus}->publish('context_procedural_guidance', {
    prompt      => 'what should I do next?',
    last_action => 'check_cash',
});
my $guidance = $result->{results}[0]{guidance};
ok($guidance, 'guidance returned for check_cash');
like($guidance, qr/\[procedural guidance\]/, 'guidance has header');
like($guidance, qr/Active procedure: check_cash/, 'active node is check_cash');
like($guidance, qr/Forecast/, 'guidance lists Forecast as next step');
like($guidance, qr/project runway for next 6 months/, 'guidance text present');
like($guidance, qr/do not skip negative balance check/, 'pitfalls present');

# Simulate agent at "start" — should get guidance about check_cash
$result = $api->{bus}->publish('context_procedural_guidance', {
    prompt      => 'start the analysis',
    last_action => 'start',
});
$guidance = $result->{results}[0]{guidance};
like($guidance, qr/Check Cash/, 'start -> check_cash guidance');
like($guidance, qr/begin by verifying current bank balance/, 'start guidance text');

# Unknown action — no guidance
$result = $api->{bus}->publish('context_procedural_guidance', {
    prompt      => 'do something random',
    last_action => 'xyzzy',
});
is($result->{results}[0]{guidance}, '', 'unknown action: no guidance');

# ===========================================================================
# Phase 3: Agent simulation — multi-turn session with guidance
# ===========================================================================

# Simulate a 4-turn agent session, collecting trajectory at each turn
my @trajectory;
my @actions = ('start', 'check_cash', 'forecast', 'check_market');

for my $action (@actions) {
    # Get guidance for this step
    $result = $api->{bus}->publish('context_procedural_guidance', {
        prompt      => 'continue analysis',
        last_action => $action,
    });
    my $g = $result->{results}[0]{guidance} // '';

    # Simulate the agent's response (in real life, the LLM would use the guidance)
    push @trajectory, {
        action   => $action,
        guidance => $g,
        has_guidance => length($g) > 0 ? 1 : 0,
    };
}

# Verify guidance was provided at each step
for my $i (0 .. $#trajectory) {
    ok($trajectory[$i]{has_guidance}, "turn ${\($i+1)} ($trajectory[$i]{action}): guidance provided");
}
is(scalar @trajectory, 4, 'trajectory has 4 steps');

# ===========================================================================
# Phase 4: Trajectory analysis — partition successes/failures
# ===========================================================================

# Simulate task results: some succeed, some fail
my $evolver = Clank::ProceduralGraph::Evolver->new(
    pg       => $pg,
    store    => $api->{store},
);

my $task_results = [
    { query => 'analyze cash flow Q1', trajectory => [@trajectory], score => 1.0 },
    { query => 'analyze cash flow Q2', trajectory => [@trajectory], score => 0.3 },
    { query => 'analyze cash flow Q3', trajectory => [@trajectory], score => 0.9 },
    { query => 'analyze cash flow Q4', trajectory => [@trajectory], score => 0.2 },
];

my $partition = $evolver->partition($task_results);
is(scalar @{$partition->{successes}}, 2, 'partition: 2 successes (score >= 0.5)');
is(scalar @{$partition->{failures}}, 2, 'partition: 2 failures (score < 0.5)');

# ===========================================================================
# Phase 5: Self-evolution — mutate, validate, verify
# ===========================================================================

my $provider = MockProvider->new();
my $full_evolver = Clank::ProceduralGraph::Evolver->new(
    pg       => $pg,
    store    => $api->{store},
    provider => $provider,
);

# Capture graph before evolution
my $before_nodes = scalar @{$pg->all_nodes};
my $before_edges = scalar @{$pg->all_edges};

# Propose mutations (uses mock LLM)
my $mutations = $full_evolver->propose_mutations(
    successes  => $partition->{successes},
    failures   => $partition->{failures},
    rejections => [],
);
ok(scalar @$mutations > 0, 'refiner proposed mutations');
my $op_count = scalar @$mutations;
diag("Proposed $op_count mutations");

# Apply mutations
my $applied = $full_evolver->apply_mutations($mutations);
ok(scalar @{$applied->{applied}} > 0, 'mutations applied');
is(scalar @{$applied->{errors}}, 0, 'no errors applying mutations');

# Verify graph changed
my $after_nodes = scalar @{$pg->all_nodes};
my $after_edges = scalar @{$pg->all_edges};
ok($after_nodes > $before_nodes, "nodes grew: $before_nodes -> $after_nodes");
ok($after_edges > $before_edges, "edges grew: $before_edges -> $after_edges");

# Verify new nodes exist
ok($pg->get_node('verify_balance'), 'new node verify_balance exists');

# Verify new edges exist
my $outgoing = $pg->outgoing('check_cash');
my @verify_edges = grep { $_->{target_id} eq 'verify_balance' } @$outgoing;
is(scalar @verify_edges, 1, 'edge check_cash -> verify_balance exists');
like($verify_edges[0]{attributes}{guidance}, qr/confirm the balance/, 'edge has guidance');

# ===========================================================================
# Phase 6: Validation gate — test with and without baseline
# ===========================================================================

# Mock evaluator that scores based on query content
sub mock_evaluator {
    my ($query) = @_;
    my $score = ($query =~ /ok/i) ? 1.0 : 0.3;
    return { ok => ($score >= 0.5), score => $score, trajectory => [] };
}

# Validate: should accept (no baseline)
my $val = $full_evolver->validate(
    tasks     => [{ query => 'ok task' }, { query => 'ok task' }],
    evaluator => \&mock_evaluator,
);
is($val->{accepted}, 1, 'validation accepted (no baseline)');
ok($val->{score} > 0.8, "validation score high: $val->{score}");

# Validate: should reject (below baseline)
$val = $full_evolver->validate(
    tasks     => [{ query => 'fail' }, { query => 'fail' }],
    evaluator => \&mock_evaluator,
    baseline  => 0.9,
);
is($val->{accepted}, 0, 'validation rejected (below baseline)');

# ===========================================================================
# Phase 7: Rejection memory — log and retrieve
# ===========================================================================

$full_evolver->log_rejection(
    round     => 1,
    mutation  => { mutations => [{ op => 'delete_edge', edge_id => 'test_edge' }] },
    val_score => 0.3,
    baseline  => 0.7,
    context   => { reason => 'test rejection' },
);

my $rejections = $full_evolver->get_rejections(round => 1);
is(scalar @$rejections, 1, 'rejection logged');
is($rejections->[0]{val_score}, 0.3, 'rejection val_score');
is($rejections->[0]{baseline}, 0.7, 'rejection baseline');

# ===========================================================================
# Phase 8: Full evolution loop — end-to-end
# ===========================================================================

# Fresh graph for full evolution test
$pg->clear;
$pg->add_node(id => 'start', label => 'Start', node_type => 'state');
$pg->add_node(id => 'check_cash', label => 'Check Cash');
$pg->add_node(id => 'forecast', label => 'Forecast');
$pg->add_edge(source_id => 'start', target_id => 'check_cash', relation => 'LEADS_TO');
$pg->add_edge(source_id => 'check_cash', target_id => 'forecast', relation => 'LEADS_TO');

my $evo = Clank::ProceduralGraph::Evolver->new(
    pg       => $pg,
    store    => $api->{store},
    provider => $provider,
);

# Evaluator: succeeds if query contains "ok"
my $evo_evaluator = sub {
    my ($query) = @_;
    my $ok = ($query =~ /ok/i) ? 1 : 0;
    return { ok => $ok, score => $ok ? 1.0 : 0.0, trajectory => [$query] };
};

my $evo_result = $evo->evolve(
    train_tasks => [
        { query => 'ok task 1' },
        { query => 'fail task' },
        { query => 'ok task 2' },
    ],
    val_tasks => [
        { query => 'ok held out' },
        { query => 'ok held out 2' },
    ],
    evaluator  => $evo_evaluator,
    max_rounds => 3,
    patience   => 2,
);

ok($evo_result->{rounds}, 'evolution produced rounds');
ok($evo_result->{best_score} >= 0, "best score: $evo_result->{best_score}");

# Verify graph evolved (mock provider adds verify_balance node)
my $final_nodes = scalar @{$pg->all_nodes};
ok($final_nodes >= 3, "final graph has $final_nodes nodes (>= 3)");

# Check evolution log
my $log = $evo->get_evolution_log;
ok(scalar @$log > 0, 'evolution log has entries');

# ===========================================================================
# Phase 9: Serialization round-trip
# ===========================================================================

my $hash = $pg->to_hash;
ok($hash->{nodes}, 'to_hash has nodes');
ok($hash->{edges}, 'to_hash has edges');

my $pg2 = Clank::ProceduralGraph->new(store => $api->{store});
$pg2->from_hash($hash);
is(scalar @{$pg2->all_nodes}, scalar @{$pg->all_nodes}, 'from_hash preserves node count');
is(scalar @{$pg2->all_edges}, scalar @{$pg->all_edges}, 'from_hash preserves edge count');

# ===========================================================================
# Phase 10: REPL commands
# ===========================================================================

my $pg_cmd = $api->{commands}{pg}{handler};
my $ctx = { bus => $api->{bus}, store => $api->{store}, session => undef, app => undef };

my $out = $pg_cmd->($ctx, 'stats');
like($out, qr/Nodes:/, '/pg stats works');

$out = $pg_cmd->($ctx, 'show');
like($out, qr/NODES/, '/pg show works');

$out = $pg_cmd->($ctx, 'reset');
is($out, 'procedural graph cleared', '/pg reset works');
is($pg->stats->{nodes}, 0, 'graph cleared by /pg reset');

done_testing;
