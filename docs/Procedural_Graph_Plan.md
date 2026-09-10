# Procedural Graph Implementation Plan

> Integrating "Procedural Graphs: Self-Evolving Execution Structures for LLM Agents"
> (Lu et al., Google, Sep 2026) into Clank's neurosymbolic architecture.

---

## 1. What We're Building

A **Procedural Graph (PG)** — a directed attributed graph of procedural knowledge
that guides the LLM agent's execution online and evolves itself offline from
execution feedback.

Where knowledge graphs answer *what-is* questions, procedural graphs answer
*what-to-do* questions. Nodes are procedures (tool calls, reasoning steps,
states). Edges are admissible transitions with attributes: `condition`,
`guidance`, `pitfalls`.

The paper's key insight maps directly to Clank's thesis: procedural knowledge
should be explicit, inspectable, and editable outside model weights.

---

## 2. Design Decisions

### 2.1 Separate from WorldModel

WorldModel stores factual knowledge (entity-relation-entity). The PG stores
procedural knowledge (procedure-relation-procedure). Different schemas, different
queries, different mutation patterns. They share the same SQLite DB but have
independent tables.

**Rationale**: WorldModel does temporal reasoning, belief revision, causal
propagation. PG does topology queries, subgraph extraction, guided traversal.
Mixing them would complect orthogonal concerns.

### 2.2 Bus Topic Separation

PG guidance uses a dedicated topic `context.procedural_guidance`, not the
existing `context.knowledge_request`. The loop collects both and injects them
as separate context blocks.

**Rationale**: Clean separation. The PG wit doesn't need to know about WorldModel
and vice versa. Both feed into the same assembly pipeline but are independent.

### 2.3 Guidance Is Pre-Formatted, Not LLM-Generated

The paper uses a separate "guidance model" (Ψ) to translate the subgraph into
situational text. We simplify: extract the relevant edge attributes and format
them directly. The solver reads structured guidance, not LLM-paraphrased prose.

**Rationale**: One fewer LLM call per turn. Edge attributes are already written
in natural language — reformatting them adds latency and token cost without
clear benefit. The solver is an LLM; it can interpret structured guidance.

If empirical results show the paraphrasing helps, we can add an optional
guidance LLM call later. Start simple.

### 2.4 Evolution Uses Crystallizer Pattern

The self-evolution loop mirrors Crystallizer's pipeline (agent_end → extract
patterns → validate → store) but operates on graph topology instead of
individual rules. The refiner proposes mutations; a validation gate commits
or rejects.

**Rationale**: Same architectural pattern, different domain. Reuse the event
journal, provider interface, and validation infrastructure.

### 2.5 SQLite Storage, Not In-Memory

The PG lives in SQLite tables, queryable via Datalog and SQL. Nodes and edges
are persisted across sessions.

**Rationale**: Single source of truth. Survives restarts. Datalog can reason
over graph structure (reachability, cycle detection). Consistent with
WorldModel's approach.

---

## 3. Data Model

### 3.1 SQLite Schema

```sql
-- Procedural graph nodes
CREATE TABLE pg_nodes (
    id          TEXT PRIMARY KEY,  -- UUID or semantic ID (e.g. "check_cash")
    label       TEXT NOT NULL,     -- Human-readable name
    description TEXT,              -- What this procedure does
    node_type   TEXT DEFAULT 'procedure',  -- procedure | state | skill | reasoning
    attributes  TEXT,              -- JSON: freeform metadata
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);

-- Procedural graph edges (directed, attributed)
CREATE TABLE pg_edges (
    id          TEXT PRIMARY KEY,
    source_id   TEXT NOT NULL REFERENCES pg_nodes(id),
    target_id   TEXT NOT NULL REFERENCES pg_nodes(id),
    relation    TEXT NOT NULL,     -- e.g. LEADS_TO, REQUIRES, BLOCKS, CONDITIONAL
    attributes  TEXT,              -- JSON: { condition, guidance, pitfalls }
    weight      REAL DEFAULT 1.0,  -- For future scoring/ranking
    enabled     INTEGER DEFAULT 1, -- Soft-delete without removing
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);

-- Evolution history (audit trail)
CREATE TABLE pg_evolution_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    round       INTEGER NOT NULL,
    mutation    TEXT NOT NULL,     -- JSON: { op, edge/node id, details }
    candidate   TEXT NOT NULL,     -- JSON: full candidate graph snapshot
    train_score REAL,
    val_score   REAL,
    committed   INTEGER NOT NULL,  -- 1 = accepted, 0 = rejected
    reason      TEXT,              -- Why committed/rejected
    created_at  INTEGER NOT NULL
);

-- Rejection memory (negative evidence for refiner)
CREATE TABLE pg_rejections (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    round       INTEGER NOT NULL,
    mutation    TEXT NOT NULL,     -- JSON: what was proposed
    val_score   REAL,             -- Score that caused rejection
    baseline    REAL,             -- Score it was compared against
    context     TEXT,             -- JSON: relevant trajectory excerpts
    created_at  INTEGER NOT NULL
);

CREATE INDEX idx_pg_edges_source ON pg_edges(source_id);
CREATE INDEX idx_pg_edges_target ON pg_edges(target_id);
CREATE INDEX idx_pg_evolution_round ON pg_evolution_log(round);
```

