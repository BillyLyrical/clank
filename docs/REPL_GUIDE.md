# Using the Clank REPL

> **Note:** Some features described here are experimental and aspirational.
> Clank is evolving rapidly — not every example may work perfectly yet.
> If something doesn't behave as described, it's a known gap, not user error.

A practical guide to Clank's interactive interface, from first prompt to complex
multi-agent workflows.

---

## Getting Started

```
clank                                     # start with local LM Studio
clank --provider=ollama --model=codellama # Ollama
clank --provider=openai --model=gpt-4o    # OpenAI
clank --provider=anthropic --model=claude-sonnet-4-20250514  # Anthropic
```

You'll see the banner:

```
clank v0.3.0 -- lmstudio (qwen3.8-27b)
db: /home/you/.clank/clank.db | session: a3f1b2c4-...
wits: session, logic, git, fs, critic, search, neuro, ...
type /help for commands
```

Type anything and press Enter. Bare text goes straight to the LLM.

```
clank> hello, what can you do?
I'm an AI coding assistant. I can read files, run bash commands, edit code,
review pull requests, search for bugs, and more. Type /help to see all commands.
```

---

## The Sigil System

Every line you type starts with a **sigil** (first character) that determines
how it's handled. No sigil = bare text goes to the LLM.

| Sigil | Mode | Mnemonic |
|-------|------|----------|
| `/` | Command | Slash commands (Unix tradition) |
| `?` | Query | Question mark = question |
| `$` | Eval | Perl's scalar sigil |
| `@` | Agent | Perl's array sigil |
| `%` | Pipeline | Perl's hash sigil |
| `>` | Pipe | Unix pipe |
| `:` | Topic | IRC-style channel |
| `~` | Wit | Home directory prefix |
| `!` | History | Bash history |
| `#` | Comment | Shell comment |
| *(none)* | LLM | Bare text goes to the LLM |

---

## Slash Commands (`/`)

### Online Help

Clank has a rich help system. Type `/help` for the overview, or `/help <topic>`
for detailed documentation on any subsystem:

```
clank> /help
# shows overview of all sigils and commands

clank> /help agents
# detailed help on the agent system

clank> /help wits
# detailed help on wit discovery and management

clank> /help neurosymbolic
# details on world model, crystallizer, escalation
```

List all available topics:

```
clank> /help topics
help topics:
  overview             Quick reference for all sigils and commands
  sigil:/              Slash commands — /help, /new, /sessions, ...
  sigil:?              Query — ask the LLM without triggering tools
  sigil:$              Eval — execute Perl in harness context
  sigil:@              Agent — dispatch constrained subagents
  sigil:%              Pipeline — run declarative multi-agent networks
  sigil:>              Pipe — inline pipeline construction
  sigil::              Topic — publish/subscribe to bus events
  sigil:~              Wit — discover, load, inspect, manage wits
  sigil:!              History — re-run previous commands
  sigil:#              Comment — annotation, ignored
  sigil:text           Bare text — send to the LLM (action mode)
  agents               Agent profiles — constrained subagents
  pipelines            Pipeline system — declarative workflows
  wits                 Wit system — CPAN modules that extend Clank
  config               Configuration — providers, API keys, dirs
  neurosymbolic        World model, crystallizer, escalation
  session              Session management — new, resume, compact
  editor               Editor integration — multi-line input
```

Fuzzy matching — if you mistype a topic, Clank suggests close matches:

```
clank> /help agent
no exact match for 'agent'. Did you mean:
  /help agents
  /help sigil:@
```

### Session Management

```
clank> /help
  /help          list all commands
  /new           start a new session
  /sessions      list recent sessions (15 most recent)
  /resume <id>   resume a previous session
  /compact       summarize conversation to save context
  /exit          leave the REPL
```

```
clank> /sessions
  a3f1b2c4  fix the parser bug                    Mon Sep  8 14:22
  7e8d9c0b  add unit tests for WorldModel          Mon Sep  8 13:05
  b2c3d4e5  initial exploration                    Sun Sep  7 20:11
```

