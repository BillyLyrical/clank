# CLAM v2 — Roadmap

> A Perl AI coding harness for experienced unix-perl greybeards.
> Simple core, Minsky blackboard, curated Wits ecosystem.

---

## 1. What Clam Is

Clam is a complete Perl environment for AI-assisted development and reasoning. It is:

- **An AI harness** — agent loop, tools, LLM providers, session management (ported from Pi)
- **A blackboard system** — Minsky's Society of Mind via SQLite pub/sub bus
- **A logic engine suite** — Datalog, rules DSL, FSM, behavior trees, SAT solving
- **A plugin ecosystem** — curated Wits (tools, commands, bus hooks) with CPAN discipline
- **A unix tool** — CLI REPL, NDJSON daemon, programmatic driver, zero mandatory deps beyond SQLite

The MVP is a coding harness. The vision is a complete neuro-symbolic execution environment — a Perl shell where LLMs, logic engines, and user code collaborate on the blackboard. We build the harness first because it's useful today; we keep the architecture clean so the Minsky Mind remains reachable.

### What This Is Not

- Not an "operating system for AI agents" (what clam-old became)
- Not a free-for-all plugin marketplace (the Tower of Babel problem)
- Not a Python/TypeScript harness with Perl bolted on — Perl is the foundation

---

## 2. Architecture

Three layers. Nothing calls anything else directly — everything goes through the bus.

```
┌─────────────────────────────────────────────┐
│              User / CLI / Daemon             │
│         (bin/clam, bin/clamd)                │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│              Clam::App                       │
│  ┌─────────┐  ┌─────────┐  ┌────────────┐  │
│  │  Store  │  │   Bus   │  │  Provider   │  │
│  │ (SQLite)│◄─┤(pub/sub)│  │ (LLM HTTP)  │  │
│  └─────────┘  └────┬────┘  └────────────┘  │
│                     │                        │
│  ┌──────────────────▼─────────────────────┐  │
│  │         Clam::Loop (Pi port)           │  │
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

## 3. The Wisdom of Clam v1 (What to Keep)

Clam v1 (clam-old) was 68 modules, 654 wits, 77 decks. Most of it was feature creep. But the intellectual core was sound:

### 3.1 The Minsky Vision (from minsky.txt)

The Society of Mind architecture: intelligence emerges from many simple, specialized agents communicating via message passing. The key architectural ideas worth keeping:

- **Modular agents with typed I/O contracts** — each wit does one thing
- **Shared working memory** (the blackboard/SQLite store) — all agents read/write facts
- **Inhibition/safety layers** — some agents veto others (guardrails, rate limits)
- **Feedback loops via critic agents** — LLM proposes, logic disposes
- **Composable societies** — wits that combine into larger capabilities

What NOT to keep: the 300+ philosophical agent types (Jungian archetypes, Kierkegaardian agents, Machiavellian politics, Stoic philosophy, Confucianism, 36 Stratagems). These were intellectual explorations, not coding harness features.

### 3.2 The Logic Engines

Clam v1 had six reasoning systems. Clam v2 correctly distilled these into two:

| Engine | Purpose | Status |
|--------|---------|--------|
| **Clam::Logic** (Datalog) | What follows necessarily — formal reasoning | ✅ In logic deck |
| **Clam::Rules** (heuristic) | What matches, and how confidently | ✅ In logic deck |
| **Clam::Rules::FSM** | State-dependent behavior | ✅ In logic deck |
| **Clam::Rules::BehaviorTree** | Prioritized fallback decisions | ✅ In logic deck |
| **Clam::Rules::DecisionTree** | Rule chains with branching | ✅ In logic deck |
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

Key lessons that validate Clam's architecture:

1. **Single authoritative state.** "If authoritative state cannot be derived from the journal, rewind, fork, and resume are lies." Clam's SQLite Store IS this — events table is the journal, everything derives from it.

2. **Extension state must not escape the journal.** Of 17 stateful Pi extensions, only 2 were correct. Module-level closures become second sources of truth. Clam's curated wits + Bus hooks over SQLite solve this by making wit state live in the Store, not in Perl closures.

3. **The Director pattern.** Multi-turn behaviors (plan, goal, force-tool) need a stack of controllers that own the yield decision. Clam's Bus + wit hooks can implement this.

4. **Complexity conservation.** "Unavoidable complexity needs an owner." Clam v1 spread it across 68 modules. Clam v2 pushes it into the core (Loop, Store, Bus) and keeps wits thin.

### 4.2 Prime Agent (PrimeIntellect)

Python harness built on Pi. Validates the "harness as programming language" thesis. Key features it has that Clam should consider:

- Subagents built in (rlm() spawns child agents)
- Daemon-backed sessions (background agents survive terminal disconnect)
- Persistent goals and heartbeats
- Automatic compaction

Clam already has Driver/clamd for programmatic sessions. The gap is background persistence and subagents — both are P3 items.

### 4.3 DeepSeek Harness / Cordis

DeepSeek's answer to "random plugins don't play nice": complex dependency injection with fibers, revertible effects, HMR, two planes (host composition + agent preset). It's engineering for a chaotic plugin ecosystem.

**Clam's answer is simpler: curate the plugins.** If you vet what enters the ecosystem, you don't need Cordis's complexity. The trust boundary IS the deck. Curated wits share hooks and data freely because they're vetted. Local/unvetted wits are second-class citizens.

### 4.4 The Tower of Babel (stencil.so)

The core insight: AI harnesses that encourage MANY user plugin ecosystems become fragmented, incompatible, and provide a large attack surface. This is exactly what happened to clam v1 (654 wits across 77 decks, 5 overlapping extension mechanisms). The curated approach is the correct response.

---

## 5. The Wit System

### 5.1 What a Wit Is

A wit is a CPAN module that extends the clam harness: tools the LLM can call,
REPL slash commands, and event hooks on the bus.

**One system, one source of truth: wits are CPAN modules.**

| Concern | Mechanism | Custom code? |
|---------|-----------|-------------|
| Distribution | `cpanm Clam::Wits::Foo` | No |
| Discovery | `grep -r "# CLAM-WIT:" @INC/Clam/Wits/` | No |
| Metadata | `# CLAM-WIT:` comment in module file | No |
| Dependencies | `META.json` + cpanm | No |
| Runtime state | SQLite DB (loaded, enabled) | Yes (exists) |
| Loading | `require` + `register($api)` | Yes (exists) |
| Isolation | `eval { require ... }` | Yes (exists) |

