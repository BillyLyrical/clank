# Neurosymbolic AI in Clam

Status: implemented. This document describes what Clam has built, the theory
behind it, how the pieces fit together, and what we hope to achieve.

## 1. The Thesis

LLMs are brilliant pattern recognizers but terrible at reasoning. Rules engines
are brilliant at reasoning but terrible at understanding natural language. The
neurosymbolic thesis is that combining them yields systems that can both
understand and reason — and that this combination is more than the sum of its
parts.

Clam is not a pure neural system with bolted-on logic. It is not a logic
system with a language model attached. It is an integrated architecture where
neural and symbolic components share a common world model, communicate through
a shared bus, and influence each other's behavior through well-defined hooks.

The core insight: **the world model is the integration point**. Both the LLM
and the rules engine read from and write to the same structured knowledge
base. This creates a feedback loop:

```
LLM generates hypothesis → Rules validate → World Model updates →
LLM constrained by world model → Better output
```

Each pass through the loop makes the system more knowledgeable. The LLM learns
from rule outcomes. Rules adapt from LLM insights. Crystallization captures
solutions as deterministic rules, making the system faster and cheaper over
time.

## 2. What We Built

### 2.1 The World Model (`lib/Clam/WorldModel.pm`)

A structured knowledge base backed by SQLite, with five tables:

| Table | Purpose |
|-------|---------|
| `wm_entities` | Named things with types and attributes |
| `wm_relations` | Typed connections between entities (with temporal validity) |
| `wm_facts` | Temporal truths with confidence and source provenance |
| `wm_causes` | Causal links between entities |
| `wm_beliefs` | Claims with confidence, evidence, and supersession chains |

The world model is not a key-value store. It is a graph with temporal
semantics, confidence propagation, and counterfactual reasoning.

**Key capabilities:**

- **Entity/relation/fact CRUD** — structured knowledge representation
- **Temporal queries** — what was true when, fact history, belief lineage
- **Causal reasoning** — trace causes of effects, predict effects of causes
- **Graph traversal** — BFS walk with distance, shortest path between entities
- **Hybrid search** — BM25 keyword search blended with embedding cosine similarity
- **Counterfactual queries** — "what if X were different?" via SQLite SAVEPOINTs
- **Belief revision** — confidence propagation through dependency graphs
- **FTS5 integration** — full-text search over entities, beliefs, and facts

### 2.2 The Rules Engine (`lib/Clam/Rules/`)

A complete rule evaluation system:

| Component | Capability |
|-----------|------------|
| `Engine` | Forward-chaining with conflict resolution |
| `DSL` | Rule definition language |
| `Rule` | Individual rule objects (pattern, fact, production) |
| `Parser` | Parse rule definitions |
| `FSM` | Finite state machine transitions |
| `BehaviorTree` | Hierarchical task execution |
| `DecisionTree` | Branching decision logic |

The engine supports backward chaining, negation as failure, rule composition,
and incremental re-evaluation when facts change.

### 2.3 The Bidirectional Integration (`lib/Clam/NeuroIntegration.pm`)

Three-phase pipeline that makes the LLM and world model talk to each other:

**Phase 1: LLM reads world model.** Before the LLM generates a response,
relevant world model facts are injected into the context. The LLM sees what
the system already knows.

**Phase 2: Rules validate LLM output.** After the LLM generates, the output
is checked against world model facts. Contradictions are flagged. If the LLM
says "Perl is not a scripting language" but the world model knows it is, the
system catches it.

**Phase 3: LLM updates world model.** After successful conversation, entities
and facts are extracted from the conversation and stored. The world model
grows from every interaction.

All three phases hook into the bus — no changes to Loop.pm required.

### 2.4 Crystallization (`lib/Clam/Crystallizer.pm`)

When the LLM solves a problem, the solution is captured as a deterministic
rule. The system gets cheaper and faster the more it's used.

Pipeline: conversation → pattern extraction (heuristic or LLM) → validate
against world model → register rule in engine. The Crystallizer hooks into
`agent_end` to analyze completed conversations automatically.

### 2.5 Output Constraints (`lib/Clam/Constraints.pm`)

A registry of validation schemas that check LLM output before emission:

| Schema | What it catches |
|--------|----------------|
| `vagueness` | Excessive hedging and imprecision |
| `overclaiming` | Absolute certainty without evidence |
| `wm_contradiction` | Contradicting known world model facts |

Custom constraints are trivial to add — register a name, description,
severity, and validation function. Constraints hook into `message_end` via
the bus.

### 2.6 Goal Planning (`lib/Clam/Logic/GoalPlanner.pm`)

Decomposes goals into subgoals with dependency tracking and relevance scoring.
Uses the world model's belief graph to prioritize: beliefs that are close to a
goal in the dependency graph and have high confidence score highest.

Supports topological execution planning, automatic subgoal completion
detection, and hierarchical goal structures.