```
clank> /new
new session 9f8e7d6c-5b4a-3c2d-1e0f-a9b8c7d6e5f4
```

### Compaction

As conversations grow, use `/compact` to summarize and free context space:

```
clank> /compact keep the discussion about auth middleware
compacted (entry c4d5e6f7)
```

### Inspecting State

```
clank> /tools
bash, read, write, edit, glob, grep, webfetch, session_send, session_broadcast,
session_messages, memory

clank> /model
active: lmstudio qwen3.8-27b
known: lmstudio, ollama, openai-compat, anthropic, gemini

clank> /events tool.*
  14:22:01  tool_execution_start    {"name":"read","input":{"path":"lib/Clank.pm"}}
  14:22:02  tool_execution_end      {"name":"read","output":"..."}

clank> /stats
automation ratio: 0.72
escalation: crystallized=15 world_model=8 rules_engine=3 llm_fallback=42
```

---

## Querying (`?`)

Ask the LLM questions without triggering tool use:

```
clank> ? what is the Datalog engine?
The Datalog engine is a deductive reasoning system that evaluates recursive
rules over facts stored in the world model. It uses a semi-naive evaluation
strategy...

clank> ? how does crystallization work?
After each agent conversation, patterns are extracted and stored as
deterministic rules. On future queries, rules are checked first (~1ms)
before falling back to the LLM (~500ms). The system gets cheaper with use.
```

---

## Perl Eval (`$`)

Execute Perl expressions in the harness context. The variables `$store`,
`$bus`, and `$session` are available:

```
clank> $ time()
1725847321

clank> $ use Clank::Util; uuid4()
a3f1b2c4-d5e6-7f89-0a1b-2c3d4e5f6a7b

clank> $ $store->kv_get('last_session')
{session_id => "a3f1b2c4...", turns => 5}

clank> $ scalar @{ $store->list_sessions(limit => 5) }
5
```

---

## Agent Dispatch (`@`)

### List Agents

```
clank> @list
agents:
  architect        Design review, architecture validation  (tools: bash,read)
  debugger         Diagnose and fix bugs (can edit)        (tools: bash,edit,read)
  planner          Task decomposition, dependency ordering  (tools: bash,read)
  reviewer         Code review, evidence-based critique     (tools: bash,read)
  security         Vulnerability scanning, OWASP review     (tools: bash,read)
```

### Run an Agent

Each agent has constrained tools and a focused prompt:

```
clank> @reviewer review lib/Clank/WorldModel.pm
[reviewer] turns: 3

## Review: lib/Clank/WorldModel.pm

### Critical
- [critical] WorldModel.pm:142 — SQL injection in `query_entities()`
  user-supplied `$type` interpolated directly into LIKE clause

### Warning
- [warning] WorldModel.pm:87 — `add_entity()` doesn't validate type field
- [warning] WorldModel.pm:203 — `retract_fact()` is not idempotent

### Suggestion
- [suggestion] WorldModel.pm:45 — consider adding a connection pool

**Assessment: request changes** (1 critical, 2 warnings, 1 suggestion)
```

```
clank> @debugger fix the SQL injection at WorldModel.pm:142
[debugger] turns: 4

Fixed: parameterized the query at WorldModel.pm:142. Changed from:
  $dbh->selectall_arrayref("SELECT * FROM entities WHERE type LIKE '%$type%'")
to:
  $dbh->selectall_arrayref("SELECT * FROM entities WHERE type LIKE ?", undef, "%$type%")
```

```
clank> @security scan lib/ for hardcoded secrets
[security] turns: 2

## Security Findings

[critical] lib/Clank/Provider/OpenAI.pm:23 — hardcoded API key in fallback
[warning] lib/Clank/Wit/Search.pm:67 — API key passed via URL parameter
```

### Check Stats

