# Clank::REPL::Help — rich online help for the interactive REPL.
# Every topic is self-contained text. /help lists topics, /help <topic> shows detail.
package Clank::REPL::Help;
use strict;
use warnings;

# All help topics. Each key is a topic name, value is { summary, body }.
# summary = one-liner for the overview listing.
# body    = multi-line help text.
my %TOPICS;

# --- build topic table at compile time --------------------------------------
%TOPICS = (
    overview => _topic('overview',
        'Quick reference for all sigils and commands',
        _overview_body()),

    'sigil:/' => _topic('sigil:/',
        'Slash commands — /help, /new, /sessions, /resume, /compact, /exit',
        <<'EOF'),
Slash commands manage the REPL session and inspect state.

  /help            list all commands (this)
  /help <topic>    show detailed help for a topic
  /new             start a new session (clears conversation)
  /sessions        list recent sessions (15 most recent)
  /resume <id>     resume a previous session by id prefix
  /compact [text]  summarize conversation to save context
  /tools           list LLM tools available in this session
  /model           show active provider and model
  /events [topic]  peek at the bus event journal
  /stats           show self-improvement metrics
  /agents          list available agent profiles
  /wits            list all discovered wits (from DB)
  /memory          knowledge document management
  /instinct        crystallized rule management
  /exit            leave the REPL

Wits can register additional /commands. Type /help to see them all.
EOF

    'sigil:?' => _topic('sigil:?',
        'Query — ask the LLM a question without triggering tool use',
        <<'EOF'),
  ? <question>

Sends the question to the LLM with a "no tools" instruction. Use this
when you want information, not action.

  ? what is the Datalog engine?
  ? how does crystallization work?
  ? explain the escalation system

For action-oriented prompts (fix a bug, write code, run a command),
use bare text instead (no sigil).
EOF

    'sigil:$' => _topic('sigil:$',
        'Eval — execute Perl expressions in the harness context',
        <<'EOF'),
  $ <perl expression>

Runs the expression with access to internal harness objects:

  $store     — Clank::Store (SQLite)
  $bus       — Clank::Bus (pub/sub)
  $session   — Clank::Session (current)

Examples:

  $ time()
  1725847321

  $ use Clank::Util; uuid4()
  a3f1b2c4-d5e6-7f89-0a1b-2c3d4e5f6a7b

  $ $store->kv_get('last_session')
  {session_id => "a3f1b2c4...", turns => 5}

  $ scalar @{ $store->list_sessions(limit => 5) }
  5

Errors are caught and displayed. The expression runs in a sandboxed eval.
EOF

    'sigil:@' => _topic('sigil:@',
        'Agent — dispatch constrained subagents',
        <<'EOF'),
  @list                   list available agent profiles
  @status                 show invocation stats
  @<name> <prompt>        run an agent with a prompt

Agents are constrained subagents with focused prompts and tool allowlists.
Each agent has a specific role (review, debug, plan, etc.) and can only
use its allowed tools.

Built-in agents:

  @reviewer    Code review, evidence-based critique     (tools: bash, read)
  @debugger    Diagnose and fix bugs                     (tools: bash, edit, read)
  @planner     Task decomposition, dependency ordering   (tools: bash, read)
  @security    Vulnerability scanning, OWASP review      (tools: bash, read)
  @architect   Design review, architecture validation    (tools: bash, read)

Examples:

  @reviewer review lib/Clank/WorldModel.pm
  @debugger fix the SQL injection at WorldModel.pm:142
  @security scan lib/ for hardcoded secrets

Agents publish lifecycle events on the bus (pre_agent_start, agent_end, etc.)
which wits can subscribe to for quality gates and coordination.
EOF

    'sigil:%' => _topic('sigil:%',
        'Pipeline — run declarative multi-agent networks',
        <<'EOF'),
  % list                  list available pipeline blueprints
  % <name>                run a named pipeline

Pipelines are declarative multi-agent workflows defined in .clank blueprint
files. They chain agents via the event bus — each agent subscribes to input
topics and publishes to output topics.

Blueprint locations: .clank/pipelines/ or ~/.clank/pipelines/

Example blueprint (code-review.clank):

  Pipeline[
    name("code-review")
    about("Multi-agent code review with blame context")
  ]
  Source[ name("diff") topic("git.diff.ready") ]
  Agent[ name("critic") wit("critic") tool("critique_code")
         subscribe("git.diff.ready") publish("critic.output") ]
  Sink[ name("out") subscribe("critic.output") topic("review.done") ]

Run it:

  % code-review
EOF

    'sigil:>' => _topic('sigil:>',
        'Pipe — inline pipeline construction (chained LLM calls)',
        <<'EOF'),
  > stage1 | stage2 | stage3

Chains LLM calls without blueprint files. Output of each stage feeds the
next. Simple text transformation pipeline.

Examples:

  > summarize lib/Clank.pm | find issues | prioritize
  > diff HEAD~1 | classify changes | suggest review focus

Each stage sends the previous output back to the LLM with a new instruction.
EOF

    'sigil::' => _topic('sigil::',
        'Topic — publish/subscribe to bus events',
        <<'EOF'),
  : <topic>                       publish an empty event to a topic
  : listen <topic>                show recent events on a topic
  : publish <topic> <json>        publish a JSON payload to a topic

The bus is the spine of Clank. Everything communicates through topics:
wits subscribe to events, agents publish results, tools emit activity.

Useful topics to listen on:

  tool_execution_start    when a tool begins executing
  tool_execution_end      when a tool finishes
  session_start           new session created
  session_shutdown        session ending
  agent_end               agent completed
  wit.error               wit handler threw an error

Examples:

  : listen tool_execution_start
  : publish review.complete {"score": 85}
  : git.commit.done
EOF

    'sigil:~' => _topic('sigil:~',
        'Wit — discover, load, inspect, and manage wits',
        <<'EOF'),
  ~ list                    list all discovered wits (DB registry)
  ~ status                  count of active vs available wits
  ~ inspect <name>          show details for a specific wit
  ~ load <directory>        load wits from a directory at runtime
  ~ unload <name>           disable a loaded wit

Wits are CPAN modules that extend Clank with tools, commands, and bus hooks.
On startup, Clank scans @INC for # CLANK-WIT: markers and registers all
found wits in the SQLite DB.

States:
  active    — loaded and running (tools + commands available)
  available — discovered but not loaded
  disabled  — manually unloaded (can re-enable)

Examples:

  ~ list                     # see all 153+ wits
  ~ inspect git              # show git wit details
  ~ load /path/to/custom     # load a wit from disk
  ~ unload critic            # disable the critic wit

From the shell, you can also discover wits:

  grep -rh "# CLANK-WIT:" $(perl -e 'print join ":", @INC')/Clank/Wits/*.pm
EOF

    'sigil:!' => _topic('sigil:!',
        'History — re-run previous commands',
        <<'EOF'),
  !           re-run the last command
  ! <N>       re-run command N (1-indexed)
  ! -N        re-run N commands ago
  ! last      re-run the last command (same as bare !)

The command is re-dispatched through the sigil system, so ! works with
any sigil.

Examples:

  !         # re-run last command
  ! 3       # re-run command #3
  ! -2      # re-run 2 commands ago
EOF

    'sigil:#' => _topic('sigil:#',
        'Comment — annotation, ignored by the REPL',
        <<'EOF'),
  # <text>

Lines starting with # are silently ignored. Use them to annotate your
session with notes, phase markers, or reminders.

  # Phase 1: understand the codebase
  what does WorldModel.pm do?

  # Phase 2: find issues
  @reviewer review lib/Clank/WorldModel.pm
EOF

    'sigil:text' => _topic('sigil:text',
        'Bare text — send directly to the LLM (action mode)',
        <<'EOF'),
  <any text without a sigil>

Bare text goes straight to the LLM as a prompt. The LLM has access to
all loaded tools and can read files, run bash commands, edit code, etc.

  fix the bug in Foo.pm
  list the files in the current directory
  explain what this function does

This is the primary way to interact with Clank for coding tasks.
For questions without tool use, prefix with ? instead.
EOF

    agents => _topic('agents',
        'Agent profiles — constrained subagents with focused roles',
        <<'EOF'),
Agents are named profiles that constrain how a subagent runs. Instead of
passing a raw prompt to the LLM, an agent profile specifies:

  - Which tools the agent can use (allowlist)
  - Which model tier to use (cost control)
  - What prompt shapes the behavior
  - How many turns before forced termination

Built-in agents:

  Name          Tools             Purpose
  ----          -----             -------
  architect     bash, read        Design review, architecture validation
  debugger      bash, edit, read  Diagnose and fix bugs (can edit files)
  planner       bash, read        Task decomposition, dependency ordering
  reviewer      bash, read        Code review, evidence-based critique
  security      bash, read        Vulnerability scanning, OWASP review

Usage:

  @list                  list available agents
  @status                show invocation stats per agent
  @reviewer <prompt>     run the reviewer agent
  @debugger <prompt>     run the debugger agent

Creating custom agents: create TOML + Markdown files in agents/

  my_agent.toml          metadata (name, description, tools, model)
  my_agent.md            system prompt instructions

Agent profiles are self-documenting — each has a description field used
for automatic routing. The @list command shows all profiles with their
descriptions and allowed tools.
EOF

    pipelines => _topic('pipelines',
        'Pipeline system — declarative multi-agent workflows',
        <<'EOF'),
Pipelines chain agents via the event bus. Each agent subscribes to input
topics and publishes to output topics. Blueprints define the graph.

Blueprint syntax:

  Pipeline[ name("code-review") about("Multi-agent code review") ]
  Source[ name("diff") topic("git.diff.ready") ]
  Agent[ name("critic") wit("critic") tool("critique_code")
         subscribe("git.diff.ready") publish("critic.output") ]
  Sink[ name("out") subscribe("critic.output") topic("review.done") ]

Built-in blueprints: see .clank/pipelines/ or ~/.clank/pipelines/

Inline pipes (no blueprint needed):

  > summarize lib/Clank.pm | find issues | prioritize

See also: sigil:% for running pipelines, sigil:> for inline pipes.
EOF

    wits => _topic('wits',
        'Wit system — CPAN modules that extend Clank',
        <<'EOF'),
Wits are CPAN modules in the Clank::Wits::* namespace that extend Clank
with tools, REPL commands, and bus event hooks.

Each wit has:
  - A # CLANK-WIT: comment block with metadata (name, about, hint)
  - A register($api) method for runtime integration

Discovery: On startup, Clank scans @INC for # CLANK-WIT: markers.
All found wits are registered in the SQLite DB.

Listing wits:

  ~ list            all discovered wits (active + available)
  ~ status          count summary
  ~ inspect <name>  details for a specific wit

Shell discovery:

  grep -rh "# CLANK-WIT:" $(perl -e 'print join ":", @INC')/Clank/Wits/*.pm
  grep -h "# CLANK-WIT:.*about=" $(perl -e 'print join ":", @INC')/Clank/Wits/*.pm

Creating a wit: see docs/WITS.md for the full spec. Quick start:

  # CLANK-WIT: name=Foo
  # CLANK-WIT: about=Does something useful
  # CLANK-WIT: hint=keywords for tool selection
  package Clank::Wits::Foo;
  sub register { my ($self, $api) = @_; ... }
  1;
EOF

    config => _topic('config',
        'Configuration — providers, API keys, data directories',
        <<'EOF'),
Clank uses layered configuration:

  CLI flags  >  env vars  >  .clank/config.json  >  defaults

Data directory precedence:

  --local      force project-local .clank/
  (default)    ./ .clank/ if it exists, else ~/.clank/
  --home       force user-global ~/.clank/

Config file (.clank/config.json):

  {
    "provider": "openai",
    "model": "gpt-4o",
    "api_key": "sk-..."
  }

Environment variables:

  CLANK_PROVIDER    provider name
  CLANK_MODEL       model identifier
  CLANK_BASE_URL    API endpoint
  CLANK_API_KEY     authentication key

Testing connection:

  clank providers        show active config and known providers
  clank providers test   probe the endpoint for available models

See docs/LLM_SETUP.md for full provider documentation.
EOF

    neurosymbolic => _topic('neurosymbolic',
        'Neurosymbolic features — world model, crystallizer, escalation',
        <<'EOF'),
Clank combines LLM pattern recognition with symbolic reasoning:

World Model — entities, relations, temporal facts, causal links, and
beliefs stored in SQLite. Queryable via Datalog rules.

Crystallizer — LLM solutions captured as deterministic Perl rules.
Gets cheaper with use: rules execute in ~1ms vs LLM calls at ~500ms.

NeuroIntegration — bidirectional bridge between LLM and world model.
Injects context into prompts, validates LLM output, extracts knowledge.

Escalation — cheapest correct tool first:
  1. Crystallized rules (~1ms)
  2. World model queries (~5ms)
  3. Rules engine (~10ms)
  4. LLM fallback (~500ms)

Inspecting:

  /stats           self-improvement metrics and escalation counts
  /instinct        crystallized rule management
  $ $store->...    direct SQLite queries on the world model

See docs/ROADMAP.md for the full architecture and vision.
EOF

    session => _topic('session',
        'Session management — new, resume, compact',
        <<'EOF'),
Sessions persist conversations in the SQLite database. Each session has
a unique ID and tracks all messages, tool calls, and LLM responses.

  /new             start a fresh session
  /sessions        list 15 most recent sessions
  /resume <id>     resume by ID prefix (first 8 chars)
  /compact [text]  summarize conversation to save context

Compaction summarizes older messages into a compact form, freeing context
window space. Optional text keeps specific topics in focus.

  /compact keep the auth middleware discussion

The banner shows the current session ID on startup:

  db: ~/.clank/clank.db | session: abd970ab-...

Each session records its working directory, provider, and model for
reproducibility.
EOF

    editor => _topic('editor',
        'Editor integration — multi-line input from $EDITOR',
        <<'EOF'),
For long prompts or complex input, open your editor from the clank> prompt:

  Alt+E             open $EDITOR (works with any readline)
  Ctrl+X Ctrl+E     open $EDITOR (GNU Readline specific)

How it works:
  1. A temp file is created and opened in your editor
  2. Write your input, save, and exit
  3. The content is sent to the REPL as if you typed it
  4. Cancel the editor (exit non-zero) and input is discarded

Falls back: $EDITOR -> $VISUAL -> vi

Useful for:
  - Long multi-line prompts
  - Complex Perl eval expressions ($ ...)
  - Editing pipeline blueprints before running them
EOF
);

# --- public API --------------------------------------------------------------

sub topic_names { sort keys %TOPICS }

sub get_topic {
    my ($class, $name) = @_;
    return $TOPICS{$name} if exists $TOPICS{$name};
    # fuzzy match: try partial match
    my @matches = grep { /\Q$name\E/i } keys %TOPICS;
    return $TOPICS{$matches[0]} if @matches == 1;
    return undef;
}

sub overview {
    my ($class) = @_;
    return $TOPICS{overview}{body};
}

sub render_topic {
    my ($class, $name) = @_;
    my $t = $class->get_topic($name);
    return undef unless $t;
    return $t->{body};
}

# List topics matching a prefix or keyword (for tab completion hints).
sub search_topics {
    my ($class, $q) = @_;
    $q //= '';
    return sort keys %TOPICS unless length $q;
    return sort grep { /\Q$q\E/i } keys %TOPICS;
}

# --- internals ---------------------------------------------------------------

sub _topic {
    my ($name, $summary, $body) = @_;
    return { name => $name, summary => $summary, body => $body };
}

sub _overview_body {
    my $out = <<'EOF';
Clank REPL — type a sigil + text, or bare text for the LLM.

Sigils:

  / <command>     slash commands (help, new, sessions, compact, ...)
  ? <question>    query the LLM (no tools, informational)
  $ <expr>        execute Perl in harness context
  @ <agent>       run a constrained subagent
  % <pipeline>    run a named pipeline
  > s1 | s2       inline pipe (chained LLM calls)
  : <topic>       publish/subscribe to bus events
  ~ <wit>         wit lifecycle (list, inspect, load, unload)
  !               re-run previous command
  #               comment (ignored)
  (bare text)     send to the LLM (action mode)

Commands:

  /help           show this overview
  /help <topic>   detailed help (try: /help agents, /help wits)
  /new            new session          /compact        summarize
  /sessions       list sessions        /resume <id>    resume session
  /tools          list LLM tools       /model          show provider
  /events [topic] bus journal          /stats          metrics
  /agents         list agent profiles  /wits           list wits

Editor: Alt+E or Ctrl+X Ctrl+E opens $EDITOR for multi-line input.
EOF
    return $out;
}

1;
