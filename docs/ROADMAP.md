# Clank v2 — Roadmap

> A Perl AI coding harness for experienced unix-perl greybeards.
> Simple core, Minsky blackboard, curated Wits ecosystem.

---

## 1. What Clank Is

Clank is a complete Perl environment for AI-assisted development and reasoning. It is:

- **An AI harness** — agent loop, tools, LLM providers, session management (ported from Pi)
- **A blackboard system** — Minsky's Society of Mind via SQLite pub/sub bus
- **A logic engine suite** — Datalog, rules DSL, FSM, behavior trees, SAT solving
- **A plugin ecosystem** — curated Wits (tools, commands, bus hooks) with CPAN discipline
- **A unix tool** — CLI REPL, NDJSON daemon, programmatic driver, zero mandatory deps beyond SQLite

The MVP is a coding harness. The vision is a complete neuro-symbolic execution environment — a Perl shell where LLMs, logic engines, and user code collaborate on the blackboard. We build the harness first because it's useful today; we keep the architecture clean so the Minsky Mind remains reachable.

### What This Is Not

- Not an "operating system for AI agents" (what clank-old became)
- Not a free-for-all plugin marketplace (the Tower of Babel problem)
- Not a Python/TypeScript harness with Perl bolted on — Perl is the foundation

---

## 2. Architecture

Three layers. Nothing calls anything else directly — everything goes through the bus.

```
┌─────────────────────────────────────────────┐
│              User / CLI / Daemon             │
│         (bin/clank, bin/clankd)                │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│              Clank::App                       │
│  ┌─────────┐  ┌─────────┐  ┌────────────┐  │
│  │  Store  │  │   Bus   │  │  Provider   │  │
│  │ (SQLite)│◄─┤(pub/sub)│  │ (LLM HTTP)  │  │
│  └─────────┘  └────┬────┘  └────────────┘  │
│                     │                        │
│  ┌──────────────────▼─────────────────────┐  │
│  │         Clank::Loop (Pi port)           │  │
│  │  prompt → tools → LLM → tools → ...   │  │
│  └──────────────────┬─────────────────────┘  │
│                     │                        │
│  ┌──────────────────▼─────────────────────┐  │
│  │          Wits (plugins)                 │  │
│  │  tools + commands + bus hooks           │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

**The Store** is the single source of truth. Sessions, messages (tree), events (journal), KV, facts, RAG+FTS5 — all in one SQLite database. State must be derivable from the journal.

**The Bus** is the spine. Everything communicates via topics. No direct calls. Events are journaled first, so crashes can be inspected and resumed.

Bus message protocol (one row per event in the `events` table):

| Column | Type | Purpose |
|--------|------|---------|
| `id` | TEXT PK | UUID |
| `correlation_id` | TEXT | Parent task/event chain |
| `topic` | TEXT | e.g. `tool.call.bash`, `agent.turn_end` |
| `sender` | TEXT | `"loop"`, `"wit:datalog"`, `"user"`, etc. |
| `payload` | TEXT | JSON |
| `created_at` | INTEGER | Unix ms |

In-process dispatch is synchronous; every event is journaled to SQLite first. Bus supports request/reply: publish `task.<name>` with `correlation_id`, wait for `result.<name>` on same correlation. Topic globs: `.` separates segments, `*` matches within one segment.

**The Loop** is Pi's agent loop ported to Perl. Prompt → stream → tool calls → results → repeat. Boring and reliable.

Agent loop events (emitted during each turn):

```
input → before_agent_start → agent_start →
  turn_start → context →
    stream assistant (message_update deltas) →
    tool_call → execute → tool_result →
  turn_end →