```
clank> @status
agent stats:
  reviewer         calls:12 ok:11 errors:1 turns:34
  debugger         calls:3 ok:3 errors:0 turns:15
  security         calls:1 ok:1 errors:0 turns:2
```

### Model Override

Use a cheaper or faster model for quick tasks:

```
clank> @reviewer review lib/Clank.pm
# uses the profile's default model (standard)

clank> @agent --model=flash reviewer review lib/Clank.pm
# overrides to the flash tier for speed
```

---

## Pipeline Execution (`%` and `>`)

### Named Pipelines (`%`)

```
clank> % list
pipelines:
  code-review
  security-audit
```

```
clank> % code-review
[pipeline output from all stages...]
```

### Inline Pipes (`>`)

Chain LLM calls without blueprint files. Output of each stage feeds the next:

```
clank> > summarize lib/Clank.pm | find issues | prioritize
```

Stage 1: The LLM summarizes the file.
Stage 2: The summary is sent back, asking the LLM to find issues.
Stage 3: The issues list is sent back, asking for prioritization.

```
clank> > diff HEAD~1 | classify changes | suggest review focus
```

### Blueprint Pipelines

Create `.clank` files in `~/.clank/pipelines/` or `.clank/pipelines/`:

```
Pipeline[
  name("code-review")
  about("Multi-stage code review with blame context")
]

Source[
  name("diff-source")
  topic("git.diff.ready")
]

Agent[
  name("git-context")
  wit("git")
  tool("git_blame")
  subscribe("git.diff.ready")
  publish("git-context.output")
]

Agent[
  name("critic")
  wit("logic")
  tool("critique_code")
  subscribe("git-context.output")
  publish("critic.output")
]

Sink[
  name("review-sink")
  subscribe("critic.output")
  topic("review.complete")
]
```

Run it:
```
clank> % code-review
```

---

## Bus Topics (`:`)

The internal event bus connects all components:

```
clank> : listen tool_execution_start
events on tool_execution_start:
  {"name":"read","input":{"path":"lib/Clank.pm"}}
  {"name":"bash","input":{"command":"prove -l t/"}}

clank> : publish review.complete {"score": 85, "verdict": "approve"}
published to review.complete

clank> : git.commit.done
published to git.commit.done
```

---

## Wit Management (`~`)

### Listing All Discovered Wits

On startup, Clank scans `@INC` for `# CLANK-WIT:` markers and registers all
found wits in the SQLite DB. Use `~ list` to see everything — loaded and
available:

```
clank> ~ list
wits (153):
  session              active    /path/to/lib/Clank/Wits/Session.pm
  logic                active    /path/to/lib/Clank/Wits/Logic.pm
  git                  active    /path/to/lib/Clank/Wits/Git.pm
  fs                   active    /path/to/lib/Clank/Wits/Fs.pm
  critic               active    /path/to/lib/Clank/Wits/Critic.pm
  search               available /path/to/lib/Clank/Wits/Search.pm
  ...
```

States: `active` (loaded and running), `available` (discovered but not loaded),
`disabled` (manually unloaded).

```
clank> ~ status
wits: 12 active, 141 available, 153 total
```

### Inspecting a Wit

```
clank> ~ inspect critic
critic:
  state:   active
  path:    /path/to/lib/Clank/Wits/Critic.pm
  version: 0.0.1
  about:   Code critique heuristics
```

### Loading and Unloading

```
clank> ~ load /path/to/custom/wit
loaded 1 wit(s) from /path/to/custom/wit

clank> ~ unload git
disabled git — 3 hook subscription(s) removed
```

### Finding Wits from the Shell

You can also discover wits without starting the REPL:

```bash
# Find all installed wits with their metadata
grep -rh "# CLANK-WIT:" $(perl -e 'print join ":", @INC')/Clank/Wits/*.pm

# Search for wits matching a keyword
grep -l "# CLANK-WIT:.*hint=.*git" $(perl -e 'print join ":", @INC')/Clank/Wits/*.pm
```

---

## History (`!`)