### 3.2 Attribute Schema

Each edge's `attributes` JSON follows the paper's three-field schema:

```json
{
    "condition": "projected runway falls below the safety buffer",
    "guidance": "submit the request early to allow for financing delivery delay",
    "pitfalls": "do not stack a second request while one is pending"
}
```

All three fields are optional. An edge with only `guidance` is a simple
transition hint. An edge with `condition` makes the transition conditional.
`pitfalls` are anti-patterns to avoid.

---

## 4. Module Architecture

### 4.1 New Modules

```
lib/Clank/ProceduralGraph.pm        # Core: schema, CRUD, subgraph extraction
lib/Clank/ProceduralGraph/Evolver.pm # Self-evolution loop
```

### 4.2 New Wit

```
wits/procedural-graph/lib/Clank/Wits/ProceduralGraph.pm  # Bus integration
```

### 4.3 Module Responsibilities

#### `Clank::ProceduralGraph`

Core graph operations. No bus dependencies — pure data layer.

```perl
# Construction
my $pg = Clank::ProceduralGraph->new(store => $store);

# Node operations
$pg->add_node(%opts);
$pg->get_node($id);
$pg->update_node($id, %opts);
$pg->delete_node($id);  # soft: disables all incident edges

# Edge operations
$pg->add_edge(%opts);   # validates source/target exist, checks for cycles
$pg->get_edge($id);
$pg->update_edge($id, %opts);
$pg->disable_edge($id);  # soft-delete
$pg->enable_edge($id);

# Graph queries
$pg->outgoing($node_id);           # edges where source = node_id
$pg->incoming($node_id);           # edges where target = node_id
$pg->neighborhood($node_id, $h);   # h-hop directed neighborhood
$pg->all_nodes();
$pg->all_edges();

# Trajectory localization
$pg->localize($last_action);       # match action to nearest node

# Subgraph extraction (for guidance)
$pg->extract_guidance_subgraph($node_id, $hops);

# Import/export
$pg->to_hash();                    # Serializable graph representation
$pg->from_hash($data);             # Load from hash/JSON
$pg->clear();                      # Reset (for evolution from scratch)
```

#### `Clank::ProceduralGraph::Evolver`

Self-evolution loop. Depends on ProceduralGraph + Provider + Store.

```perl
my $evolver = Clank::ProceduralGraph::Evolver->new(
    pg       => $pg,
    provider => $provider,  # LLM for refiner calls
    store    => $store,     # Event journal access
);

# Run one evolution round
my $result = $evolver->evolve_round(
    train_tasks => \@tasks,    # Array of { query, expected } hashes
    val_tasks   => \@val,      # Held-out validation set
);

# Full evolution loop
my $final = $evolver->evolve(
    train_tasks => \@tasks,
    val_tasks   => \@val,
    rounds      => 10,
    patience    => 3,          # Stop if no improvement for N rounds
);
```

#### `Clank::Wits::ProceduralGraph` (wit)

Bus integration. Wires PG into the context assembly pipeline.

```perl
sub register {
    my ($self, $api) = @_;

    # Register tools for manual graph inspection/editing
    $api->register_tool(
        name        => 'pg_show_graph',
        description => 'Display the current procedural graph',
        execute     => sub { ... },
    );

    $api->register_tool(
        name        => 'pg_add_node',
        description => 'Add a node to the procedural graph',
        execute     => sub { ... },
    );

    $api->register_tool(
        name        => 'pg_add_edge',
        description => 'Add an edge to the procedural graph',
        execute     => sub { ... },
    );

    $api->register_tool(
        name        => 'pg_evolve',
        description => 'Run one round of self-evolution on the procedural graph',
        execute     => sub { ... },
    );

    # Bus: provide procedural guidance context
    $api->on('context.procedural_guidance', sub {
        my ($ev) = @_;
        my $prompt = $ev->{payload}{prompt};
        my $last_action = $ev->{payload}{last_action};

        # Localize active node
        my $node_id = $pg->localize($last_action);
        return { guidance => '' } unless $node_id;

        # Extract subgraph
        my $subgraph = $pg->extract_guidance_subgraph($node_id, 2);

        # Format as context injection
        return { guidance => $self->format_guidance($subgraph) };
    });

    # Bus: trigger evolution after agent session
    $api->on('agent_end', sub {
        my ($ev) = @_;
        # Store trajectory for potential evolution
        # (actual evolution triggered by explicit command or batch schedule)
    });
}
```