### 5.2 The `# CLAM-WIT:` Comment Format

Every wit module has a `# CLAM-WIT:` comment block near the top. This is the
single source of truth for discovery metadata — grep finds it without loading
the module.

```perl
# CLAM-WIT: name=Foo
# CLAM-WIT: version=1.0
# CLAM-WIT: about=Blocks dangerous git commands before they run
# CLAM-WIT: usage=Load in any repo you trust the model with
# CLAM-WIT: hint=Git safety: vetoes rm, reset --hard, push -f, force
# CLAM-WIT: author=you
# CLAM-WIT: license=Artistic-2.0
package Clam::Wits::Foo;
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
the runtime view; the `# CLAM-WIT:` comment is the source of truth.

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
1. Scan: `grep -r "# CLAM-WIT:" @INC/Clam/Wits/`
2. Cache: Store metadata in SQLite DB
3. Select: Query DB to decide which wits to load
4. Load: `require Clam::Wits::Foo` (Perl finds it in `@INC`)
5. Register: Call `$wit->register($api)`

**Development** (in-tree wits):
1. Scan: `grep -r "# CLAM-WIT:" wits/*/lib/Clam/Wits/`
2. Select: Same as production
3. Load: Add each wit's `lib/` to `@INC`, then `require`
4. Register: Same as production

Same loader, same code. Just different `@INC` setup.

eval around `require` + `register`. A broken wit warns and skips. The harness
always runs (527 tests, all passing).

### 5.5 Lifecycle

```
LOADED → ACTIVE ⇄ DISABLED
```

- **ACTIVE**: registered tools callable by the LLM, commands in the REPL, hooks on the bus.
- **DISABLED**: all registrations reverted; module still compiled in memory; re-enable is instant.

Revertible effects (borrowed from Cordis, simplified): every registration tracks
its reverse. Disable reverts all effects. Module wits can't truly unload without
restart — honest Unix answer: disable + restart clamd.

### 5.6 Distribution Model

**Core dist: `Clam`** — the minimum viable harness.

```
Clam/
  lib/Clam.pm
  lib/Clam/App.pm
  lib/Clam/Loop.pm
  lib/Clam/Bus.pm
  lib/Clam/Store.pm
  lib/Clam/Provider/*.pm
  lib/Clam/Tool.pm
  lib/Clam/Tools/*.pm
  lib/Clam/Wit/API.pm
  lib/Clam/Wit/Session.pm
  bin/clam
  bin/clamd
  META.json
```

`cpanm Clam` installs the core. Session wit is included (part of the harness).
All other wits are separate dists.

**Wit dists: `Clam-Wits-Foo`** — one per wit (or one per related group).

