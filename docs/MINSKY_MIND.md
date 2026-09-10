# The Minsky Mind

Status: implemented. What's built, what works, and what remains.

---

## 1. The Vision

The Minsky vision: intelligence emerges from many simple, specialized
agents communicating via shared memory. No agent is smart. The society is.

Phase 4 was the transition from "coding harness with logic engines" to
"execution environment where intelligence emerges from composition."

**That transition is complete.** Clank now has:
- Agents (143 wits across 15 decks, each does one thing)
- Shared memory (SQLite world model: entities, relations, facts, beliefs)
- Communication (bus pub/sub + cross-session mesh)
- Reasoning (rules engine: Datalog, FSM, behavior trees, SAT)
- Learning (crystallizer: LLM solutions → deterministic rules)
- Integration (NeuroIntegration: LLM ↔ world model bidirectional)
- Composition (Bands: composable societies of wits)
- Escalation (cheapest correct tool first)
- Execution (PerlEnv + PerlLoop: full neurosymbolic loop)

---

## 2. What's Implemented

### 2.1 Computational Escalation

`Clank::Escalation` — try the cheapest correct tool first.

```
Prompt arrives
    │
    ▼
1. Crystallized rules match?     ~1ms, $0.00
   Yes → return rule result
   No ↓
2. World model has answer?       ~5ms, $0.00
   Yes → return fact
   No ↓
3. Rules engine can derive?      ~10ms, $0.00
   Yes → return derived fact
   No ↓
4. Call LLM (normal path)        ~500ms, $0.01
   Crystallize result for next time
```

**Module:** `lib/Clank/Escalation.pm`
**Tests:** `t/42_escalation.t` (21 tests)
**Status:** ✅ Complete

### 2.2 Composable Societies (Bands)

`Clank::Band` — wits chain into workflows via bus events. No wit knows
about any other — they only know topics.

```
Band code-review:
  Step critic:   wit(critic)   topic(git.diff.ready)   → critic.output
  Step fixer:    wit(repair)    topic(critic.output)     → fixer.output
```

**Module:** `lib/Clank/Band.pm`
**Tests:** `t/43_bands.t` (27 tests)
**Bands:** `bands/code-review/`, `bands/log-event/`
**Status:** ✅ Complete

### 2.3 Cross-Session Communication

`Clank::Mesh` — send/broadcast/subscribe/query across sessions via SQLite.

```perl
$mesh->send(target => 'session-B', payload => { ... });
$mesh->broadcast(payload => { ... });
$mesh->subscribe(topic => 'mesh.*');
my @msgs = $mesh->query_messages(topic => 'mesh.*');
```

**Module:** `lib/Clank/Mesh.pm`
**Tests:** `t/44_mesh.t` (15 tests)
**Status:** ✅ Complete

### 2.4 Self-Improvement Metrics

`Metrics::self_stats()` + `/stats` REPL command — measure whether
crystallized rules are being used and whether they're correct.

Tracks:
- `automation_ratio` — rule hits / (rule hits + LLM fallbacks)
- `crystallized_rules` — total crystallized rules
- `wm_facts` — world model facts
- `wm_entities` — world model entities
- `total_events` — bus events processed

**Module:** `lib/Clank/Metrics.pm` (self_stats method)
**Bus handler:** `metrics.self_stats`
**REPL:** `/stats` command
**Tests:** `t/45_self_stats.t` (21 tests)
**Status:** ✅ Complete

### 2.5 Perl Execution Environment

`Clank::PerlEnv` — sandbox execution, fact extraction, world model update.

```perl
my $env = Clank::PerlEnv->new(store => $store);
my $r = $env->execute(code => 'my $x = 42;');
# $r = { ok => 1, output => "...", facts => [...] }
```

`Clank::PerlLoop` — agent loop connecting LLM to PerlEnv.

```
LLM generates code → sandbox executes → world model updates →
rules fire → LLM sees results → better code next time
```

**Modules:** `lib/Clank/PerlEnv.pm`, `lib/Clank/PerlLoop.pm`
**Tests:** `t/46_perlenv.t` (22 tests), `t/47_perlloop.t` (21 tests)
**Status:** ✅ Complete

---

## 3. What Remains

The core Phase 4 features are built. These are the next horizons:

### 3.1 SQLite as OS Kernel (aspirational)

The ROADMAP mentions "SQLite as the operating system kernel" — call stack,
process queue, instruction memory, IPC. This is aspirational, not literal.

**What we have:**
- SQLite stores sessions, messages, events, facts, beliefs, rules
- Bus journals events to SQLite before dispatch
- World model uses SQLite FTS5 for search
- Crystallizer stores rules in SQLite

**What we don't have (and may not need):**
- Process scheduling (bus handles dispatch)
- Instruction memory (wits are loaded, not interpreted)
- Inter-process IPC (clankd handles multi-session coordination)

**Assessment:** The "OS kernel" metaphor was useful for design but
doesn't need literal implementation. SQLite is the shared memory layer,
not a general-purpose OS. The current architecture is cleaner.

### 3.2 Persistent Societies (aspirational)

Bands are currently defined per-deck. A persistent society would:
- Survive restart (persisted to SQLite)
- Evolve through use (add/remove steps dynamically)
- Have a lifecycle (create → activate → evolve → retire)

**Assessment:** Useful but low priority. Current Bands are sufficient
for the coding workflow. Dynamic societies would matter for autonomous
agents — a future concern.

### 3.3 Self-Improvement Feedback Loops (aspirational)

The crystallizer captures solutions, but there's no loop that:
- Tests crystallized rules against new inputs
- Retires rules that produce incorrect results
- Refines rules based on usage patterns

**Assessment:** The `use_count` and `last_used` tracking exists.
A feedback loop would be valuable for long-running deployments.
Not urgent for the current single-user harness.

### 3.4 Multi-Agent Reasoning (aspirational)

The current architecture supports one LLM call at a time. Multi-agent
reasoning would involve:
- Parallel LLM calls (different models, different perspectives)
- Debate between agents (critic vs. builder)
- Consensus mechanisms (voting on solutions)

**Assessment:** Subagents exist (fork Loop for parallel work). True
multi-agent reasoning requires a coordination layer that doesn't
exist yet. This is a future direction.

---

## 4. Architecture Summary

```
┌─────────────────────────────────────────────────────┐
│              User / CLI / Daemon                     │
└──────────────────┬──────────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────────┐
│              Clank::App                              │
│  ┌─────────┐  ┌─────────┐  ┌────────────────────┐  │
│  │  Store  │  │   Bus   │  │  Escalation         │  │
│  │ (SQLite)│◄─┤(pub/sub)│  │  (cheapest first)   │  │
│  └─────────┘  └────┬────┘  └────────────────────┘  │
│                    │                                │
│  ┌─────────────────▼─────────────────────────────┐  │
│  │         Clank::Loop (Pi port)                  │  │
│  │  prompt → escalate → tools → LLM → ...        │  │
│  └─────────────────┬─────────────────────────────┘  │
│                    │                                │
│  ┌─────────────────▼─────────────────────────────┐  │
│  │          PerlLoop (neurosymbolic loop)         │  │
│  │  LLM → PerlEnv → world model → rules → LLM   │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │          Wits (143 modules)                  │    │
│  │  tools + commands + bus hooks + bands        │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

---

## 5. Test Coverage

| Feature | Tests | Status |
|---------|-------|--------|
| Escalation | 21 | ✅ All passing |
| Bands | 27 | ✅ All passing |
| Mesh | 15 | ✅ All passing |
| Self-stats | 21 | ✅ All passing |
| PerlEnv | 22 | ✅ All passing |
| PerlLoop | 21 | ✅ All passing |
| Integration | 38 | ✅ All passing |
| **Total** | **165** | **All passing** |

997 core tests + 430 wit tests = 1427 total tests, all offline.

---

## 6. References

- `docs/ROADMAP.md` — project roadmap and phase definitions
- `docs/CONTEXT.md` — five-pipeline context engineering system
- `docs/NExT_migration.md` — NExT format migration plan
- `lib/Clank/Escalation.pm` — computational escalation
- `lib/Clank/Band.pm` — composable societies of wits
- `lib/Clank/Mesh.pm` — cross-session communication
- `lib/Clank/PerlEnv.pm` — Perl execution environment
- `lib/Clank/PerlLoop.pm` — neurosymbolic agent loop
- `lib/Clank/Metrics.pm` — self-improvement metrics