```
clank> hello, what time is it?
The current time is...

clank> what about in UTC?
The current UTC time is...

clank> !
# re-runs: what about in UTC?

clank> ! 1
# re-runs: hello, what time is it?

clank> ! -2
# re-runs 2 commands ago
```

---

## Editor Integration

For multi-line input or long prompts, open your editor directly from the
`clank>` prompt:

| Keybinding | Description |
|-----------|-------------|
| **Alt+E** | Open `$EDITOR` (works with any readline) |
| **Ctrl+X Ctrl+E** | Open `$EDITOR` (GNU Readline specific) |

How it works:
1. A temp file is created and opened in your editor (`$EDITOR`, falling back
   to `$VISUAL`, then `vi`).
2. Write your input, save, and exit. The content is sent to the REPL as if
   you had typed it.
3. Cancel the editor (exit non-zero) and the input is discarded.

This is useful for:
- Writing long prompts with multiple paragraphs
- Crafting complex Perl eval expressions (`$ ...`)
- Editing pipeline blueprints before running them

```
clank> Ctrl+X Ctrl+E
# opens vi (or $EDITOR) with an empty temp file
# type your multi-line input, save, exit
# the text is submitted to the REPL
```

---

## Comments (`#`)

Lines starting with `#` are silently ignored:

```
clank> # TODO: come back to this later
clank> # this is just a note to myself
```

---

## Complex Workflow Example

Here's a realistic workflow combining multiple features:

### Step 1: Explore the codebase

```
clank> what modules are in the lib/Clank/ directory?
The lib/Clank/ directory contains the following modules:
WorldModel.pm, Bus.pm, Store.pm, Loop.pm, Agent.pm, Pipeline.pm, ...
```

### Step 2: Get a focused review

```
clank> @reviewer review lib/Clank/Bus.pm for race conditions
[reviewer] turns: 3

## Review: lib/Clank/Bus.pm

[critical] Bus.pm:67 — `publish()` iterates `@{$self->{subs}}` without lock
  If a handler calls `subscribe()`, the array is modified during iteration.
  Risk: missed events or iterator corruption.

[warning] Bus.pm:92 — `request()` polls with 50ms sleep, no jitter
  Under load, many requesters hit the journal simultaneously.
```

### Step 3: Fix the critical issue

```
clank> @debugger fix the race condition in Bus.pm:67
[debugger] turns: 5

Fixed: snapshot the subscriber list before iterating:
  my @subs = @{ $self->{subs} };
  for my $sub (@subs) { ... }
This prevents modification during iteration.
```

### Step 4: Verify the fix

```
clank> @security check Bus.pm for remaining thread safety issues
[security] turns: 2

No remaining thread safety issues in Bus.pm. The subscriber snapshot
fix addresses the only race condition.
```

### Step 5: Record a memory

```
clank> /memory add lesson "Bus subscriber iteration" "Always snapshot the subs array before iterating in publish(). Direct iteration causes race conditions if handlers subscribe/unsubscribe." --scope project
Memory added: lesson "Bus subscriber iteration"
```

### Step 6: Check that crystallization captured the pattern

```
clank> /instinct status
crystallized rules: 18
avg confidence: 0.84
top instincts:
  bus_subscriber_snapshot    confidence: 0.95  domain: concurrency
  sql_parameterization       confidence: 0.91  domain: security
  eval_error_handling        confidence: 0.88  domain: error_handling
```

### Step 7: Compact and move on

```
clank> /compact keep the Bus.pm fix discussion
compacted (entry e7f8a9b0)

clank> now let's look at WorldModel.pm...
```

---

## Creating Custom Agents

Create two files in `agents/`:

**`my_agent.toml`**:
```toml
name = "my_agent"
description = "Does specialized analysis of database schemas"
model = "standard"
tools = ["read", "bash"]
max_turns = 5
```