```
Clam-Wits-Foo/
  lib/Clam/Wits/Foo.pm
  lib/Clam/Wits/Foo/Helper.pm
  META.json
  t/
```

`cpanm Clam-Wits-Foo` installs the wit. `META.json` declares
`requires => { Clam => '1.0' }`.

After installation, everything lands in one `@INC` tree. One tree, one grep,
all wits found. In the git repo, wits live in `wits/` as separate dist
directories — a staging area for development, not shipped in the core dist.

### 5.7 What Goes Away

| Old Mechanism | Replaced By |
|---------------|-------------|
| `wit.toml` / `deck.toml` | `# CLAM-WIT:` comment + `META.json` |
| `wits.lock` | CPAN versioning |
| `wits.index.json` | SQLite DB cache |
| `clam wits install/upgrade/uninstall` | `cpanm` |
| Directory-based discovery | `grep -r "# CLAM-WIT:"` |
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

Resolution order for active model: CLI `--provider/--model` > env (`CLAM_PROVIDER`, `CLAM_MODEL`, `CLAM_BASE_URL`) > `~/.clam/config.json` > default (lmstudio). API keys NEVER stored in SQLite or logs:
- env var indirection: config `"api_key": "$MY_KEY"` expands at use time
- optional `~/.clam/keys.json` (chmod 600) for named key refs
- LM Studio needs no key (local); default base_url `http://localhost:1234/v1`

Provider interface: `stream_chat({model,system,messages,tools})` → iterator of `{type=>start|text_delta|toolcall_delta|done,...}`; `complete(...)` non-streaming; `models()` listing. New providers = new subclass + register in `Providers.pm` (or via wit `api->register_provider`).

### 2.2 Compaction (Pi semantics)

Trigger: `est_tokens(context) > context_window - reserve` (default 16384). Check points: between turns inside a run, before new user prompt. Method: walk back from newest accumulating ~tokens until `keep_recent` (default 20k); summarize older span with LLM into structured summary (goal, decisions, files touched, open threads); store as compaction entry in session tree; next context = [summary] + kept messages. Manual: `/compact [instructions]`. Wits may cancel/customize via `session_before_compact`.

### 2.3 Module Map

```
bin/clam                  CLI + Term::ReadLine REPL (unified command dispatch)
bin/clamd                 NDJSON daemon front-end
lib/Clam.pm               version, facade
lib/Clam/Util.pm          uuid4, now_ms, json, truncate_head/tail
lib/Clam/Store.pm         DBI/SQLite: sessions, messages, events, kv, rag+FTS5
lib/Clam/Bus.pm           pub/sub over Store; glob topics; request/reply
lib/Clam/Messages.pm      user/assistant/toolResult/custom + to_llm()
lib/Clam/SystemPrompt.pm  Pi's prompt, verbatim structure (clam-branded)
lib/Clam/Provider.pm      base class (stream_chat iterator)
lib/Clam/Provider/OpenAICompat.pm   SSE chat-completions client
lib/Clam/Provider/LMStudio.pm       OpenAICompat @ localhost:1234/v1
lib/Clam/Provider/Mock.pm           deterministic offline provider (tests)
lib/Clam/Providers.pm     registry + config/key resolution
lib/Clam/LLM.pm           facade used by Loop
lib/Clam/Tool.pm          tool base class (schema + execute)
lib/Clam/Tools/{Read,Bash,Edit,Write}.pm   Pi's tools, exact prompts
lib/Clam/Tools.pm         registry: builtins + wit-registered
lib/Clam/Session.pm       session tree over Store
lib/Clam/Loop.pm          agent loop = Pi runLoop port
lib/Clam/Wit/API.pm       what Wits receive: on/register_tool/command/ui/help
lib/Clam/Wit/Session.pm   built-in wit: core REPL commands
lib/Clam/Wit/Dispatch.pm  inter-wit execution
lib/Clam/Wit/Scanner.pm   discovers user wits via # CLAM-WIT: grep
lib/Clam/PluginManager.pm discovery + load + error isolation
lib/Clam/Skills.pm        SKILL.md discovery + prompt section
lib/Clam/Compaction.pm    threshold compaction (Pi semantics)
lib/Clam/REPL.pm          interactive loop, slash commands, streaming
lib/Clam/Logic/*.pm       Datalog engine (Term, Unify, Solver, KB, Parser)
lib/Clam/Rules.pm         rule-engine facade
lib/Clam/Rules/{Rule,Engine,DSL,Parser}.pm
lib/Clam/Rules/{DecisionTree,FSM,BehaviorTree}.pm
```

---

## 6. Curated Wit Catalog

### 6.1 Current Wits (v2, working)