### 2.7 Taxonomy (`lib/Clam/Logic/Taxonomy.pm`)

Hierarchical classification for entities, beliefs, and goals. Categories form
trees with inherited properties. Enables category-aware queries across the
world model.

Property inheritance: child categories inherit properties from parents, with
child overrides. Category-aware queries: find all entities/beliefs/goals under
a branch.

### 2.8 Infrastructure Primitives

| Module | Purpose |
|--------|---------|
| `Governor` | Rate limiting, budget caps, circuit breaker for LLM providers |
| `Tracer` | Event-trace log for pipeline observability |
| `Cache` | TTL cache for LLM responses (prevents re-asking the same question) |
| `Metrics` | Simple counters for LLM calls, tokens, rules, crystallizations |
| `EventSourcing` | Immutable state-change log for debugging and replay |

All wired into the agent loop via `App.pm`. Governor wraps provider calls,
Tracer wraps pipeline stages, Cache checks before provider calls, Metrics
counts at key points.

## 3. The Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                         User Input                            │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│              World Model Context Injection                     │
│  Query relevant facts, beliefs, and relations                 │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                    LLM Generation                              │
│  Generate response constrained by world model context         │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                  Constraint Validation                         │
│  Check output against practical schemas and world facts       │
└───────────────────────────┬──────────────────────────────────┘
                            │
                    ┌───────┴───────┐
                    │               │
                    ▼               ▼
              ┌──────────┐    ┌──────────┐
              │  Valid   │    │ Invalid  │
              └────┬─────┘    └────┬─────┘
                   │               │
                   │               ▼
                   │        ┌──────────────┐
                   │        │ LLM Revision │
                   │        │ (with facts) │
                   │        └──────┬───────┘
                   │               │
                   ▼               ▼
┌──────────────────────────────────────────────────────────────┐
│              World Model Update                                │
│  Extract new entities, relations, facts from conversation     │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│              Crystallization                                   │
│  Capture reusable patterns as deterministic rules             │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                   Output to User                               │
└──────────────────────────────────────────────────────────────┘
```

Every arrow is a bus event. No component calls another directly. This means:

- **Any component can be replaced** without touching others
- **Any component can be disabled** at runtime
- **New components can be added** by subscribing to bus events
- **All interactions are journaled** for debugging and replay

## 4. How to Use It

### 4.1 As a Coding Harness

```bash
clam --provider ollama --model codellama
```

The standard coding harness — read files, edit code, run commands. The
neurosymbolic layer runs silently in the background: the world model
accumulates knowledge about your codebase, constraints catch contradictions,
crystallized rules speed up repeated tasks.

### 4.2 As a Reasoning System

```perl
use Clam::App;

my $app = Clam::App->new(provider => 'ollama', model => 'llama3');
$app->start_session;

# The world model is automatically available.
# Add knowledge:
my $wm = $app->{world_model};
$wm->add_entity(id => 'perl', type => 'language', name => 'Perl');
$wm->assert_fact(entity_id => 'perl', predicate => 'is', value => 'a scripting language');
$wm->believe(statement => 'Perl is good for text processing', confidence => 0.9);

# Query it:
my $facts = $wm->query_facts(entity_id => 'perl');
my $beliefs = $wm->query_beliefs(min_confidence => 0.7);

# Use goal planning:
my $gp = Clam::Logic::GoalPlanner->new(world_model => $wm);
my $goal_id = $gp->set_goal(statement => 'Learn Perl', priority => 1);
$gp->add_subgoal(goal_id => $goal_id, statement => 'Read perldoc');
$gp->add_subgoal(goal_id => $goal_id, statement => 'Write a script', depends_on => [$subgoal_id]);
my $plan = $gp->plan($goal_id);
```

### 4.3 As a Knowledge Base

The world model persists across sessions. Build up knowledge over time:

```perl
# Knowledge accumulates in SQLite
$wm->add_entity(id => 'project_x', type => 'project', name => 'Project X',
    attributes => { language => 'Perl', status => 'active' });
$wm->add_relation(source_id => 'perl', target_id => 'project_x', type => 'used_by');

# Crystallized rules persist — repeated questions get faster
# Constraints persist — output quality improves over time
```

### 4.4 Extending with Custom Constraints

```perl
use Clam::Constraints;

