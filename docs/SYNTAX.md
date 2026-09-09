# Syntax, Semantics, and Pipeline Format

Status: design document. How the REPL signals intent via sigils,
how Minsky pipelines are declared, and how everything hooks together.

---

## 1. Sigil-Based REPL

The REPL dispatches on the first character. Each sigil is a mode.
Perl developers already know these as syntax markers — extending
them to REPL modes is natural.

### 1.1 Sigil Table

| Sigil | Mode | Example | Description |
|-------|------|---------|-------------|
| `/` | Command | `/wits list` | Slash command (wit-registered) |
| `?` | Query | `? what is Datalog?` | LLM natural language query |
| `$` | Eval | `$ time()` | Perl expression evaluation |
| `@` | Agent | `@plan implement auth` | Agent dispatch (plan/execute) |
| `%` | Pipeline | `% code-review` | Run named pipeline |
| `>` | Pipe | `> diff \| classify \| critique` | Inline pipeline construction |
| `:` | Topic | `: git.commit.done` | Bus topic publish/subscribe |
| `~` | Wit | `~ load logic` | Wit management (load/unload/list) |
| `!` | History | `! 42` | Re-run command 42 |
| `#` | Comment | `# this is ignored` | No-op (skip line) |
| (none) | Prompt | `fix the bug in Foo.pm` | Send to LLM (current behavior) |

### 1.2 Parser Design

The REPL parser becomes a sigil dispatch table. No regex chains,
no nested if/else — just a hash of coderefs:

```perl
sub _dispatch {
    my ($self, $app, $line) = @_;
    return undef unless length $line;

    my $sigil = substr($line, 0, 1);
    my %dispatch = (
        '/' => sub { $self->_command($app, $line) },
        '?' => sub { $self->_query($app, $line) },
        '$' => sub { $self->_eval($app, $line) },
        '@' => sub { $self->_agent($app, $line) },
        '%' => sub { $self->_pipeline($app, $line) },
        '>' => sub { $self->_pipe($app, $line) },
        ':' => sub { $self->_topic($app, $line) },
        '~' => sub { $self->_wit($app, $line) },
        '!' => sub { $self->_history($app, $line) },
    );

    my $handler = $dispatch{$sigil};
    return $handler ? $handler->($line) : undef;
}
```

No sigil = no match = fall through to LLM prompt (existing behavior).
This preserves backward compatibility: bare text still goes to the agent.

### 1.3 Sigil Semantics

**`/` — Command** (existing, unchanged)

```
/wits list
/compact
/new
/exit
```

Dispatches to wit-registered command handlers. Already implemented in
`REPL.pm::_dispatch`. No changes needed.

**`?` — Query**

```
? explain the Datalog engine
? how does crystallization work?
? what wits are loaded?
```

Wraps the text as a prompt and sends it to the LLM. Differs from bare
text in that `?` queries are *informational* — they don't trigger tool
calls. The LLM responds with explanation, not action.

Implementation: send as a user message with a system-injected instruction:
"This is a question about the system. Answer from your knowledge of Clank.
Do not use tools unless explicitly asked."

**`$` — Perl Eval**

```
$ time()
$ use Clank::Util; uuid4()
$ $store->kv_get('last_session')
```

Evals the expression in the harness's Perl context. Returns the result.
The `$` sigil is already Perl's scalar prefix — users expect it to mean
"evaluate this Perl thing."

Implementation: `eval` the expression (after stripping the sigil) in a
context where `$app`, `$store`, `$bus`, `$session` are available.
Return the stringified result. Catch errors with `eval { ... } or do { ... }`.

**`@` — Agent Dispatch**

```
@plan implement authentication
@execute plan-42
@status
@list
```

Agent operations: plan decomposition, execution, status checks.
The `@` sigil is Perl's array prefix — agent dispatch returns a list
of sub-tasks or results.

Implementation: routes to `Clank::Director` or agent-loop manager.
`@plan` triggers goal decomposition. `@execute` runs a plan.
`@status` shows active agents. `@list` shows plans.