| Wit Group | Count | Contents | Status |
|-----------|-------|----------|--------|
| `logic` | 35 | Datalog, rules DSL, FSM, BT, DT, SAT | ✅ Ported, tested |
| `critic` | 12 | Code critique heuristics | ✅ Ported, tested |
| `git` | 10 | Git operations | ✅ Ported, tested |
| `fs` | 18 | Filesystem operations | ✅ Ported, tested |
| `db` | 8 | DB connect/query/execute/schema/shell | ✅ Ported, tested |
| `perl` | 16 | Perl development tools | ✅ Ported, tested |
| `psh` | 3 | Perl Shell REPL | ✅ Ported, tested |
| `search` | 9 | Local + web search | ✅ Ported, tested |

### 6.2 Planned Wits (from clam-old, prioritized)

These are the wits worth porting. Not all 77 old decks — just the ones that serve a coding harness.

**High priority** (core coding workflow):
- `db` — database operations (SQLite, PostgreSQL, MySQL)
- `web` — HTTP requests, API calls
- `build` — make, cmake, cargo, npm
- `perl` — Perl-specific utilities (PPI, perlcritic, perltidy)

**Medium priority** (devops/sysadmin):
- `devops` — Docker, systemd, service management
- `sysadmin` — process management, disk, networking
- `debug` — debugging tools, profiler integration

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

Not all wits ship with a default install. The `Clam` CPAN dist includes only
the core harness + Session wit. Everything else is a separate CPAN dist,
installable on demand via `cpanm`.

Core bundle: Session wit (part of Clam dist). All other wits are separate
distances: logic, git, fs, db, perl, psh, critic, search, etc. The principle:
if a wit has zero external dependencies and serves the coding workflow, it's a
core candidate. If it needs vendor CLIs, API keys, or non-core binaries, it's
install-on-demand.

---

## 7. The Logic + LLM Integration

The real power of Clam is the hybrid: LLMs for pattern recognition, logic engines for deterministic reasoning, coordinated by the blackboard.

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

### Phase 1: MVP (now)

The core harness is done and working (527 tests). MVP adds providers + README so someone can actually use it.

**What's working today:**
- Agent loop (Pi parity), 4 core tools (read, bash, edit, write)
- SQLite store + pub/sub bus
- LLM providers: LMStudio, OpenAI-compat, Mock
- REPL with streaming, slash commands (unified command dispatch)
- Clam::Driver + clamd daemon (NDJSON)
- Wit system (CPAN modules, grep discovery, eval isolation)
- Session wit (built-in, registers core commands)
- 8 decks ported (111 wits total), 527 tests offline

**MVP deliverables:**

| Item | Effort | What |
|------|--------|------|
| Anthropic provider | ~1 day | Native Messages API: `system` top-level, `tool_use`/`tool_result` content blocks, `x-api-key` auth, different streaming format |
| Gemini provider | ~1 day | Native generateContent API: different message format, `functionCall`/`functionResponse` parts, API key auth |
| Azure provider | ~2 hours | Thin wrapper over OpenAI-compat: deployment URL construction + `api-version` query param |
| Ollama + OpenAI aliases | ~10 min | `ollama` = localhost:11434, `openai` = api.openai.com, both use OpenAI-compat |
| DB wit | ported | 8 core wits: connect, query, execute, schema, shell, history, export, import |
| README | ~half day | What it is, how to install, how to run, provider config examples |
| cpanfile | ~10 min | Declare DBI + DBD::SQLite as the only non-core deps |

**MVP bundle: Session wit (core) + logic, git, fs, db, perl, psh as separate CPAN dists.**
5 providers, deps = Perl + SQLite + DBI + git. All wits in the repo; search, SAT,
critic, OS, remote, and DB admin are install-on-demand via `cpanm`.

### Phase 2: Ecosystem

Make the CPAN-based plugin system real + expand provider coverage.

| Item | Effort | Why |
|------|--------|-----|
| `# CLAM-WIT:` comment format | ~1 day | Grep-able metadata, discovery without loading |
| DB schema for wit registry | ~1 day | Cache metadata, track loaded/enabled state |
| CPAN dist packaging | ~1 day | Build separate tarballs from wits/ directory |
| P2-3: stdio handler type | ~1 day | Enables untrusted/user code safely. Process boundary. |
| Bedrock provider | ~1 day | AWS SigV4 signing (deferred from MVP). |
| More wits (db, web, build, perl) | ongoing | Grow the curated catalog based on real needs. |

### Phase 3: Capabilities

Features that make Clam more than a harness — a complete environment.