agent_end → agent_settled
```

Wits may: transform/block input, replace system prompt, rewrite messages[], block/mutate tool args, replace tool results. A throwing handler is caught, logged, and skipped — one broken wit never kills the loop.

**The Wits** are the extension surface. They register tools the LLM can call, REPL slash commands, and event hooks on the bus.

---

## 3. The Wisdom of Clank v1 (What to Keep)

Clank v1 (clank-old) was 68 modules, 654 wits, 77 decks. Most of it was feature creep. But the intellectual core was sound:

### 3.1 The Minsky Vision (from minsky.txt)

The Society of Mind architecture: intelligence emerges from many simple, specialized agents communicating via message passing. The key architectural ideas worth keeping:

- **Modular agents with typed I/O contracts** — each wit does one thing
- **Shared working memory** (the blackboard/SQLite store) — all agents read/write facts
- **Inhibition/safety layers** — some agents veto others (guardrails, rate limits)
- **Feedback loops via critic agents** — LLM proposes, logic disposes
- **Composable societies** — wits that combine into larger capabilities

What NOT to keep: the 300+ philosophical agent types (Jungian archetypes, Kierkegaardian agents, Machiavellian politics, Stoic philosophy, Confucianism, 36 Stratagems). These were intellectual explorations, not coding harness features.

### 3.2 The Logic Engines

Clank v1 had six reasoning systems. Clank v2 correctly distilled these into two:

| Engine | Purpose | Status |
|--------|---------|--------|
| **Clank::Logic** (Datalog) | What follows necessarily — formal reasoning | ✅ In logic deck |
| **Clank::Rules** (heuristic) | What matches, and how confidently | ✅ In logic deck |
| **Clank::Rules::FSM** | State-dependent behavior | ✅ In logic deck |
| **Clank::Rules::BehaviorTree** | Prioritized fallback decisions | ✅ In logic deck |
| **Clank::Rules::DecisionTree** | Rule chains with branching | ✅ In logic deck |
| **SAT (picosat)** | Constraint satisfaction | ✅ In logic deck |

Division of labor: Logic answers "what follows necessarily." Rules answers "what matches." They compose at the wit layer.

### 3.3 The Bus-First Design

Everything talks through topics, never direct calls. This is what makes wits composable. A git wit publishes `git.commit.done`; a critic wit subscribes and runs analysis; a guardrails wit subscribes and blocks dangerous pushes. No wit knows about any other — they only know topics.

### 3.4 The Unix Layering

Wits are CPAN modules. Distribution via `cpanm`, discovery via `grep`, isolation via
`eval`. One system, one source of truth. cpan/cpanm/perlbrew — user's choice, zero
extra work for us.

---

## 4. The Wisdom of Others (External Validation)

### 4.1 The Harness Playbook (Can Bölük, omp²)

Key lessons that validate Clank's architecture:

1. **Single authoritative state.** "If authoritative state cannot be derived from the journal, rewind, fork, and resume are lies." Clank's SQLite Store IS this — events table is the journal, everything derives from it.

2. **Extension state must not escape the journal.** Of 17 stateful Pi extensions, only 2 were correct. Module-level closures become second sources of truth. Clank's curated wits + Bus hooks over SQLite solve this by making wit state live in the Store, not in Perl closures.

3. **The Director pattern.** Multi-turn behaviors (plan, goal, force-tool) need a stack of controllers that own the yield decision. Clank's Bus + wit hooks can implement this.

4. **Complexity conservation.** "Unavoidable complexity needs an owner." Clank v1 spread it across 68 modules. Clank v2 pushes it into the core (Loop, Store, Bus) and keeps wits thin.

### 4.2 Prime Agent (PrimeIntellect)

Python harness built on Pi. Validates the "harness as programming language" thesis. Key features it has that Clank should consider:

- Subagents built in (rlm() spawns child agents)
- Daemon-backed sessions (background agents survive terminal disconnect)
- Persistent goals and heartbeats
- Automatic compaction

Clank already has Driver/clankd for programmatic sessions. Background persistence was the last gap — now solved with clankd --daemon.

### 4.3 DeepSeek Harness / Cordis

DeepSeek's answer to "random plugins don't play nice": complex dependency injection with fibers, revertible effects, HMR, two planes (host composition + agent preset). It's engineering for a chaotic plugin ecosystem.

**Clank's answer is simpler: curate the plugins.** If you vet what enters the ecosystem, you don't need Cordis's complexity. The trust boundary IS the deck. Curated wits share hooks and data freely because they're vetted. Local/unvetted wits are second-class citizens.

### 4.4 The Tower of Babel (stencil.so)

The core insight: AI harnesses that encourage MANY user plugin ecosystems become fragmented, incompatible, and provide a large attack surface. This is exactly what happened to clank v1 (654 wits across 77 decks, 5 overlapping extension mechanisms). The curated approach is the correct response.

---

## 5. The Wit System

### 5.1 What a Wit Is

A wit is a CPAN module that extends the clank harness: tools the LLM can call,
REPL slash commands, and event hooks on the bus.

**One system, one source of truth: wits are CPAN modules.**

| Concern | Mechanism | Custom code? |
|---------|-----------|-------------|
| Distribution | `cpanm Clank::Wits::Foo` | No |
| Discovery | `grep -r "# CLANK-WIT:" @INC/Clank/Wits/` | No |
| Metadata | `# CLANK-WIT:` comment in module file | No |
| Dependencies | `META.json` + cpanm | No |
| Runtime state | SQLite DB (loaded, enabled) | Yes (exists) |
| Loading | `require` + `register($api)` | Yes (exists) |
| Isolation | `eval { require ... }` | Yes (exists) |