**`my_agent.md`**:
```markdown
# Database Schema Analyst

You analyze database schemas for design issues.

## Rules

1. **Read only** — never modify the database.
2. **Evidence first** — reference the exact table/column.
3. **Focus on**: missing indexes, N+1 patterns, normalization issues.

## Output format

For each issue:
```
[table.column] issue description
  Impact: what goes wrong at scale
  Fix: recommendation
```
```

Then use it:
```
clank> @my_agent analyze the schema in lib/Clank/Store.pm
```

---

## Creating Pipeline Blueprints

### Simple Pass-Through

```
Pipeline[
  name("echo")
  about("echoes input through an LLM")
]
Source[ name("in") topic("echo.input") ]
Agent[ name("llm") wit("logic") tool("chat") subscribe("echo.input") publish("echo.output") ]
Sink[ name("out") subscribe("echo.output") topic("echo.done") ]
```

### Fan-Out (Fork)

Two agents process the same input in parallel:

```
Pipeline[
  name("parallel-review")
  about("review code from two angles simultaneously")
]
Source[ name("in") topic("review.input") ]
Agent[ name("security") wit("critic") tool("security_review") subscribe("review.input") publish("review.security") ]
Agent[ name("quality")  wit("critic") tool("quality_review")  subscribe("review.input") publish("review.quality") ]
Sink[ name("out") subscribe("review.security") subscribe("review.quality") topic("review.done") ]
```

### Chain (Merge)

Agents process sequentially, each building on the previous output:

```
Pipeline[
  name("deep-review")
  about("classify then deep-dive")
]
Source[ name("in") topic("deep.input") ]
Agent[ name("classifier") wit("logic") tool("classify") subscribe("deep.input") publish("deep.classified") ]
Agent[ name("analyzer")  wit("logic") tool("analyze")  subscribe("deep.classified") publish("deep.analyzed") ]
Agent[ name("summarizer") wit("logic") tool("summarize") subscribe("deep.analyzed") publish("deep.summary") ]
Sink[ name("out") subscribe("deep.summary") topic("deep.done") ]
```

---

## Daemon Mode (clankd)

For programmatic access or running Clank as a service:

```bash
# Start as a foreground stdio daemon
clankd --provider=lmstudio --stdio

# Start as a background daemon with a socket
clankd --provider=lmstudio --daemon --socket /tmp/clankd.sock

# Check if running
clankd --status

# Stop the daemon
clankd --stop
```

### NDJSON Protocol

Every line is a JSON object. Every response echoes the `id`:

```json
{"id":1,"command":"ping"}
{"id":1,"ok":1,"pong":1}

{"id":2,"prompt":"@reviewer review lib/Clank.pm"}
{"id":2,"ok":1,"response":"[reviewer] turns: 3\n\n## Review...","turns":3,"tools":[...]}

{"id":3,"command":"session_info"}
{"id":3,"ok":1,"session_id":"a3f1b2c4-...","messages":6,"tools":["bash","read","write",...]}

{"id":4,"command":"shutdown"}
{"id":4,"ok":1,"bye":1}
```

---

## Tips and Patterns

**Use `?` for questions, bare text for tasks:**
```
? what is the caching strategy?    # informational, no tools
fix the cache invalidation bug     # action, triggers tools
```

**Use `#` to annotate your session:**
```
# Phase 1: understand the codebase
what does WorldModel.pm do?

# Phase 2: find issues
@reviewer review lib/Clank/WorldModel.pm

# Phase 3: fix them
@debugger fix the issues found
```

**Chain agents for complex tasks:**
```
@planner plan the refactoring of lib/Clank/Store.pm
@reviewer review the plan for correctness
@debugger implement the first subtask
```

**Use `$` to inspect internal state:**
```
$ $store->kv_get('last_agent_result')
$ scalar @{ $bus->{subs} }
$ $session->id
```

**Monitor with bus topics:**
```
: listen tool_execution_start
: listen agent_end
: listen wit.error
```

**Compact early, compact often:**
```
/compact keep the architecture discussion
```

---

## Worked Examples

