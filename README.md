# Clank

**A Perl AI coding harness for experienced unix-perl greybeards.**

LLMs are fat-fingered geniuses.
Logic engines are idiot savants.
Clank bridges them.

---

## What Clank Is

Clank is a neurosymbolic AI harness that combines LLM pattern recognition
with explicit world models, symbolic reasoning, and deterministic rules.
Entities, relations, temporal facts, causal links, and beliefs live in a
shared SQLite blackboard. Datalog, FSMs, behavior trees, and SAT solvers
reason over that world model. LLMs generate and critique. The bus
coordinates everything.

Perl is the backbone because LLMs can read, write, and extend Perl code
natively. The harness can modify itself. That's the thesis, and the
working codebase proves it.

## What's in the Box

### Core Harness

- Agent loop (ported from Pi) with 4 tools: read, bash, edit, write
- SQLite store + pub/sub bus (Minsky blackboard)
- 7 LLM providers: LMStudio, Ollama, OpenAI, Anthropic, Gemini, Azure, Mock
- Sigil-based REPL: `/commands`, `?queries`, `$eval`, `@agents`, `%pipelines`, `>pipes`, `:topics`, `~wits`, `!history`
- Daemon mode (`clankd`) with NDJSON protocol for programmatic access
- Context engineering: capability manifest, RATS tool selection, knowledge bus, compression

### 141 Curated Wits (14 decks)

| Deck | Count | Purpose |
|------|-------|---------|
| logic | 51 | Datalog engine, rules DSL, FSM, behavior trees, SAT |
| critic | 12 | Code critique heuristics |
| git | 10 | Git operations (status, log, diff, blame, ...) |
| fs | 12 | Filesystem operations |
| db | 8 | Database shell (connect, query, execute, schema, ...) |
| perl | 16 | Perl development (syntax, review, POD, tests) |
| psh | 3 | Perl Shell REPL |
| search | 9 | Local + web search |
| embedding | 1 | Semantic search via embeddings |
| neuro | 3 | World model, crystallizer, constraints |
| web | 4 | HTTP requests (fetch, post, put, delete) |
| build | 4 | Build systems (make, perl build, cpanm, test) |
| devops | 4 | Docker + systemd |
| debug | 4 | Debugging tools (stacktrace, strace, lsof, pstack) |

### Neurosymbolic Features

- **World Model** — entities, relations, temporal facts, causal links, beliefs in SQLite
- **Crystallizer** — LLM solutions captured as deterministic Perl rules (gets cheaper with use)
- **NeuroIntegration** — bidirectional LLM <-> world model (inject context, validate output, extract knowledge)
- **Escalation** — cheapest correct tool first: rules engine -> world model -> crystallized rules -> LLM
- **Agent System** — constrained subagents (reviewer, debugger, planner, security, architect)
- **Pipeline System** — declarative multi-agent networks via `.clank` blueprint files

### 1450 Tests, All Offline

```
prove -l t/
```

## Quick Start

```bash
# LM Studio (local, default):
clank

# Ollama:
CLANK_PROVIDER=ollama CLANK_MODEL=codellama clank

# OpenAI:
CLANK_PROVIDER=openai CLANK_MODEL=gpt-4o clank

# Anthropic:
CLANK_PROVIDER=anthropic CLANK_MODEL=claude-sonnet-4-20250514 clank

# Daemon mode (NDJSON protocol):
clankd --stdio --provider lmstudio --model qwen3.8-27b

# Programmatic (in-process):
perl -Ilib -e '
  use Clank::Driver;
  my $d = Clank::Driver->new(provider=>"ollama", model=>"codellama");
  $d->start;
  my $r = $d->ask("list the files in the current directory");
  print $r->{response};
  $d->close;
'
```

## The Sigil System

Every line starts with a sigil that determines how it's handled:

| Sigil | Mode | Example |
|-------|------|---------|
| `/` | Command | `/help`, `/new`, `/compact` |
| `?` | Query | `? what is Datalog?` |
| `$` | Eval | `$ time()` |
| `@` | Agent | `@reviewer review lib/Foo.pm` |
| `%` | Pipeline | `% code-review` |
| `>` | Pipe | `> summarize \| classify \| critique` |
| `:` | Topic | `: listen tool.call` |
| `~` | Wit | `~ list`, `~ load path/to/wit` |
| `!` | History | `! 42` |
| `#` | Comment | `# ignored` |
| *(none)* | LLM | `fix the bug in Foo.pm` |

## Agents

Constrained subagents with focused prompts and tool allowlists:

```
clank> @list
  architect   Design review, architecture validation  (tools: bash,read)
  debugger    Diagnose and fix bugs (can edit)        (tools: bash,edit,read)
  planner     Task decomposition, dependency ordering  (tools: bash,read)
  reviewer    Code review, evidence-based critique     (tools: bash,read)
  security    Vulnerability scanning, OWASP review     (tools: bash,read)

clank> @reviewer review lib/Clank/WorldModel.pm
[reviewer] turns: 3
## Review: lib/Clank/WorldModel.pm
[critical] WorldModel.pm:142 — SQL injection in query_entities()
...
```

## Pipelines

Declarative multi-agent networks communicating via the event bus:

```
Pipeline[
  name("code-review")
  about("Multi-agent code review")
]
Source[ name("diff") topic("git.diff.ready") ]
Agent[ name("critic") wit("critic") tool("critique_code")
       subscribe("git.diff.ready") publish("critic.output") ]
Sink[ name("out") subscribe("critic.output") topic("review.done") ]
```

Or inline pipes:

```
clank> > diff HEAD~1 | classify | critique
```

## REPL Commands

```
/help          list all commands
/new           start a new session
/sessions      list recent sessions
/resume <id>   resume a previous session
/compact       summarize conversation to save context
/tools         list available LLM tools
/model         show active provider/model
/events        peek at bus journal
/stats         self-improvement metrics
/agents        list agent profiles
/memory        knowledge document management
/instinct      crystallized rule management
/exit          leave the REPL
```

Editor integration: **Alt+E** or **Ctrl+X Ctrl+E** opens `$EDITOR` for
multi-line input.

## Development

```bash
git clone git@psycho:~/clank.git
cd clank
perl link_wits.pl        # symlink wits/ into lib/
prove -l t/              # run all tests (1450)
prove -l wits/*/t/       # run wit tests
```

`link_wits.pl` creates relative symlinks from `lib/Clank/Wits/*` to each
wit's `lib/` directory. The symlinks are gitignored.

## Dependencies

Core (only non-core deps):

- `DBI`
- `DBD::SQLite`

Everything else is core Perl (5.020+). Install with:

```bash
cpanm --installdeps .
```

Or for development:

```bash
cpanm --installdeps --with-develop .
```

## Architecture

```
User / CLI / Daemon
       |
   Clank::App
   |    |    |
 Store  Bus  Provider
       |
   Clank::Loop (agent loop)
       |
    Wits (plugins)
```

- **Store** — single source of truth (SQLite)
- **Bus** — spine (pub/sub over Store, everything talks through topics)
- **Loop** — agent loop (Pi port, prompt -> tools -> LLM -> repeat)
- **Wits** — extension surface (tools + commands + bus hooks)

Read `docs/ROADMAP.md` for the full architecture and vision.
Read `docs/REPL_GUIDE.md` for the interactive guide.
Read `docs/Wits.md` for the wit system design.
Read `docs/DRIVER.md` for the programmatic API.
Read `docs/CONTEXT.md` for the context engineering system.

## License

Artistic License 2.0