### 5.2 The `# CLANK-WIT:` Comment Format

Every wit module has a `# CLANK-WIT:` comment block near the top. This is the
single source of truth for discovery metadata — grep finds it without loading
the module.

```perl
# CLANK-WIT: name=Foo
# CLANK-WIT: version=1.0
# CLANK-WIT: about=Blocks dangerous git commands before they run
# CLANK-WIT: usage=Load in any repo you trust the model with
# CLANK-WIT: hint=Git safety: vetoes rm, reset --hard, push -f, force
# CLANK-WIT: author=you
# CLANK-WIT: license=Artistic-2.0
package Clank::Wits::Foo;
use strict;
use warnings;

sub register {
    my ($self, $api) = @_;
    # ... register tools, commands, bus listeners ...
}

1;
```

Fields: `name` (optional, defaults from package), `version` (optional),
`about` (required), `usage` (optional), `hint` (required — dense keywords
for LLM tool selection), `author` (optional), `license` (optional).

The `hint` field is essential: when the LLM sees available tools, it needs
a concise, keyword-rich description to decide which to use. Example:
"Git safety: vetoes rm, reset --hard, push -f, force." No grammar, no
sentences — just keywords the LLM can match against.

After the first grep scan, metadata is cached in the SQLite DB. The DB is
the runtime view; the `# CLANK-WIT:` comment is the source of truth.

### 5.3 Registration: `register($api)`

The comment is for discovery. The `register($api)` function is for runtime
integration. After `require`, the PluginManager calls `$wit->register($api)`.

The wit registers:
- **Tools** the LLM can call: `$api->register_tool(name, description, execute)`
- **Commands** for the REPL: `$api->register_command(name, description, handler)`
- **Bus listeners**: `$api->on(topic, handler)`
- **Help text**: `$api->help(text)`

### 5.4 Discovery and Loading

**Production** (installed via cpanm):
1. Scan: `grep -r "# CLANK-WIT:" @INC/Clank/Wits/`
2. Cache: Store metadata in SQLite DB
3. Select: Query DB to decide which wits to load
4. Load: `require Clank::Wits::Foo` (Perl finds it in `@INC`)
5. Register: Call `$wit->register($api)`

**Development** (in-tree wits):
1. Scan: `grep -r "# CLANK-WIT:" wits/*/lib/Clank/Wits/`
2. Select: Same as production
3. Load: Add each wit's `lib/` to `@INC`, then `require`
4. Register: Same as production