These examples show realistic workflows combining multiple features.
Some are aspirational — they describe where Clank is headed, not just
where it is today.

### Example 1: Study a Codebase and Crystallize Rules

```
clank> # Phase 1: explore the project structure
clank> find all Perl modules in lib/
clank> what are the main subsystems?

clank> # Phase 2: learn the coding conventions
clank> ? what naming conventions does this project use for error handling?
clank> ? what's the standard pattern for registering bus subscriptions?

clank> # Phase 3: crystallize what we learned
clank> /instinct create error_handling_pattern \
        condition="error.*handler|die.*catch|eval.*block" \
        action="Always wrap eval blocks with specific error messages. Never use bare eval without $@ checking." \
        confidence=0.85 \
        domain=perl

clank> /instinct create bus_subscription_pattern \
        condition="subscribe.*bus|on.*event" \
        action="Subscribe with name => 'wit:<name>' for tracking. Unsubscribe_all on disable." \
        confidence=0.9 \
        domain=architecture

clank> /instinct status
```

### Example 2: Multi-Agent Code Review Pipeline

```
clank> # Step 1: get the diff
clank> : publish git.diff.ready {}
clank> # (or have a wit produce the diff automatically)

clank> # Step 2: parallel review from multiple angles
clank> @reviewer review lib/Clank/Store.pm for race conditions and API design
clank> @security scan lib/Clank/Store.pm for SQL injection and injection attacks

clank> # Step 3: synthesize findings
clank> ? given these two reviews, what are the top 3 priorities?
clank> The reviews found: [paste both outputs]

clank> # Step 4: fix the critical issues
clank> @debugger fix the SQL injection in Store.pm and the race condition in Bus.pm

clank> # Step 5: verify the fix
clank> @reviewer review the changes for correctness

clank> # Step 6: compact and record lessons
clank> /compact keep the Store.pm fix discussion
clank> /instinct create store_sql_safety \
        condition="Store\.pm.*query|SQL.*inject" \
        action="Always use parameterized queries in Store.pm. Never interpolate user input into SQL." \
        confidence=0.95 \
        domain=security
```

### Example 3: Create a Custom Pipeline from the REPL

```
clank> # Define a pipeline inline using Perl eval
clank> $ use Clank::Pipeline;
clank> my @stages = (
clank>   { name => 'summarize', prompt => 'Summarize the following code concisely' },
clank>   { name => 'critique',  prompt => 'Find issues and suggest improvements' },
clank>   { name => 'prioritize', prompt => 'Rank issues by severity and effort' },
clank> );
clank> my $result = Clank::Pipeline->run_inline(
clank>   join(' | ', map { $_->{prompt} } @stages),
clank>   app => $app
clank> );
clank> print $result->{output};
```

### Example 4: Interactive Exploration with History Replay

```
clank> # Explore the bus system
clank> ? how does the pub/sub bus work?
clank> what events does the bus publish?

clank> # Oops, wrong direction — let's go back
clank> ! 1     # re-run: what events does the bus publish?
clank> ! -2     # re-run: how does the pub/sub bus work?

clank> # Now dive deeper
clank> @reviewer review lib/Clank/Bus.pm for thread safety
clank> ? based on the review, what are the concurrency risks?

clank> # Record what we learned
clank> /instinct create bus_concurrency_risk \
        condition="Bus.*concurr|thread.*safe|race.*condition" \
        action="Bus publish() must snapshot subscriber list before iteration. See Bus.pm:67." \
        confidence=0.9
```

### Example 5: Agent Chaining with Delegation

```
clank> # Start with high-level planning
clank> @planner decompose the task 'refactor the store layer' into subtasks

clank> # Review the plan
clank> @reviewer review this plan for completeness and correctness

clank> # Execute each subtask with the right agent
clank> @debugger implement subtask 1: extract ConnectionPool from Store.pm
clank> @security review the ConnectionPool for injection vulnerabilities
clank> @debugger implement subtask 2: parameterize all queries

clank> # Final verification
clank> @architect validate the overall design changes

clank> # Compact the session
clank> /compact keep the store refactor discussion and final design
```