**`%` — Pipeline**

```
% code-review
% security-audit
% list
```

Runs a named pipeline (see section 2). `%` is Perl's hash prefix —
pipelines are keyed by name.

Implementation: loads the pipeline blueprint from `~/.clank/pipelines/`,
wires up bus subscriptions, and runs the source through the route.

**`>` — Inline Pipe**

```
> diff HEAD~1 | classify | critique
> input | route(git) | execute
```

Constructs a pipeline inline. `>` is the Unix pipe redirect — natural
for flow. The `|` separator chains stages.

Implementation: parses the pipe chain, creates ephemeral bus wiring,
runs the pipeline, returns the result.

**`:` — Topic**

```
: git.commit.done
: listen tool.call
: publish review.complete { "score": 85 }
```

Bus operations. `:` is used in shell history expansion — repurposed
for topic addressing (like `#channel` in IRC).

Implementation: `: <topic>` publishes an empty event. `: listen <topic>`
subscribes and prints events. `: publish <topic> <json>` publishes
with payload.

**`~` — Wit Management**

```
~ list
~ load logic
~ unload critic
~ inspect git
~ status
```

Wit lifecycle operations. `~` is Perl's home directory prefix — a
mnemonic for "system-level" operations.

Implementation: routes to `PluginManager` methods. `~ list` shows all
wits with state. `~ load` triggers `load_dir`. `~ unload` calls
`disable_wit`. `~ inspect` returns full metadata.

**`!` — History**

```
! 42
! -3
! last
```

Re-run a previous command by number. `!` is bash history expansion.

Implementation: store command history in an array. `! N` re-runs
command N. `! -N` re-runs N commands ago. `! last` re-runs the
last command.

### 1.4 LLM Tool Integration

The LLM can also use sigil modes in its tool calls. When the LLM
generates a tool call with a sigil-prefixed string, the harness
dispatches it the same way:

```perl
# LLM tool call:
$app->run_prompt('$ time()')            # dispatched as eval
$app->run_prompt('@ plan implement auth')  # dispatched as agent
$app->run_prompt('% code-review')         # dispatched as pipeline
```

This means the LLM can use the same interface the human uses.
The sigils become a shared vocabulary between human and AI.

---

## 2. Pipeline Format (Minsky Blueprints)

Pipelines are Minsky societies — networks of agents communicating
via the bus. They need a declarative, human-readable, LLM-generable
format.

### 2.1 Design Principles

- **Declarative** — describe agents and their topic connections, not execution steps
- **Topic-routed** — agents declare subscribe/publish topics; the Bus is the router
- **Composable** — pipelines can include other pipelines
- **Same grammar as Facade** — uppercase widgets, lowercase properties, LL(1)

### 2.2 Grammar

The pipeline format uses NExT grammar, parsed by `Data::NExT`

| First char | Meaning |
|------------|---------|
| Uppercase | Widget name, followed by `[` |
| Lowercase | Property name, followed by `(` |
| `#` | Comment (skip to end of line) |
| `]` | End of block |

No extensions. No `->` routing operators. No Perl `=>` syntax.
The Bus handles all wiring based on topic declarations.

### 2.3 Block Types

**Pipeline** — top-level container:

```
Pipeline[
  name("code-review")
  about("Review code changes with critic + git context")
  version("1.0")
]
```

**Source** — event source (entry point). Publishes to a topic:

```
Source[
  name("diff-source")
  topic("git.diff.ready")
]
```

**Agent** — processing node. Subscribes to input topics, publishes
to output topics:

```
Agent[
  name("critic")
  wit("logic")
  tool("critique_code")
  subscribe("git-context.output")
  publish("critic.output")
]
```

**Sink** — event sink (output). Subscribes to a topic and publishes
the final result:

```
Sink[
  name("review-sink")
  subscribe("quality-gate.output")
  topic("review.complete")
]
```