Same loader, same code. Just different `@INC` setup.

eval around `require` + `register`. A broken wit warns and skips. The harness
always runs (705 tests, all passing).

### 5.5 Lifecycle

```
LOADED → ACTIVE ⇄ DISABLED
```

- **ACTIVE**: registered tools callable by the LLM, commands in the REPL, hooks on the bus.
- **DISABLED**: all registrations reverted; module still compiled in memory; re-enable is instant.

Revertible effects (borrowed from Cordis, simplified): every registration tracks
its reverse. Disable reverts all effects. Module wits can't truly unload without
restart — honest Unix answer: disable + restart clankd.

### 5.6 Distribution Model

**Core dist: `Clank`** — the minimum viable harness.

```
Clank/
  lib/Clank.pm
  lib/Clank/App.pm
  lib/Clank/Loop.pm
  lib/Clank/Bus.pm
  lib/Clank/Store.pm
  lib/Clank/Provider/*.pm
  lib/Clank/Tool.pm
  lib/Clank/Tools/*.pm
  lib/Clank/Wit/API.pm
  lib/Clank/Wit/Session.pm
  bin/clank
  bin/clankd
  META.json
```

`cpanm Clank` installs the core. Session wit is included (part of the harness).
All other wits are separate dists.

**Wit dists: `Clank-Wits-Foo`** — one per wit (or one per related group).

```
Clank-Wits-Foo/
  lib/Clank/Wits/Foo.pm
  lib/Clank/Wits/Foo/Helper.pm
  META.json
  t/
```

`cpanm Clank-Wits-Foo` installs the wit. `META.json` declares
`requires => { Clank => '1.0' }`.

After installation, everything lands in one `@INC` tree. One tree, one grep,
all wits found. In the git repo, wits live in `wits/` as separate dist
directories — a staging area for development, not shipped in the core dist.

### 5.7 What Goes Away

| Old Mechanism | Replaced By |
|---------------|-------------|
| `wit.toml` / `deck.toml` | `# CLANK-WIT:` comment + `META.json` |
| `wits.lock` | CPAN versioning |
| `wits.index.json` | SQLite DB cache |
| `clank wits install/upgrade/uninstall` | `cpanm` |
| Directory-based discovery | `grep -r "# CLANK-WIT:"` |
| Declarative `.wit` files | CPAN modules |

### 5.8 Security and Trust

Third-party code runs in your process with no sandbox; CPAN does not solve this
either. Security is provenance + policy:

- **In-tree wits** (in `wits/`): trusted — ship with the harness
- **Installed wits**: you ran `cpanm`; CPAN records the version
- **Project wits**: the repo's choice for this checkout

eval isolation protects against bad modules. A broken wit warns and skips.

---

### 2.1 Provider Management

Resolution order for active model: CLI `--provider/--model` > env (`CLANK_PROVIDER`, `CLANK_MODEL`, `CLANK_BASE_URL`) > `~/.clank/config.json` > default (lmstudio). API keys NEVER stored in SQLite or logs:
- env var indirection: config `"api_key": "$MY_KEY"` expands at use time
- optional `~/.clank/keys.json` (chmod 600) for named key refs
- LM Studio needs no key (local); default base_url `http://localhost:1234/v1`

Provider interface: `stream_chat({model,system,messages,tools})` → iterator of `{type=>start|text_delta|toolcall_delta|done,...}`; `complete(...)` non-streaming; `models()` listing. New providers = new subclass + register in `Providers.pm` (or via wit `api->register_provider`).

### 2.2 Compaction (Pi semantics)

Trigger: `est_tokens(context) > context_window - reserve` (default 16384). Check points: between turns inside a run, before new user prompt. Method: walk back from newest accumulating ~tokens until `keep_recent` (default 20k); summarize older span with LLM into structured summary (goal, decisions, files touched, open threads); store as compaction entry in session tree; next context = [summary] + kept messages. Manual: `/compact [instructions]`. Wits may cancel/customize via `session_before_compact`.