| Item | Depends on | Why |
|------|-----------|-----|
| Subagents (fork Loop for parallel work) | Core stable | Multi-file editing, research tasks |
| Background persistence (clamd sessions survive disconnect) | clamd stable | Long-running tasks |
| RAG/FTS5 retrieval-based tool selection | Wit registry DB | Hundreds of wits without prompt bloat |
| Per-session wit loading | Wit lifecycle | Different wits for different tasks |
| Director pattern (plan/goal/force-tool) | Bus hooks | Multi-turn autonomous behaviors |
| Code crystallization (LLM → deterministic rules) | Logic deck | The system gets faster with use |

### Phase 4: The Minsky Mind (aspirational)

The long-term direction. Not a priority — a horizon.

- Composable societies of wits that invoke each other
- SQLite as the "operating system kernel" (call stack, process queue, instruction memory, IPC)
- Crystallization pipeline: LLM outputs compiled into saved subroutines
- Computational escalation: cheapest correct tool first, automatically
- Agent-to-agent communication across sessions
- Clam as a complete Perl execution environment, not just a coding tool

This is the vision from minsky.txt. The harness gets us in the door; the Minsky Mind is what we're building toward.

---

## 9. The Recruiting Pitch

Clam v2 is what you show to Perl greybeards:

> "Here's a Perl AI environment. SQLite backend, pub/sub bus, Pi-parity agent loop.
> Four tools, 115 curated wits, Datalog engine, rules DSL, database shell,
> Perl development suite (syntax check, code review, POD, test generation).
> 556 tests, all offline. `prove -l t/` green.
> A wit is a CPAN module in Clam::Wits::* with a register() method.
> `cpanm Clam::Wits::Foo` and it works.
> `grep -r "# CLAM-WIT:" @INC/Clam/Wits/` finds all installed wits.
>
> Supports Ollama, OpenAI, Anthropic, Gemini, Azure out of the box.
> Not just a coding harness — a complete Perl shell for AI-assisted reasoning.
> Not a toy. Not a framework. A tool."

The hook: Perl is uniquely suited for this because LLMs can read, write, and extend Perl code natively. The harness can modify itself. That's the thesis, and the working codebase proves it.

---

## 10. Open Questions

These are decisions to make as we proceed, not blockers:

1. **Bus topic vocabulary** — too early to define a standard. Let it evolve through use.
2. **Core bundle list** — discover through real usage, not upfront design.
3. **`# CLAM-WIT:` format** — spec is in Wits.md §3. Refine through use.
4. **Per-session wit loading** — when? How? The lifecycle state machine makes this safe.
5. **Subagent protocol** — how do child loops communicate with parent? Bus topics? Direct IPC?

---

## Appendix A: Key Files

| File | Purpose | Status |
|------|---------|--------|
| `docs/ROADMAP.md` | This document — vision, architecture, decisions | **Primary source of truth** |
| `docs/Wits.md` | Wit system spec (CPAN modules, `# CLAM-WIT:`, discovery, registration) | **Keep — detailed how-to** |
| `docs/DRIVER.md` | Clam::Driver and clamd operational docs | **Keep — user-facing reference** |
| `_tmp/minsky.txt` (clam-old) | 300+ agent types, Society of Mind exploration | **Historical — ideas folded into §3.1** |

Deleted (consolidated into ROADMAP):
- `docs/DESIGN.md` → §2, §2.1, §2.2, §2.3
- `docs/plan.txt` → §3, §7, §8
- `docs/verdict` → §5.6
- `docs/logic` → §7
- `docs/cordis` → §4.3

## Appendix B: Clam v1 Postmortem (What NOT to Repeat)

| Problem | v1 Count | v2 Approach |
|---------|----------|-------------|
| Perl modules | 68 | ~25 core + wit libraries |
| .wit files | 654 | 118 (port selectively) |
| Deck directories | 77 | 8 (grow on demand) |
| Extension mechanisms | 5 (Wits, Plugins, Skills, Rules, Recipes) | 1 (Wits) |
| Reasoning engines | 6 | 2 (Logic + Rules) |
| Agent coordination | 5 (Band, Society, Debate, Swarm, Federation) | Bus topics |
| Knowledge systems | 5 (Dream, Wiki, Skills, Store, Recipe) | Store + FTS5 |
| Communication patterns | 4 (Bus, Blackboard, Store, TiedHash) | Bus over Store |
| God Object (Core.pm) | 1585 lines | App.pm + Loop.pm + REPL.pm |
| Process turn() | 22 steps, 300 lines | Loop.pm (Pi port) |
| Philosophy decks | 8 (linus, rms, larry, etc.) | 0 |

The pattern: v1 tried to be everything. v2 does one thing well and lets wits add the rest.