### 2.4 Full Example: Code Review Pipeline

```
# Code Review Pipeline
# Reviews git diffs through critic and git-context agents

Pipeline[
  name("code-review")
  about("Multi-agent code review with blame context")
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

Agent[
  name("quality-gate")
  wit("logic")
  tool("evaluate_rules")
  subscribe("critic.output")
  publish("quality-gate.output")
]

Sink[
  name("review-sink")
  subscribe("quality-gate.output")
  topic("review.complete")
]
```

### 2.5 Topic Flow

The wiring is implicit in the topic declarations. Trace the chain:

```
Source("diff-source") publishes to: git.diff.ready
  ↓
Agent("git-context") subscribes to: git.diff.ready
  publishes to: git-context.output
  ↓
Agent("critic") subscribes to: git-context.output
  publishes to: critic.output
  ↓
Agent("quality-gate") subscribes to: critic.output
  publishes to: quality-gate.output
  ↓
Sink("review-sink") subscribes to: quality-gate.output
  publishes to: review.complete
```

The Bus resolves the chain. No routing code needed — topic names
are the wiring.

### 2.6 Forking (Fan-Out)

Two agents subscribing to the same topic = fork. The Bus delivers
the event to both:

```
Agent[
  name("git-context")
  wit("git")
  tool("git_blame")
  subscribe("diff-source.output")
  publish("git-context.output")
]

Agent[
  name("db-context")
  wit("db")
  tool("query_schema")
  subscribe("diff-source.output")
  publish("db-context.output")
]
```

Both `git-context` and `db-context` receive the same event from
`diff-source.output`. They run in parallel on the Bus.

### 2.7 Merging (Fan-In)

One agent subscribing to multiple topics = merge. The agent receives
events from all subscribed topics:

```
Agent[
  name("merger")
  wit("logic")
  tool("merge_results")
  subscribe("git-context.output")
  subscribe("db-context.output")
  publish("merged.output")
]
```

The `merger` agent receives events from both `git-context` and
`db-context`. It decides how to combine them (wait for both, or
process each as it arrives).

### 2.8 Conditional Routing

A classifier agent publishes to different topics based on payload
content. Downstream agents subscribe to specific topics:

```
Agent[
  name("classifier")
  wit("logic")
  tool("classify_input")
  subscribe("input.ready")
  publish("input.git")
  publish("input.db")
  publish("input.generic")
]

Agent[
  name("git-review")
  wit("git")
  subscribe("input.git")
  publish("review.output")
]

Agent[
  name("db-review")
  wit("db")
  subscribe("input.db")
  publish("review.output")
]

Agent[
  name("generic-review")
  wit("critic")
  subscribe("input.generic")
  publish("review.output")
]
```

The classifier publishes to one of three topics. Only the matching
subscriber receives the event. The Bus handles the routing.

### 2.9 Composability

Pipelines can include other pipelines via `Include()`. Sub-pipelines
are just groups of agents with matching topic names:

```
Pipeline[
  name("full-review")
  about("Complete review: code + security + performance")
]

Include("code-review")
Include("security-audit")
Include("performance-check")
```

The included pipelines' agents subscribe and publish on the same Bus.
Topic names must match across pipelines for the wiring to connect.

### 2.10 Storage

Pipeline blueprints live in:

```
~/.clank/pipelines/           # user pipelines
.clank/pipelines/          # project pipelines
wits/*/pipelines/     # wit-shipped pipelines
```

File extension: `.clank`. The parser is the same LL(1) grammar as
facade blueprints — uppercase blocks, lowercase properties.

### 2.11 LLM-Generated Pipelines

The LLM can generate pipelines from natural language:

```
? create a pipeline that reviews git diffs and checks for security issues
```

The LLM responds with a pipeline blueprint. The user reviews it,
then runs it with `% security-review`. Or the LLM can run it
directly if the user approves.

Implementation: the LLM's response includes a blueprint in a code
block. The harness detects the code block, parses it, and offers
to save and execute it.