### Example 6: Live Debugging with Bus Monitoring

```
clank> # Start monitoring bus events
clank> : listen tool_execution_start

clank> # Run the problematic code
clank> @debugger diagnose why clank crashes when resuming sessions

clank> # Check what happened on the bus
clank> : listen wit.error

clank> # If the debugger didn't find it, use $ to inspect directly
clank> $ use DBI;
clank> my $dbh = DBI->connect("dbi:SQLite:dbname=$ENV{HOME}/.clank/clank.db");
clank> my $rows = $dbh->selectall_arrayref("SELECT * FROM sessions ORDER BY updated_at DESC LIMIT 3");
clank> $ rows->[0]{id}

clank> # Now fix it
clank> @debugger fix the resume crash — it's a missing column check in Store.pm
```

### Example 7: Knowledge Capture and Recall

```
clank> # Learn something new about the project
clank> ? what is the WorldModel's query API?
clank> how do entities and relations work?

clank> # Capture it as a memory
clank> /memory add reference "WorldModel Query API" "Entities are queried via query_entities(type). Relations via query_relations(from, to, type). Facts have temporal bounds (valid_from, valid_to)."

clank> # Later, the LLM will recall this automatically
clank> # when you ask about the WorldModel

clank> # Also crystallize the pattern
clank> /instinct create worldmodel_query_pattern \
        condition="WorldModel.*query|query_entit" \
        action="Use query_entities(type) for entities, query_relations(from,to,type) for relations. Always check temporal bounds." \
        confidence=0.85 \
        domain=architecture
```

### Example 8: Using Editor for Complex Prompts

```
clank> # Press Alt+E or Ctrl+X Ctrl+E to open your editor
clank> # Write a multi-line prompt:

# Code Review Request

Review lib/Clank/Loop.pm with focus on:

1. Error handling — are all edge cases covered?
2. Performance — any N+1 patterns or unnecessary allocations?
3. Security — can the LLM be tricked via prompt injection?
4. Memory — does context grow unbounded?

Output format:
- [critical] must fix before merge
- [warning] should fix, may cause issues
- [suggestion] nice to have

Save and exit — the text is sent to the REPL.

clank> @reviewer (the above prompt is sent automatically)
```

### Example 9: Daemon Mode Workflow (clankd)

```bash
# Terminal 1: start the daemon
clankd --provider=openai --model=gpt-4o --stdio

# Terminal 2: interact via NDJSON
# Ping
echo '{"id":1,"command":"ping"}' | nc -U /tmp/clankd.sock

# Run a review
echo '{"id":2,"prompt":"@reviewer review lib/Clank/Store.pm"}' | nc -U /tmp/clankd.sock

# Use /help via the command field
echo '{"id":3,"command":"/help agents"}' | nc -U /tmp/clankd.sock

# Check session state
echo '{"id":4,"command":"session_info"}' | nc -U /tmp/clankd.sock

# Monitor events
echo '{"id":5,"command":"events","topic":"tool_*","limit":10}' | nc -U /tmp/clankd.sock
```

### Example 10: Full Session Lifecycle

```
clank> # Start fresh
clank> /new

clank> # Explore
clank> what files are in this project?
clank> what does the README say?

clank> # Learn
clank> ? what are the main design patterns used here?

clank> # Build
clank> @planner plan the implementation of a new /config command
clank> @debugger implement the plan

clank> # Review
clank> @reviewer review the changes
clank> @security check for issues

clank> # Record
clank> /instinct create config_command_pattern \
        condition="config.*command|/config" \
        action="Config commands should check ./ .clank/config.json first, then ~/.clank/config.json." \
        confidence=0.8
clank> /compact keep the /config command implementation

clank> # Check what we've learned
clank> /instinct status
clank> /stats

clank> # Save and move on
clank> /exit
```
