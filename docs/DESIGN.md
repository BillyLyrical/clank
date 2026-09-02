# CLAM v2 — Design

A Perl AI coding harness modeled on Pi (earendil-works/pi-coding-agent).
Same loop semantics, same prompts, same tool behavior — rebuilt around a
SQLite-backed pub/sub blackboard as the architectural spine.

## 1. Philosophy

- The harness is a small, robust event loop + state manager.
- Core ships narrow: read, bash, edit, write (Pi's exact tools/prompts).
- All advanced behaviour lives in Wits (plugins), installed optionally
  OUTSIDE this tree (~/.clam/wits or .clam/wits).
- Plain Perl 5 (strict/warnings, bless OO). No Moo/Moose. Core deps:
  DBI + DBD::SQLite only; JSON::PP/HTTP::Tiny are core modules.

## 2. The Spine: Blackboard Bus

Everything communicates via Clam::Bus — a pub/sub broker persisted in
SQLite (table `events`). This is Minsky's blackboard: the LLM loop,
tools, Wits and logic agents all publish/subscribe topics; nothing calls
anything else directly.

Message protocol (one row per event):
  id            TEXT PK   (uuid)
  correlation_id TEXT     (parent task/event chain)
  topic         TEXT      (e.g. tool.call.bash, agent.turn_end)
  sender        TEXT      ("loop", "wit:datalog", "user", ...)
  payload       TEXT      (JSON)
  created_at    INTEGER   (unix ms)

Topics mirror Pi's extension events (see §5). Bus also supports
request/reply: publish task.<name> with correlation_id, wait for
result.<name> on same correlation (used by logic agents).

In-process dispatch is synchronous; every event is journaled to SQLite
first, so a crash mid-task can be inspected/resumed from the log.

## 3. Module Map (main tree)

    bin/clam                  CLI + Term::ReadLine REPL (no TUI)
    bin/clamd                 NDJSON daemon front-end for AI harnesses/scripts (docs/DRIVER.md)
    lib/Clam.pm               version, facade
    lib/Clam/Util.pm          uuid4, now_ms, json, truncate_head/tail, sizes
    lib/Clam/Store.pm         DBI/SQLite: sessions, messages(tree), events, kv, rag+FTS5
    lib/Clam/Bus.pm           pub/sub over Store; glob topics; request/reply
    lib/Clam/Messages.pm      user/assistant/toolResult/custom + to_llm()
    lib/Clam/SystemPrompt.pm  Pi's prompt, verbatim structure (clam-branded)
    lib/Clam/Provider.pm      provider base class (stream_chat iterator)
    lib/Clam/Provider/OpenAICompat.pm   SSE chat-completions client
    lib/Clam/Provider/LMStudio.pm       OpenAICompat @ localhost:1234/v1
    lib/Clam/Provider/Mock.pm           deterministic offline provider (tests/CI)
    lib/Clam/Driver.pm                  programmatic multi-query session wrapper (docs/DRIVER.md)
    lib/Clam/Providers.pm     registry + config/key resolution (§6)
    lib/Clam/LLM.pm           facade used by Loop (model, stream, complete)
    lib/Clam/Tool.pm          tool base class (schema + execute)
    lib/Clam/Tools/{Read,Bash,Edit,Write}.pm   Pi's tools, exact prompts
    lib/Clam/Tools.pm         registry: builtins + wit-registered
    lib/Clam/Session.pm       session tree over Store (new/resume/fork/leaf)
    lib/Clam/Loop.pm          agent loop = Pi runAgentLoop port (§4)
    lib/Clam/Wit.pm           plugin base class
    lib/Clam/WitAPI.pm        what Wits receive: on/register_tool/command/ui
    lib/Clam/PluginManager.pm discovery + load + error isolation
    lib/Clam/Skills.pm        SKILL.md discovery + prompt section (Pi-style)
    lib/Clam/Compaction.pm    threshold compaction (Pi semantics, §7)
    lib/Clam/REPL.pm          interactive loop, slash commands, streaming print
    lib/Clam/Logic/*.pm       Datalog engine (§8)

## 4. Agent Loop (port of pi agent-loop.ts runLoop)

prompt(text):
  emit input            -> Wits may transform/handle/block
  emit before_agent_start (may inject message / replace system prompt)
  emit agent_start
  loop:
    drain steering queue (messages queued while running)
    emit turn_start; emit context (Wits may rewrite messages[])
    stream assistant via LLM -> message_update events as deltas arrive
    for each toolCall in response:
      emit tool_call   -> Wits may block {block,reason} or mutate args
      execute tool (sequential mode v1)
      emit tool_result -> Wits may replace content/isError
      append toolResult message to session tree
    emit turn_end; check compaction threshold between turns
  until: no toolCalls and no steering/follow-up queued
  emit agent_end, agent_settled

Truncated-by-length assistant messages: all their tool calls are failed
with an error result (Pi behavior) — never execute half-args.

## 5. Plugin Hooks (full port of Pi's extension events)

A Wit is a Perl module with:
    package Clam::Wit::<Name>;
    sub new { ... }                 # optional, defaults to {}
    sub register { my ($self,$api)=@_; ... }   # receives WitAPI

$api surface (mirrors Pi ExtensionAPI):
  $api->on($event, \&handler)      # handler(event_hashref, ctx) -> result|undef
  $api->register_tool(%def)        # name/description/parameters/execute
  $api->register_command($name,%d) # /slash-command for the REPL
  $api->ui->{notify,input,confirm,select}   # readline-backed prompts
  $api->session / $api->store / $api->bus   # scoped access

Event set (topic = event name; handler results follow Pi semantics):
  startup:    session_start, resources_discover
  input:      input {continue|transform|handled}, user_bash (! prefix)
  agent:      before_agent_start (+systemPrompt replace), agent_start,
              agent_end, agent_settled
  turn:       turn_start, turn_end, context (rewrite messages[])
  provider:   before_provider_request (replace payload),
              after_provider_response (status/headers)
  message:    message_start, message_update, message_end (replace msg)
  tool:       tool_call (block/mutate args), tool_result (mutate result),
              tool_execution_start/update/end (observe)
  session:    session_before_switch/fork/compact/tree (cancel),
              session_compact(_failed), session_shutdown,
              session_info_changed
  model:      model_select, thinking_level_select

Dispatch rules (from pi runner.ts):
- handlers run in registration order; each sees earlier mutations
- tool_call: first {block=>1} wins -> error result to LLM
- context/message_end/tool_result: results applied sequentially
- before_agent_start systemPrompt: chained across Wits
- a throwing handler is caught, logged to events (topic wit.error),
  and skipped — one broken Wit never kills the loop

## 6. Provider Management

Resolution order for active model: CLI --provider/--model > env
(CLAM_PROVIDER, CLAM_MODEL, CLAM_BASE_URL) > ~/.clam/config.json >
default (lmstudio). API keys NEVER stored in SQLite or logs:
- env var indirection: config "api_key": "$MY_KEY" expands at use time
- optional ~/.clam/keys.json (chmod 600) for named key refs
- LM Studio needs no key (local); default base_url http://localhost:1234/v1

Provider interface: stream_chat({model,system,messages,tools}) ->
iterator of {type=>start|text_delta|toolcall_delta|done,...};
complete(...) non-streaming; models() listing. New providers = new
subclass + register in Providers.pm (or via Wit api->register_provider).

## 7. Compaction (Pi semantics)

Trigger: est_tokens(context) > context_window - reserve (default 16384).
Check points: between turns inside a run, before new user prompt.
Method: walk back from newest accumulating ~tokens until keep_recent
(default 20k); summarize older span with LLM into structured summary
(goal, decisions, files touched, open threads); store as compaction
entry in session tree; next context = [summary] + kept messages.
Manual: /compact [instructions]. Wits may cancel/customize via
session_before_compact.

## 8. Datalog Engine (maximally modular)

Pure Perl, no deps. One concern per module:
  Clam::Logic::Term         term model; resolve_var($term,$env)
  Clam::Logic::Unify        unify($t1,$t2,$env) -> env|undef
                            (atoms, ?vars, nested lists; occurs check)
  Clam::Logic::Solver       prove_first_match($goals,$kb,$env)
                            prove_all(...) lazy iterator; depth limit
  Clam::Logic::KnowledgeBase facts+rules store, indexed by pred/arity,
                            add_fact/add_rule/clear
  Clam::Logic::Parser       recursive-descent parser for:
                              parent(alice,bob).
                              gp(X,Y) :- parent(X,Z), parent(Z,Y).
  Clam::Logic               facade: parse($text)->kb; query($kb,$goal)
Wit layer (separate tree): wit `datalog` exposes tool `logic_query`
and bus agent on task.query_logic -> result.query_logic.

## 9. Wits Ecosystem (optional installs, separate tree)

Repo: ~/dev/clam-wits — NOT part of this tree. Layout per wit:
    <wit>/lib/Clam/Wit/<Name>.pm   (or single .pm for tiny wits)
    <wit>/README.md  [t/]
Install: `clam wits install <dir|git-url>` -> ~/.clam/wits/<name>
(uninstall/list/info subcommands). Discovery at startup:
  1. CLAM_WITS_PATH (colon list)   2. .clam/wits/ (project)
  3. ~/.clam/wits/ (user)          4. -w/--wit CLI flags
A broken wit fails to load with a warning; the harness still runs.

Planned wits: datalog, rag (FTS5 index+search+context injection),
git_guardrails (tool_call blocker for dangerous commands),
perl_eval (Safe-compartment code execution), wisdom/perl_style
(context injectors), hello (example).