### 4.4 Context Assembly Integration

The loop's context assembly in `Loop.pm` gains one new step:

```
  5. KNOWLEDGE CONTEXT
     bus: context.knowledge_request
       ├── WorldModel → entities, facts, beliefs
       └── Crystallizer → deterministic rules
  5a. PROCEDURAL GUIDANCE                    ← NEW
     bus: context.procedural_guidance
       └── ProceduralGraph → subgraph guidance
```

This is a **minimal change** to Loop.pm — publish one more bus event, collect
the response, inject as a `[procedural guidance]` context block. The existing
pipeline pattern (`publish → collect → inject`) is already established.

---

## 5. Online Guidance Pipeline

### 5.1 Per-Turn Flow

```
User prompt arrives
  │
  ├─ Loop.pm assembles context (existing)
  │
  ├─ Bus: context.procedural_guidance { prompt, last_action }
  │    │
  │    ├─ ProceduralGraph::localize($last_action)
  │    │   → match last tool call / action text to nearest node
  │    │   → fallback: Start node, or full graph if no match
  │    │
  │    ├─ ProceduralGraph::extract_guidance_subgraph($node_id, h=2)
  │    │   → outgoing edges from node_id, up to 2 hops
  │    │   → returns: { node, edges: [{target, relation, attributes}] }
  │    │
  │    └─ Format as structured text:
  │       "PROCEDURAL GUIDANCE (active: check_cash_in_bank)
  │        Next possible steps:
  │        → cash_flow_forecast (LEADS_TO)
  │          condition: after verifying current balance
  │          guidance: project runway for next 6 months
  │          pitfalls: do not skip negative balance check
  │        → check_market_data (LEADS_TO)
  │          condition: before any financing decision
  │          guidance: check latest valuation metrics"
  │
  └─ LLM receives: system_prompt + [knowledge context] + [procedural guidance] + history
```

### 5.2 Node Localization

Matching the agent's last action to a graph node. Three strategies, in order:

1. **Exact match**: last tool call name matches a node label
2. **Fuzzy match**: substring/keyword overlap between action text and node labels
3. **Fallback**: use the `Start` node, or if no `Start`, return full graph

The paper uses exact match (`Match(a_{t-1}, V)`). We start with exact + fuzzy
and can refine based on empirical results.

### 5.3 Guidance Formatting

The formatted guidance block is injected as a user message (like knowledge
context). Structure:

```
[procedural guidance]
Active procedure: <node_label>
<node_description>

Available transitions:
  → <target_label> (<relation>)
    condition: <condition>
    guidance: <guidance>
    pitfalls: <pitfalls>

  → <target_label> (<relation>)
    ...
[/procedural guidance]
```

Only non-empty attribute fields are included. The block is omitted entirely
if localization fails or the graph is empty.

---

## 6. Self-Evolution Loop

### 6.1 Four-Step Loop (Per Paper's Algorithm 1)

```
┌──────────────────────────────────────────────────────┐
│ Step 1: DIAGNOSTIC ROLLOUT                            │
│   Run solver on training batch with current PG        │
│   Record: { query, trajectory, score } per task       │
│   Partition: successes vs failures                    │
├──────────────────────────────────────────────────────┤
│ Step 2: FEEDBACK-DRIVEN MUTATION                      │
│   LLM refiner reads partitioned trajectories          │
│   Identifies:                                         │
│     - Repeated error loops in failures                │
│     - Multi-step shortcuts in successes               │
│   Proposes mutations:                                 │
│     ADD: missing nodes/edges                          │
│     DELETE: failure-inducing nodes/edges              │
│     REVISE: edge attributes (delete + re-add)         │
│   Structural checks: no orphans, no dangling refs     │
├──────────────────────────────────────────────────────┤
│ Step 3: VALIDATION GATING                             │
│   Apply mutations to candidate graph                  │
│   Run solver on held-out validation set               │
│   Accept if val_score >= baseline                     │
│   Reject otherwise                                    │
├──────────────────────────────────────────────────────┤
│ Step 4: REJECTION MEMORY                              │
│   Log rejected mutations + context to pg_rejections   │
│   Refiner sees these as negative evidence next round  │
└──────────────────────────────────────────────────────┘
```