### 2.3 Module Map

```
bin/clank                  CLI + Term::ReadLine REPL (unified command dispatch)
bin/clankd                 NDJSON daemon front-end
lib/Clank.pm               version, facade
lib/Clank/Util.pm          uuid4, now_ms, json, truncate_head/tail
lib/Clank/Store.pm         DBI/SQLite: sessions, messages, events, kv, rag+FTS5
lib/Clank/Bus.pm           pub/sub over Store; glob topics; request/reply
lib/Clank/Provider.pm      base class (stream_chat iterator)
lib/Clank/Provider/OpenAICompat.pm   SSE chat-completions client
lib/Clank/Provider/LMStudio.pm       OpenAICompat @ localhost:1234/v1
lib/Clank/Provider/OpenAI.pm         OpenAI API
lib/Clank/Provider/Anthropic.pm      Anthropic Messages API
lib/Clank/Provider/Gemini.pm         Google Gemini API
lib/Clank/Provider/Azure.pm          Azure OpenAI wrapper
lib/Clank/Provider/Ollama.pm         Ollama local API
lib/Clank/Provider/Mock.pm           deterministic offline provider (tests)
lib/Clank/Providers.pm     registry + config/key resolution
lib/Clank/Tool.pm          tool base class (schema + execute)
lib/Clank/Session.pm       session tree over Store
lib/Clank/Session/Messages.pm       message tree ops
lib/Clank/Session/Compaction.pm     threshold compaction (Pi semantics)
lib/Clank/Session/SystemPrompt.pm   prompt building
lib/Clank/Loop.pm          agent loop = Pi runLoop port
lib/Clank/Wit/API.pm       what Wits receive: on/register_tool/command/ui/help
lib/Clank/Wit/Dispatch.pm  inter-wit execution
lib/Clank/Wit/Scanner.pm   discovers user wits via # CLANK-WIT: grep
lib/Clank/PluginManager.pm discovery + load + error isolation
lib/Clank/Skills.pm        SKILL.md discovery + prompt section
lib/Clank/REPL.pm          interactive loop, slash commands, streaming
lib/Clank/Driver.pm        NDJSON protocol driver
lib/Clank/Logic/*.pm       Datalog engine (Term, Unify, Solver, KB, Parser)
lib/Clank/Logic/GoalPlanner.pm      goal decomposition with belief graph scoring
lib/Clank/Logic/Taxonomy.pm         hierarchical classification with inheritance
lib/Clank/Rules.pm         rule-engine facade
lib/Clank/Rules/{Rule,Engine,DSL,Parser}.pm
lib/Clank/Rules/{DecisionTree,FSM,BehaviorTree}.pm
lib/Clank/WorldModel.pm    neurosymbolic world model (entities, relations, facts, beliefs)
lib/Clank/NeuroIntegration.pm  bidirectional LLM ↔ world model (3 phases)
lib/Clank/Crystallizer.pm  LLM solutions → deterministic rules
lib/Clank/Constraints.pm   output validation schemas
lib/Clank/Governor.pm      rate limiter, budget cap, circuit breaker
lib/Clank/Tracer.pm        event-trace log for observability
lib/Clank/Cache.pm         TTL cache for LLM responses
lib/Clank/Metrics.pm       counters for LLM calls, tokens, rules
lib/Clank/EventSourcing.pm immutable state-change log
lib/Clank/Escalation.pm    computational escalation (cheapest correct tool first)
lib/Clank/Band.pm           composable societies of wits (bus workflows)
lib/Clank/Mesh.pm           cross-session communication
lib/Clank/PerlEnv.pm        Perl execution environment
lib/Clank/PerlLoop.pm       agent loop connecting LLM to PerlEnv
lib/Clank/ContextRules.pm   deterministic context rules (DSL)
lib/Clank/Exec.pm           reusable subprocess execution
wits/web/lib/Clank/Wits/Web/*.pm        HTTP requests (4 wits)
wits/build/lib/Clank/Wits/Build/*.pm    Build systems (4 wits)
wits/devops/lib/Clank/Wits/Devops/*.pm  Docker + systemd (4 wits)
wits/debug/lib/Clank/Wits/Debug/*.pm    Debugging tools (4 wits)
```