my $c = Clam::Constraints->new(world_model => $wm);
$c->add_constraint(
    name     => 'no_jargon',
    desc     => 'Avoid technical jargon for non-technical users',
    severity => 'warn',
    fn       => sub {
        my ($output, $context) = @_;
        my @v;
        push @v, 'Contains jargon' if $output =~ /\b(?:monad|functor|kleisli)\b/i;
        return @v;
    },
);
```

### 4.5 Counterfactual Reasoning

```perl
# What would happen if Perl were compiled instead of interpreted?
my $result = $wm->counterfactual(
    scenario => [
        { op => 'retract_fact', fact_id => $original_fact_id },
        { op => 'assert_fact', entity_id => 'perl', predicate => 'type', value => 'compiled language' },
    ],
    query => sub {
        my ($wm) = @_;
        return $wm->query_facts(entity_id => 'perl');
    },
);
# The world model is unchanged after the call.
```

## 5. What We Hope to Achieve

### 5.1 The System Gets Smarter Over Time

Every interaction feeds the world model. Every crystallized rule reduces future
LLM calls. Every validated output improves quality. The system is designed to
be measurably better after a month of use than on day one.

### 5.2 Explainable Reasoning

Every conclusion has a traceable path through world model facts and rules.
When the system makes a recommendation, you can trace: which facts led to
which beliefs, which rules fired, which crystallized rules contributed.
No black boxes.

### 5.3 Cost Reduction Through Crystallization

The LLM is expensive. Deterministic rules are cheap. When the LLM solves a
problem once, crystallization captures the solution as a rule. Next time, the
rule fires instantly without LLM involvement. Over time, the fraction of
queries handled by rules grows, and the fraction requiring LLM calls shrinks.

### 5.4 Safe Autonomy Through Constraints

The constraint system provides guardrails. Output is validated before
emission. World model contradictions are caught. Overclaiming is flagged.
This makes the system safe to use in contexts where unchecked LLM output
would be dangerous.

### 5.5 Goal-Directed Behavior

The goal planner enables multi-step reasoning. Set a goal, and the system
decomposes it into subgoals, scores them by relevance to known beliefs,
executes them in dependency order, and tracks completion. This is the
foundation for autonomous task execution.

### 5.6 The Perl Advantage

This entire system is Perl. No Python runtime. No TypeScript transpiler. No
Docker containers. SQLite and CPAN — the two things that have been reliable
in production for decades. The neurosymbolic infrastructure runs in the same
process as the LLM harness, with the same database, on the same machine.

For experienced Perl developers, this means: the system is inspectable,
modifiable, and hackable with the tools you already know. Every component
is a Perl module with tests. Every bus event is a SQLite row you can query.
Every rule is a Perl expression you can debug.

## 6. Implementation Status

### Completed

| Phase | Component | Status |
|-------|-----------|--------|
| World Model | Schema, CRUD, Store integration | ✅ |
| World Model | Hybrid search (BM25 + embeddings) | ✅ |
| World Model | Graph traversal, shortest path | ✅ |
| World Model | Temporal queries, fact/belief history | ✅ |
| Bidirectional | Context injection into LLM | ✅ |
| Bidirectional | Rule validation after LLM output | ✅ |
| Bidirectional | Knowledge extraction from conversation | ✅ |
| Crystallization | Pattern extraction, rule storage | ✅ |
| Constraints | Practical validation schemas | ✅ |
| Advanced Reasoning | Causal reasoning, trace causes | ✅ |
| Advanced Reasoning | Counterfactual queries | ✅ |
| Advanced Reasoning | Belief revision with confidence propagation | ✅ |
| Goal Planning | Decomposition, relevance scoring | ✅ |
| Taxonomy | Hierarchical classification, inheritance | ✅ |
| Infrastructure | Governor, Tracer, Cache, Metrics | ✅ |
| Infrastructure | Event sourcing, replay | ✅ |
| Integration | All primitives wired into App.pm | ✅ |

### Test Coverage

705 tests across 28 test files. All passing.

### Module Count

- Core modules: 32 (lib/Clam/)
- Logic modules: 7 (lib/Clam/Logic/)
- Rules modules: 7 (lib/Clam/Rules/)
- Provider modules: 8 (lib/Clam/Provider/)
- Wit decks: 10 (wits/)

## 7. What Comes Next

### Real-World Testing

The infrastructure is built. The next step is running it against real coding
tasks, real knowledge bases, and real reasoning challenges. Measuring:

- How much does crystallization reduce LLM calls over time?
- How accurate is the world model after a week of use?
- How many contradictions does the constraint system catch?
- How useful is goal planning for multi-step coding tasks?

### Advanced Reasoning Extensions

- **Counterfactual chains** — multi-step "what if" reasoning
- **Belief propagation at scale** — confidence cascading through large graphs
- **Temporal reasoning** — "what was true before X changed?"
- **Constraint-aware revision** — LLM automatically revises when constraints fail

## 8. References

- Marcus, G. (2020). *The Next Decade in AI: Four Steps Towards Robust Artificial Intelligence*
- Minsky, M. (1986). *The Society of Mind*
- Garcez, A. d'A., et al. (2019). *Neural-Symbolic Computing: An Effective Methodology for Principled Integration of Machine Learning and Reasoning*
- Hamilton, W. L. (2020). *Logical Entailment and Neural-Symbolic AI*
- Lake, B. M., et al. (2017). *Building machines that learn and think like people*
- Clark, A. (2013). *Whatever Next? Predictive Brains, Situated Agents, and the Future of Cognitive Science*