### 6.2 Mutation Operations

The refiner operates on a serialized graph representation and proposes JSON
edit sets:

```json
{
    "mutations": [
        {
            "op": "add_node",
            "node": {
                "id": "verify_balance",
                "label": "Verify Account Balance",
                "description": "Check current bank balance before forecast",
                "node_type": "procedure"
            }
        },
        {
            "op": "add_edge",
            "edge": {
                "source": "check_cash_in_bank",
                "target": "verify_balance",
                "relation": "LEADS_TO",
                "attributes": {
                    "condition": "before running cash flow forecast",
                    "guidance": "confirm the balance matches expectations",
                    "pitfalls": "do not proceed if balance is stale (>24h)"
                }
            }
        },
        {
            "op": "delete_edge",
            "edge_id": "edge-uuid-here"
        },
        {
            "op": "revise_edge",
            "edge_id": "edge-uuid-here",
            "attributes": {
                "condition": "updated condition text",
                "guidance": "updated guidance text",
                "pitfalls": "updated pitfalls text"
            }
        }
    ]
}
```

### 6.3 Refiner Prompt Structure

```
You are a procedural graph refiner. You analyze agent execution trajectories
and propose improvements to the procedural graph.

CURRENT GRAPH:
<serialized graph>

REJECTED MUTATIONS (do not repeat these):
<from pg_rejections>

SUCCESSFUL TRAJECTORIES:
<excerpts from high-scoring runs>

FAILED TRAJECTORIES:
<excerpts from low-scoring runs>

Based on this analysis, propose mutations to improve the graph.
Focus on:
1. Missing transitions that would prevent failure loops
2. Edges that steer agents toward repeated errors
3. Attribute revisions that clarify ambiguous guidance
4. Pruning edges that encourage wrong behavior

Return a JSON edit set.
```

### 6.4 Validation

The validation gate runs the solver on held-out tasks with the candidate
graph. Key implementation detail: **validation must be reproducible**. The
paper uses greedy decoding (temperature 0) for this. We do the same.

If the candidate's mean validation score >= the current graph's cached score,
commit. Otherwise reject and log.

### 6.5 From-Scratch vs Expert Initialization

The paper shows both work. We support:

1. **Empty graph**: start with just `Start → End`, let evolution build
2. **Expert prior**: user provides initial nodes/edges via tools or config
3. **Hybrid**: seed with core workflow, let evolution fill in details

The evolution loop works identically in all three cases.

---

## 7. Implementation Phases

### Phase 1: Core Data Layer

**Deliverable**: `Clank::ProceduralGraph` with SQLite storage and basic queries.

**Tasks**:
1. Define schema (create tables in Store or via ProceduralGraph init)
2. Implement CRUD for nodes and edges
3. Implement `outgoing()`, `incoming()`, `neighborhood()`
4. Implement `localize()` with exact + fuzzy matching
5. Implement `extract_guidance_subgraph()`
6. Implement `to_hash()` / `from_hash()` for serialization
7. Write tests: CRUD, subgraph extraction, localization, edge cases

**Dependencies**: Store.pm (existing), nothing new.

**Estimated scope**: ~400 lines core + ~200 lines tests.

### Phase 2: Online Guidance

**Deliverable**: PG context injection wired into the agent loop.

**Tasks**:
1. Create `wits/procedural-graph/` wit directory
2. Implement wit `register()`: bus subscription for `context.procedural_guidance`
3. Implement guidance formatting (subgraph → text block)
4. Add `context.procedural_guidance` publish call to Loop.pm context assembly
5. Register PG tools: `pg_show_graph`, `pg_add_node`, `pg_add_edge`, `pg_delete_edge`
6. Write tests: guidance formatting, tool registration, bus round-trip

**Dependencies**: Phase 1, Loop.pm (minimal change), Wit/API (existing).

**Estimated scope**: ~300 lines wit + ~50 lines Loop.pm change + ~200 lines tests.

### Phase 3: Self-Evolution

**Deliverable**: `Clank::ProceduralGraph::Evolver` with the four-step loop.

**Tasks**:
1. Implement `Evolver.pm`: trajectory extraction from event journal
2. Implement refiner prompt construction (current graph + trajectories → mutations)
3. Implement mutation application (add/delete/revise with structural checks)
4. Implement validation gate (run solver on val set, compare scores)
5. Implement rejection memory (log to `pg_rejections`, feed to refiner)
6. Wire evolution trigger into wit (tool or bus event)
7. Write tests: mutation application, structural validation, rejection logging