---

## 6. Curated Wit Catalog

### 6.1 Current Wits (v2, working)

| Wit Group | Count | Contents | Status |
|-----------|-------|----------|--------|
| `logic` | 51 | Datalog, rules DSL, FSM, BT, DT, SAT | ✅ Ported, tested |
| `critic` | 12 | Code critique heuristics | ✅ Ported, tested |
| `git` | 10 | Git operations | ✅ Ported, tested |
| `fs` | 12 | Filesystem operations | ✅ Ported, tested |
| `db` | 8 | DB connect/query/execute/schema/shell | ✅ Ported, tested |
| `perl` | 16 | Perl development tools | ✅ Ported, tested |
| `psh` | 3 | Perl Shell REPL | ✅ Ported, tested |
| `search` | 9 | Local + web search | ✅ Ported, tested |
| `embedding` | 1 | Semantic search via embeddings | ✅ Built |
| `neuro` | 3 | Neurosymbolic integration (Constraints, Crystallizer, NeuroIntegration) | ✅ Built |
| `web` | 4 | HTTP requests (fetch, post, put, delete) | ✅ Built |
| `build` | 4 | Build systems (make, perl build, cpanm, test) | ✅ Built |
| `devops` | 4 | Docker + systemd (ps, run, logs, status) | ✅ Built |
| `debug` | 4 | Debugging (stacktrace, strace, lsof, pstack) | ✅ Built |

### 6.2 Planned Wits (from clank-old, prioritized)

These are the wits worth porting. Not all 77 old decks — just the ones that serve a coding harness.

**High priority** (core coding workflow):
- `db` — database operations (SQLite, PostgreSQL, MySQL) ✅ done
- `web` — HTTP requests, API calls ✅ done
- `build` — make, cmake, cargo, npm ✅ done
- `perl` — Perl-specific utilities (PPI, perlcritic, perltidy) ✅ done

**Medium priority** (devops/sysadmin):
- `devops` — Docker, systemd, service management ✅ done
- `sysadmin` — process management, disk, networking
- `debug` — debugging tools, profiler integration ✅ done

**Low priority** (specialist):
- `email` — send/read email (IMAP/SMTP)
- `time` — scheduling, cron, time zones
- `math` — math operations, unit conversion

**Not porting** (philosophical/exploratory):
- `linus/`, `rms/`, `larry/`, `greybeard/` — philosophy decks
- `agent/`, `ai/`, `mollusk/` — agent orchestration (depends on old infra)
- `cloud/`, `aws/`, `azure/`, etc. — cloud provider wits (need vendor CLIs)
- `federation/`, `swarm/`, `band/` — multi-agent coordination
- `c/` — C toolchain (needs Inline::C/FFI)

### 6.3 The Core Bundle

Not all wits ship with a default install. The `Clank` CPAN dist includes only
the core harness + Session wit. Everything else is a separate CPAN dist,
installable on demand via `cpanm`.

Core bundle: Session wit (part of Clank dist). All other wits are separate
distances: logic, git, fs, db, perl, psh, critic, search, etc. The principle:
if a wit has zero external dependencies and serves the coding workflow, it's a
core candidate. If it needs vendor CLIs, API keys, or non-core binaries, it's
install-on-demand.

---

## 7. The Logic + LLM Integration

The real power of Clank is the hybrid: LLMs for pattern recognition, logic engines for deterministic reasoning, coordinated by the blackboard.

### 7.1 How Logic Engines Are Used

From the `docs/logic` exploration, five integration patterns:

1. **Router pattern** — Input arrives, fast-path checks (Expect/regex) handle trivial cases without calling the LLM. Complex cases route to the appropriate engine. Fallback to LLM with grounded facts injected.

2. **Validator pattern** — LLM proposes, logic disposes. LLM generates a plan; Datalog checks consistency; FSM checks permissions. Validation failure triggers a correction loop.

3. **Classifier pattern** — `classify_input` wit subscribes to `input` topic, matches against rules DSL, annotates the prompt with domain context before the LLM sees it.

4. **Memory pattern** — LLM mentions a fact; Datalog wit asserts it as a fact; future queries retrieve it without re-prompting.

5. **Crystallization pattern** — LLM solves a repetitive task; harness asks "can we write a deterministic rule for this?"; if yes, the soft neural prompt collapses into a fast logic rule.

### 7.2 Computational Escalation

The harness operates on a spectrum from soft to hard:

```
LLM (probabilistic) → Datalog/SAT (formal) → Rules/FSM (heuristic) → Pure Perl (deterministic)
     expensive                                    cheap                        free
```

Try the cheapest correct tool first. Escalate only when needed.

---

## 8. Build Roadmap

### Phase 1: MVP ✅ COMPLETE

The core harness is done and working (705 tests, all passing).

**What's working today:**
- Agent loop (Pi parity), 4 core tools (read, bash, edit, write)
- SQLite store + pub/sub bus
- LLM providers: Ollama, OpenAI, Anthropic, Gemini, Azure, LMStudio, Mock (8 providers)
- REPL with streaming, slash commands (unified command dispatch)
- Clank::Driver + clankd daemon (NDJSON)
- Wit system (CPAN modules, grep discovery, eval isolation)
- Session wit (built-in, registers core commands)
- 10 wit decks (125 wits total), 705 tests offline
- Neurosymbolic infrastructure: WorldModel, NeuroIntegration, Crystallizer, Constraints, Governor, Tracer, Cache, Metrics, EventSourcing, GoalPlanner, Taxonomy

**MVP deliverables:**

| Item | Status | What |
|------|--------|------|
| Anthropic provider | ✅ Done | Native Messages API: `system` top-level, `tool_use`/`tool_result` content blocks, `x-api-key` auth |
| Gemini provider | ✅ Done | Native generateContent API: different message format, `functionCall`/`functionResponse` parts |
| Azure provider | ✅ Done | Thin wrapper over OpenAI-compat: deployment URL + `api-version` query param |
| Ollama + OpenAI | ✅ Done | Full providers (not just aliases) |
| DB wit | ✅ Done | 8 core wits: connect, query, execute, schema, shell, history, export, import |
| README | ⬜ TODO | What it is, how to install, how to run, provider config examples |
| cpanfile | ⬜ TODO | Declare DBI + DBD::SQLite as the only non-core deps |

**MVP bundle: Session wit (core) + logic, git, fs, db, perl, psh as separate CPAN dists.**
5 providers, deps = Perl + SQLite + DBI + git. All wits in the repo; search, SAT,
critic, OS, remote, and DB admin are install-on-demand via `cpanm`.

### Phase 2: Ecosystem

Make the CPAN-based plugin system real + expand provider coverage.

| Item | Status | Notes |
|------|--------|-------|
| `# CLANK-WIT:` comment format | ✅ Done | Grep-able metadata, discovery without loading |
| DB schema for wit registry | ✅ Done | Cache metadata, track loaded/enabled state |
| CPAN dist packaging | ⬜ TODO | Build separate tarballs from wits/ directory |
| P2-3: stdio handler type | ⬜ TODO | Enables untrusted/user code safely. Process boundary. |
| Bedrock provider | ⬜ TODO | AWS SigV4 signing (deferred). |
| More wits (web, build, devops, debug) | ✅ Done | 16 new wits across 4 new decks. |

### Phase 3: Capabilities

Features that make Clank more than a harness — a complete environment.