---

## 3. How It All Hooks Together

### 3.1 Connection Topology

```
User REPL
  +-- sigil dispatch -> commands/eval/agents/pipelines
  +-- capability manifest -> injected into LLM system prompt (see CONTEXT.md)
  +-- LLM tool calls -> ToolSelector -> wit handlers -> bus

Bus (pub/sub over SQLite)
  +-- wit handlers publish/subscribe topics
  +-- pipeline agents declare subscribe/publish topics
  +-- world model facts flow on bus

Wits (CPAN modules)
  +-- register tools -> LLM can call them
  +-- register commands -> REPL can dispatch them
  +-- register bus hooks -> participate in pipelines
  +-- # CLANK-WIT: comments -> manifest generation
```

### 3.2 Data Flow

1. User types `? how do I review code?`
2. Sigil `?` dispatches to query handler
3. Query handler sends to LLM with system prompt containing:
   - Core tools (always)
   - Capability manifest (always, see CONTEXT.md)
   - "This is an informational query" instruction
4. LLM sees `critic [analysis]` in manifest, responds with explanation
5. User types `% code-review`
6. Sigil `%` loads pipeline blueprint from `~/.clank/pipelines/code-review.clank`
7. Pipeline parser reads agent topic declarations
8. Bus wires subscribe/publish connections
9. Source publishes `git.diff.ready` event
10. Agents process as events arrive on their subscribed topics
11. Sink receives final result, prints to user

### 3.3 Shared Vocabulary

The sigils are the shared vocabulary between human and LLM:

- Human: `$ time()` — eval Perl
- LLM tool call: `$time()` — same dispatch
- Human: `% code-review` — run pipeline
- LLM tool call: `%security-audit` — same dispatch

The LLM learns sigils the same way humans do: by seeing them in
context. The system prompt includes the sigil table. The LLM uses
them in its tool calls. The REPL dispatches them uniformly.

---

## 4. Implementation Priority

### Phase 1: Capability Manifest (immediate)

- Add `PluginManager::manifest()` method
- Inject into `SystemPrompt` build
- Add `/wits inspect` command
- Cost: ~2 hours, zero risk

### Phase 2: Sigil Dispatch (next)

- Refactor `REPL.pm::_dispatch` to sigil hash
- Port existing `/command` to `'/''` handler
- Add `$` eval handler (most useful immediately)
- Add `?` query handler
- Cost: ~1 day, low risk (backward compatible)

### Phase 3: Pipeline Format (after)

- Define `.clank` file format spec (topic-based routing, see §2)
- Write parser (reuse facade grammar, no extensions)
- Wire Bus subscriptions from parsed topic declarations
- Add `%` and `>` handlers
- Cost: ~3 days, medium risk

### Phase 4: Two-Tier Injection (polish)

- Context-aware tool schema injection
- Bus hook on `context` topic
- ToolSelector deck-level scoring
- Cost: ~2 days, medium risk

---

## 5. Open Questions

1. **Sigil conflicts**: `$` is also Perl's scalar prefix. In the REPL
   there's no ambiguity (first char is the sigil), but in documentation
   and LLM prompts, `$` might be confused with Perl syntax. Mitigation:
   always show sigils at the start of a line, never embedded.

2. **Pipeline nesting depth**: How deep can `Include()` chains go?
   Practical limit: 5 levels. Deeper than that, the pipeline is
   probably poorly factored.

3. **Agent return format**: When an agent in a pipeline returns a
   result, what's the envelope? Suggested: `{topic, payload, meta}`
   matching the bus event format.

4. **Error propagation**: If an agent throws, does the pipeline halt
   or skip? Default: halt + report. The Bus could support a
   `pipeline.error` topic for error handling agents.

5. **State between runs**: Should pipelines be stateless (each run
   independent) or stateful (accumulate across runs)? Default:
   stateless. Stateful requires explicit `State[...]` block.