**Dependencies**: Phase 1, Provider (existing), Store event journal (existing).

**Estimated scope**: ~500 lines Evolver + ~300 lines tests.

### Phase 4: Polish and Integration

**Deliverable**: End-to-end working system with documentation.

**Tasks**:
1. CLI slash commands: `/pg show`, `/pg evolve`, `/pg reset`
2. Graph visualization (text-based, for REPL)
3. Statistics tracking (node/edge counts, evolution metrics)
4. Integration tests: full agent session with PG guidance
5. Documentation: usage guide, API reference, examples
6. Tune localization fuzzy matching based on empirical results

**Dependencies**: All previous phases.

**Estimated scope**: ~200 lines commands + ~200 lines tests + docs.

---

## 8. How Existing Modules Are Reused

| Existing Module | How PG Uses It |
|---|---|
| `Store` | SQLite DB for pg_nodes, pg_edges, pg_evolution_log, pg_rejections |
| `Bus` | pub/sub for context.procedural_guidance, agent_end events |
| `WorldModel` | Independent — PG complements it, doesn't modify it |
| `Crystallizer` | Pattern reference for the evolution pipeline |
| `ContextRules` | Coexists — PG guidance is a separate context block |
| `Logic::Datalog` | Can query PG structure (reachability, cycles) |
| `Rules::FSM` | PG edges can map to FSM transitions |
| `Rules::BehaviorTree` | PG branches can map to BT fallback sequences |
| `Provider` | LLM calls for refiner (evolution) and optionally guidance |
| `ToolSelector` | PG tools are just more tools — RATS selects them naturally |
| `Wit::API` | Standard wit registration interface |

No existing module is modified except Loop.pm (one new bus publish + collect).

---

## 9. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Localization fails (action doesn't match any node) | Fallback to Start node or full graph. Log mismatches for graph improvement. |
| Graph grows unbounded | Cap node count (e.g. 200). Evolution prunes unused nodes. |
| Validation is stochastic (temperature 0 helps but doesn't eliminate variance) | Run validation 3x, take mean. Paper uses single run with greedy — we can match that initially. |
| Refiner proposes degenerate mutations (empty graph, self-loops) | Structural checks: no orphans, no cycles (unless allowed), min node count. |
| Context overhead grows with graph size | 2-hop neighborhood keeps it bounded (~5-10 edges max). Guidance block is ~200-500 tokens. |
| Evolution is expensive (many LLM calls per round) | Batch rounds, not per-task. Track token cost in Metrics. Make evolution opt-in. |

---

## 10. Open Questions

1. **Guidance model**: Paper uses a separate LLM for guidance generation.
   We start with pre-formatted attributes (no extra LLM call). Should we
   add an optional paraphrasing step?

2. **Node matching**: How to handle actions that don't map cleanly to nodes
   (e.g. multi-step tool calls, conditional branches)?

3. **Graph seeding**: Should we provide default "Start" and "End" nodes
   automatically, or let users define them?

4. **Multi-session evolution**: Should the PG persist across sessions and
   accumulate evolution rounds, or reset per session?

5. **Interaction with Crystallizer**: When Crystallizer captures a rule,
   should it also update the PG (add a node for the crystallized behavior)?

---

## Appendix A: Reference — Paper's Algorithm 1

```
Input: Initial graph G_0, training set D_train, validation set D_val, rounds K
Output: Evolved graph G_K

for k = 1 to K:
    1. Diagnostic Rollout:
       Run solver with G_{k-1} on batch B_k ⊂ D_train
       Record traces E_k = {(q_i, T_i, S_i)}

    2. Feedback-Driven Mutation:
       Refiner analyzes E_k (successes vs failures)
       Proposes ΔG_k (add/delete/revise)
       Candidate: G_k^cand = G_{k-1} ⊕ ΔG_k

    3. Validation Gating:
       If S_val(G_k^cand) >= S_val(G_{k-1}):
           G_k = G_k^cand
       Else:
           G_k = G_{k-1}

    4. Rejection Memory:
       If rejected: log to H_rejected
       Refiner sees H_rejected as negative evidence in round k+1
```

## Appendix B: Paper's Three-Field Edge Attributes

| Field | Purpose | Example |
|---|---|---|
| `condition` | When this transition applies | "projected runway falls below safety buffer" |
| `guidance` | How to execute the transition | "submit request early to allow financing delay" |
| `pitfalls` | What to avoid | "do not stack a second request while one is pending" |

All optional. A minimal edge has only `guidance`. A rich edge has all three.
