# The Minsky Mind — Phase 4 Architecture

Status: design. What Phase 4 means, what's tractable, and the path from
harness to execution environment.

---

## 1. What Phase 4 Is

Phase 4 is not a feature. It is the transition from "coding harness that
happens to have logic engines" to "execution environment where intelligence
emerges from the composition of simple agents."

The Minsky vision: intelligence is not a single algorithm. It is a society
of many simple, specialized agents — each doing one thing well —
communicating through shared memory. No agent is smart. The society is.

Clank already has the pieces:
- **Agents**: wits (125 of them, each does one thing)
- **Shared memory**: SQLite world model (entities, relations, facts, beliefs)
- **Communication**: bus (pub/sub over SQLite, journaled events)
- **Reasoning**: rules engine (forward/backward chaining, FSM, behavior trees)
- **Learning**: crystallizer (LLM solutions → deterministic rules)
- **Integration**: NeuroIntegration (LLM ↔ world model bidirectional)

Phase 4 makes these pieces compose. The question is not "what do we build?"
It is "what makes the existing pieces talk to each other in useful ways?"

---

## 2. The Five Phase 4 Features

### 2.1 Computational Escalation

**The idea:** Before calling the LLM (expensive, probabilistic), try
cheaper alternatives (free, deterministic). Escalate only when needed.

```
User asks: "What is the default PostgreSQL port?"

Path A (LLM):    → provider call → $0.01, 500ms, might hallucinate
Path B (Rules):  → crystallized rule → $0.00, 1ms, correct if crystallized
Path C (Datalog): → fact query → $0.00, 5ms, correct if asserted
Path D (WM):     → world model search → $0.00, 10ms, correct if populated
```

The optimal path is D → C → B → A. Try the cheapest correct tool first.

**Current state:** The pieces exist but aren't wired into a decision pipeline:
- Crystallizer has rules in `crystallized_rules` table
- World model has facts in `wm_facts` table
- Rules engine can match patterns and query facts
- But Loop.pm always calls the LLM — no escalation layer

**Design:**

```
Prompt arrives
    │
    ▼
┌─────────────────────────────────┐
│ 1. Crystallized rules match?    │  cheapest: regex match on stored rules
│    Yes → return rule result     │  cost: ~1ms
│    No ↓                        │
├─────────────────────────────────┤
│ 2. World model has answer?      │  FTS5 search over facts/entities
│    Yes → return fact            │  cost: ~5ms
│    No ↓                        │
├─────────────────────────────────┤
│ 3. Rules engine can derive?     │  forward/backward chaining
│    Yes → return derived fact    │  cost: ~10ms
│    No ↓                        │
├─────────────────────────────────┤
│ 4. Call LLM (normal path)       │  expensive: ~$0.01, 500ms
│    Crystallize result for next  │
└─────────────────────────────────┘
```

**Where it lives:** A new `Clank::Escalation` module, or a bus hook on
`context` that short-circuits the provider call. The bus makes this clean:
subscribe to `before_provider_request`, check escalation paths, return
a result if any path succeeds (preventing the LLM call).

**Key insight:** This is not a replacement for the LLM. It is a fast path
for questions the system has already answered. The LLM is the fallback for
novel questions. Crystallization captures those answers for next time.

### 2.2 Composable Societies

**The idea:** Wits chain into workflows via bus events. No wit knows about
any other — they only know topics. A git commit triggers a critic analysis,
which triggers a guardrails check, which triggers a world model update.

**Current state:** Wit::Dispatch supports inter-wit calls. Bus supports
pub/sub with glob patterns. But no concrete workflow chains exist.

**Design:**

A "society" is a set of wits that compose via bus topics:

```
git_commit wit publishes:  git.commit.done
    │
    ├──→ critic wit subscribes: runs code critique
    │    publishes: critic.analysis.done
    │
    ├──→ guardrails wit subscribes: checks for dangerous patterns
    │    publishes: guardrails.check.done
    │
    └──→ world_model wit subscribes: extracts entities from diff
         publishes: wm.update.done
```

No wit imports or calls any other. They communicate through the bus.
The society emerges from the topic subscriptions.

**What to build:** A concrete example wit that demonstrates the pattern.
The existing critic wit already subscribes to `message_end`. Wire it into
a git workflow: git commit → critic analysis → world model update.

### 2.3 Cross-Session Communication

**The idea:** Session A publishes an event. Session B (running in a
different process, or later in time) sees it. The SQLite store is the
shared medium.

**Current state:** Bus is in-process. Events are journaled to SQLite.
But there's no mechanism for another session to subscribe to events
from a different session.

**Design:**

Two approaches:

**Approach A: Shared topics.** Both sessions subscribe to a global topic
(e.g., `session.*.done`). When Session A completes, it publishes
`session.A.done` with results. Session B, which subscribed to
`session.*.done`, receives it. This works because the bus dispatches
in-process, and the journal is the durable record.

