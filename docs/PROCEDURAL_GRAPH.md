# Procedural Graph

Status: implemented. Phase 1-4 complete.

A directed attributed graph of procedural knowledge that guides the LLM
agent's execution online and evolves itself offline from execution feedback.

Based on "Procedural Graphs: Self-Evolving Execution Structures for LLM
Agents" (Lu et al., Google, Sep 2026).

## Quick Start

```perl
# Create a procedural graph
use Clank::ProceduralGraph;
my $pg = Clank::ProceduralGraph->new(store => $store);

# Add nodes (procedures, states, skills)
$pg->add_node(id => 'start', label => 'Start', node_type => 'state');
$pg->add_node(id => 'check', label => 'Check Cash', description => 'Verify bank balance');
$pg->add_node(id => 'forecast', label => 'Forecast', description => 'Project runway for 6 months');

# Add edges with attributes
$pg->add_edge(
    source_id => 'start', target_id => 'check',
    relation  => 'LEADS_TO',
    attributes => {
        condition => 'beginning of cycle',
        guidance  => 'verify balance before any forecast',
        pitfalls  => 'do not skip negative balance check',
    },
);
$pg->add_edge(
    source_id => 'check', target_id => 'forecast',
    relation  => 'LEADS_TO',
    attributes => { guidance => 'project runway for 6 months' },
);

# Localize agent's position and get guidance
my $node_id = $pg->localize('check');  # matches "Check Cash" node
my $subgraph = $pg->extract_guidance_subgraph($node_id, 2);
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  ProceduralGraph.pm (core data layer)               │
│  SQLite: pg_nodes, pg_edges, pg_evolution_log,      │
│          pg_rejections                               │
│  CRUD, graph queries, localization, serialization    │
├─────────────────────────────────────────────────────┤
│  ProceduralGraph::Evolver.pm (self-evolution)        │
│  4-step loop: rollout → mutate → validate → reject   │
│  LLM refiner, rejection memory, snapshot/rollback    │
├─────────────────────────────────────────────────────┤
│  Wits::ProceduralGraph (bus + tools + REPL)          │
│  context_procedural_guidance bus topic               │
│  8 tools: show, add_node, add_edge, delete_*, stats, │
│           reset, evolve                              │
│  /pg show|stats|reset REPL commands                  │
├─────────────────────────────────────────────────────┤
│  Loop.pm (context assembly)                          │
│  Step 3d: publishes context_procedural_guidance      │
│  _extract_last_action(): finds last tool call        │
└─────────────────────────────────────────────────────┘
```

## Modules

| Module | Purpose |
|--------|---------|
| `Clank::ProceduralGraph` | Core data layer: schema, CRUD, graph queries, localization, subgraph extraction, serialization |
| `Clank::ProceduralGraph::Evolver` | Self-evolution: diagnostic rollout, mutation, validation gate, rejection memory |
| `Clank::Wits::ProceduralGraph` | Bus integration, REPL commands, LLM tools |

## Online Guidance

The wit subscribes to `context_procedural_guidance` on the bus. Before each
LLM call, Loop.pm publishes this event with the last action taken. The wit:

1. **Localizes** the active node by matching the last action (exact → fuzzy → reverse fuzzy)
2. **Extracts** the 2-hop directed neighborhood of that node
3. **Formats** the subgraph as a `[procedural guidance]` context block
4. **Injects** it as a user message before the solver's prompt

The guidance biases the solver without dictating — the LLM sees available
transitions with conditions, guidance, and pitfalls, but chooses freely.

## Self-Evolution

The Evolver runs an offline loop that improves the graph topology:

```
for round = 1..K:
  1. Run tasks with current graph → collect trajectories
  2. LLM refiner contrasts successes vs failures → propose mutations
  3. Apply mutations → validate on held-out tasks
  4. Accept if val_score >= baseline, else rollback + log rejection
```

### Using the Evolver

```perl
use Clank::ProceduralGraph::Evolver;

my $evolver = Clank::ProceduralGraph::Evolver->new(
    pg       => $pg,
    store    => $store,
    provider => $provider,  # LLM for refiner calls
);

# Define evaluator: runs a query, returns { ok, score, trajectory }
my $evaluator = sub {
    my ($query) = @_;
    my $result = $app->loop->run_prompt($query);
    return {
        ok    => $result->{ok},
        score => $result->{ok} ? 1.0 : 0.0,
        trajectory => [ $result->{response} ],
    };
};

my $result = $evolver->evolve(
    train_tasks => [ { query => 'task 1' }, { query => 'task 2' } ],
    val_tasks   => [ { query => 'held out task' } ],
    evaluator   => $evaluator,
    max_rounds  => 10,
    patience    => 3,   # stop if no improvement for 3 rounds
);

# $result = { rounds => [...], best_score => 0.85, graph_stats => {...} }
```

### Via the LLM Tool

The `pg_evolve` tool accepts JSON task arrays:

```json
{
  "train_tasks": "[{\"query\":\"task 1\"},{\"query\":\"task 2\"}]",
  "val_tasks": "[{\"query\":\"held out task\"}]",
  "max_rounds": 3
}
```

## REPL Commands

| Command | Description |
|---------|-------------|
| `/pg show` | Display the current graph (nodes and edges) |
| `/pg stats` | Show node/edge counts and evolution rounds |
| `/pg reset` | Clear the entire graph |
| `/pg evolve` | Run self-evolution (use pg_evolve tool for parameters) |

## LLM Tools

| Tool | Description |
|------|-------------|
| `pg_show_graph` | Display nodes and edges |
| `pg_add_node` | Add a procedure/state/skill node |
| `pg_add_edge` | Add a directed attributed edge |
| `pg_delete_edge` | Remove an edge |
| `pg_delete_node` | Remove a node (soft-deletes incident edges) |
| `pg_stats` | Node/edge counts, evolution rounds |
| `pg_reset` | Clear the entire graph |
| `pg_evolve` | Run self-evolution with custom tasks |

## Edge Attributes

Each edge carries three optional textual attributes (per the paper):

| Attribute | Purpose | Example |
|-----------|---------|---------|
| `condition` | When this transition applies | "projected runway falls below safety buffer" |
| `guidance` | How to execute the transition | "submit request early to allow financing delay" |
| `pitfalls` | What to avoid | "do not stack a second request while one is pending" |

## Node Types

| Type | Purpose |
|------|---------|
| `procedure` | A tool call or action (default) |
| `state` | A decision point or status (Start, End) |
| `skill` | A capability or competency |
| `reasoning` | An internal reasoning step |

## Implementation Phases

| Phase | What | Status |
|-------|------|--------|
| 1 | Core data layer (`ProceduralGraph.pm`) | ✅ 69 tests |
| 2 | Online guidance (wit + Loop.pm) | ✅ 44 tests |
| 3 | Self-evolution (`Evolver.pm`) | ✅ 54 tests |
| 4 | Polish (CLI, tools, docs) | ✅ Done |

Total: 1164 tests, all passing.