| Item | Status | Depends on | Why |
|------|--------|-----------|-----|
| Subagents (fork Loop for parallel work) | ✅ Done | Core stable | Multi-file editing, research tasks |
| Background persistence (clankd sessions survive disconnect) | ✅ Done | clankd stable | Long-running tasks |
| RAG/FTS5 retrieval-based tool selection (RATS) | ✅ Done | Wit registry DB | Hundreds of wits without prompt bloat |
| Per-session wit loading | ✅ Done | Wit lifecycle | Different wits for different tasks |
| Director pattern (plan/goal/force-tool) | ✅ Done | Bus hooks | Multi-turn autonomous behaviors |
| Code crystallization (LLM → deterministic rules) | ✅ Done | Logic deck | The system gets faster with use |

### Phase 4: The Minsky Mind (aspirational)

The long-term direction. Not a priority — a horizon.

- Composable societies of wits that invoke each other
- SQLite as the "operating system kernel" (call stack, process queue, instruction memory, IPC)
- Crystallization pipeline: LLM outputs compiled into saved subroutines ✅ partially done (Crystallizer built)
- Computational escalation: cheapest correct tool first, automatically
- Agent-to-agent communication across sessions
- Clank as a complete Perl execution environment, not just a coding tool

This is the vision from minsky.txt. The harness gets us in the door; the Minsky Mind is what we're building toward.

---

## 9. The Recruiting Pitch

Clank v2 is what you show to Perl greybeards:

> "Here's a Perl AI environment. SQLite backend, pub/sub bus, Pi-parity agent loop.
> Four tools, 125 curated wits across 10 decks, Datalog engine, rules DSL, database shell,
> Perl development suite (syntax check, code review, POD, test generation).
> 705 tests, all offline. `prove -l t/` green.
> A wit is a CPAN module in Clank::Wits::* with a register() method.
> `cpanm Clank::Wits::Foo` and it works.
> `grep -r "# CLANK-WIT:" @INC/Clank/Wits/` finds all installed wits.
>
> Supports Ollama, OpenAI, Anthropic, Gemini, Azure out of the box.
> Neurosymbolic: world model, bidirectional LLM integration, crystallization,
> output constraints, goal planning, belief revision.
> Not just a coding harness — a complete Perl shell for AI-assisted reasoning.
> Not a toy. Not a framework. A tool."

The hook: Perl is uniquely suited for this because LLMs can read, write, and extend Perl code natively. The harness can modify itself. That's the thesis, and the working codebase proves it.

---

## 10. Open Questions

These are decisions to make as we proceed, not blockers:

1. **Bus topic vocabulary** — too early to define a standard. Let it evolve through use.
2. **Core bundle list** — discover through real usage, not upfront design.
3. **`# CLANK-WIT:` format** — spec is in Wits.md §3. Refine through use.
4. **Per-session wit loading** — when? How? The lifecycle state machine makes this safe.
5. **Subagent protocol** — how do child loops communicate with parent? Bus topics? Direct IPC?
6. **CPAN dist packaging** — how to build separate tarballs from wits/ directory for independent distribution.
7. **README and cpanfile** — still needed for onboarding and dependency declaration.

---

## Appendix A: Key Files

| File | Purpose | Status |
|------|---------|--------|
| `docs/ROADMAP.md` | This document — vision, architecture, decisions | **Primary source of truth** |
| `docs/AGI.md` | Neurosymbolic AI: theory, components, usage, aspirations | **Keep — neurosymbolic reference** |
| `docs/Wits.md` | Wit system spec (CPAN modules, `# CLANK-WIT:`, discovery, registration) | **Keep — detailed how-to** |
| `docs/DRIVER.md` | Clank::Driver and clankd operational docs | **Keep — user-facing reference** |
| `_tmp/minsky.txt` (clank-old) | 300+ agent types, Society of Mind exploration | **Historical — ideas folded into §3.1** |