Problem: sessions run in separate processes. In-process subscriptions
don't see each other's events.

**Approach B: Store as message bus.** Add a `session_messages` table.
Session A writes a message. Session B polls or is notified via a trigger.
This is the "shared blackboard" pattern — Minsky's original vision.

**Approach C: clankd as coordinator.** The daemon runs multiple sessions.
All sessions share the same in-process bus. Cross-session communication
is just bus pub/sub within the daemon.

Approach C is the simplest and most natural. clankd already manages
multiple sessions. Add a `session.send` command to the NDJSON protocol:
`{"command":"send","to_session":"B","payload":{...}}`.

### 2.4 Self-Improvement Metrics

**The idea:** Measure whether crystallized rules are actually being used
and whether they produce correct results. Track the ratio of LLM calls
to rule hits over time. The system should get measurably cheaper.

**Current state:** Crystallizer has `use_count` and `last_used` on rules.
Metrics module has counters. But no dashboard or analysis tooling.

**Design:**

Track in the metrics table:
- `escalation.rule_hit` — crystallized rule answered without LLM
- `escalation.wm_hit` — world model answered without LLM
- `escalation.rule_derived` — rules engine derived answer
- `escalation.llm_fallback` — LLM was called (novel question)
- `escalation.crystallized` — LLM result was crystallized for next time

The ratio `rule_hit / (rule_hit + llm_fallback)` is the "automation ratio".
Over time, as more conversations are crystallized, this ratio should climb.

**What to build:** A `/stats` REPL command that shows escalation metrics.
Or a bus event `metrics.request` that returns the current ratios.

### 2.5 The Perl Execution Environment

**The idea:** Clank is not just a coding tool — it is a Perl shell where
LLMs, logic engines, and user code collaborate on the blackboard.

**Current state:** psh_eval runs Perl in-process. psh_sandbox runs it in
a subprocess. The world model stores facts. The rules engine reasons.
But they don't compose — there's no " Perl environment" experience.

**Design:**

The Perl execution environment is the long-term vision where:
- The LLM writes Perl code
- Code executes in a sandbox (psh_sandbox)
- Results update the world model (facts, entities)
- Rules fire on new facts (forward chaining)
- Crystallization captures solutions
- The system evolves through use

This is the full neurosymbolic loop:
```
LLM generates code → sandbox executes → world model updates →
rules fire → LLM sees results → better code next time
```

---

## 3. Implementation Order

Phase 4 is not a single release. It is a direction. The features build
on each other:

```
Phase 4.1: Computational Escalation
    │         (cheapest correct tool first)
    │
    ├──→ Phase 4.2: Self-Improvement Metrics
    │         (measure escalation effectiveness)
    │
    ├──→ Phase 4.3: Composable Societies
    │         (wits chain via bus events)
    │
    ├──→ Phase 4.4: Cross-Session Communication
    │         (clankd as session coordinator)
    │
    └──→ Phase 4.5: Perl Execution Environment
              (full neurosymbolic loop)
```

**Start with 4.1 (Escalation).** It is the highest-value feature:
- Makes the system cheaper immediately
- Uses existing infrastructure (Crystallizer, WorldModel, Rules engine)
- The bus makes it pluggable (subscribe to `before_provider_request`)
- Measurable impact (escalation metrics prove value)

---

## 4. What NOT to Build

- **Don't build an OS kernel.** SQLite is the shared memory, not an OS.
  The "operating system kernel" metaphor from the ROADMAP is aspirational,
  not literal. Don't implement process scheduling or instruction memory.

- **Don't build 300 agent types.** The old clank had Jungian archetypes,
  Kierkegaardian agents, Machiavellian politics. These were philosophical
  explorations, not engineering. Keep wits simple and composable.

- **Don't over-orchestrate.** The bus is the orchestrator. Don't build
  a central coordinator that knows about all wits. Let wits discover
  each other through topic subscriptions.

- **Don't promise sentience.** The system learns from use (crystallization),
  reasons over facts (rules engine), and integrates neural + symbolic
  components (NeuroIntegration). It is not conscious. It is useful.

---

## 5. Open Questions

1. **Escalation scope:** Should escalation apply to all LLM calls, or only
   to "knowledge" questions? Some calls need the LLM's generative capability
   (writing code, explaining concepts) — escalation would always fail.

2. **Society definition:** How does a user define a society of wits? Is it
   a config file? A set of bus subscriptions? A wit that wires other wits?

3. **Cross-session state:** When two sessions share the world model, how do
   they handle conflicting updates? Last-write-wins? Causal ordering?

4. **Metrics storage:** Should escalation metrics live in the existing metrics
   table, or in a separate analytics table with time-series support?

5. **Crystallization quality:** How do we know a crystallized rule is correct?
   Should we test it against the world model before promoting it?
