# Clam Driver & clamd — programmatic sessions for AI harnesses and scripts

Two layers on top of `AI::Clam::App` for driving **complex multi-query Clam
sessions** from outside:

| Layer | What it is | For whom |
|---|---|---|
| `AI::Clam::Driver` (lib/AI/Clam/Driver.pm) | In-process OO wrapper: one session, structured results per prompt, full event capture | Perl code, tests, other harnesses in the same process |
| `clamd` (bin/clamd) | NDJSON front-end over stdio or a Unix socket; one long-lived daemon process | Any language via pipes/sockets; AI harnesses supervising Clam |

Both are thin: all session state lives in the SQLite store, so sessions can be
resumed across processes and restarts.

---

## 1. AI::Clam::Driver (in-process)

```perl
use AI::Clam::Driver;

my $d = AI::Clam::Driver->new(
    provider => 'lmstudio',          # registry name ... or a ready-made object
    base_url => 'http://192.168.1.12:1234/v1',
    model    => 'qwen3.8-27b',
    db       => ':memory:',          # or a file path for resumable sessions
    wit_paths => ['decks/git'],      # optional extra wit dirs (deck-aware)
    events   => 1,                   # per-turn event capture (default on)
    timeout  => 0,                   # default ask() timeout in seconds (0 = none)
);

$d->start;                           # or start(resume => $session_id)
my $r1 = $d->ask('read the README and summarize it');
my $r2 = $d->ask('now write a one-line changelog entry for that summary');
# ... r2's provider payload already contains r1's full exchange ...
$d->close;                           # idempotent; also runs from DESTROY
```

### Constructor options (`new`)

Pass-through to `AI::Clam::App`: `db`, `provider` (name **or object** — objects are
how tests inject scripted providers), `model`, `base_url`, `api_key`, `stream`,
`wit_paths`, `compact`, plus driver-only: `workdir` (chdir before start),
`events` (1/0, default 1), `timeout` (default per-ask timeout, seconds).

### `start(%session_opts)`

Builds the App and starts a session. Pass `resume => $id` to continue an
earlier session from the same db file. Dies if already started.

### `ask($text, %opts)` — the core call

Runs one full prompt (any number of provider turns / tool calls) and returns a
**structured result hashref**. Never dies for ordinary failures:

```perl
{
    ok             => 1,        # 0 on error/timeout
    error          => undef,    # message when !ok
    timed_out      => 0,        # 1 when the driver-level timeout fired
    handled        => 0,        # 1 when an 'input' hook short-circuited
    output         => undef,    # hook-provided output when handled
    response       => "final assistant text",   # from the leaf message
    turns          => 3,        # provider round-trips this prompt took
    tools          => [ { id, name, input, isError }, ... ],  # execution order
    events         => [ { topic, sender, payload }, ... ],    # dispatch order
    messages_added => 5,        # session message-count delta for this turn
}
```

`timeout => N` overrides the default for one call. Sub-second values work
(`Time::HiRes::ualarm` under the hood). A timeout leaves the session usable —
the next `ask()` proceeds from the current chain.

### Introspection

| Method | Returns |
|---|---|
| `$d->messages(limit => N)` | arrayref of the last N messages (oldest→newest) |
| `$d->events(topic => 'tool_*', limit => N)` | arrayref of journal rows `{id, correlation_id, topic, sender, payload, created_at}` with **decoded** payloads |
| `$d->tool_names` | list of tool names available to the model |
| `$d->wit_names` | list of loaded declarative wit names (aliases collapsed) |
| `$d->skipped_wits` / `$d->load_errors` | arrayrefs from the PluginManager |
| `$d->info()` | compact summary: session_id, message count, tools, wits, skipped, provider `log_safe` string |

Accessors: `app`, `store`, `bus`, `session`, `provider`, `session_id`,
`started`. The bus is exposed so callers can subscribe their own hooks (input
interception, tool_call vetoing, context rewriting) exactly as wits do.

### Topic glob conventions

The same matcher as bus subscriptions (`AI::Clam::Bus::topic_matches`):
`.` separates segments, `*` matches within one segment. Lifecycle topics use
underscores — match them with e.g. `tool_*`, `agent_*`; wit-defined topics use
dots — `search.*`. SQLite `LIKE` cannot express these patterns, so journal
queries filter in Perl (fetch a wider window first).

---

## 2. clamd — NDJSON front-end

One request per line on stdin, one response per line on stdout. Every response
echoes the request's `id`. **stdout carries protocol lines only**; all
diagnostics go to stderr.

```
$ perl bin/clamd --stdio --provider lmstudio \
      --base_url http://192.168.1.12:1234/v1 --model qwen3.8-27b
{"id":1,"command":"ping"}
→ {"id":1,"ok":1,"pong":1}

{"id":2,"prompt":"hello","timeout":60}
→ {"events":[...],"id":2,"messages_added":2,"ok":1,"response":"...",
   "tools":[...],"turns":1,...}          # full ask() result + id

{"id":3,"command":"session_info"}
→ {"id":3,"ok":1,"session_id":"...","messages":4,"tools":[...],
   "wits":[...],"skipped_wits":[...],"provider":"provider=lmstudio ..."}

{"id":4,"command":"events","topic":"tool_*","limit":50}
→ {"events":[{...journal rows...}],"id":4,"ok":1}

{"id":5,"command":"tools"}
→ {"id":5,"ok":1,"tools":["bash","edit","read","write"],"wits":[...],
   "skipped_wits":[...]}

{"id":6,"command":"shutdown"}
→ {"bye":1,"id":6,"ok":1}                # then the process exits 0
```

### Commands

| Command | Fields | Notes |
|---|---|---|
| `ping` | — | liveness probe |
| `prompt` (alias `input`) | `prompt`, optional `timeout` | runs a full multi-turn prompt; response is the driver's ask() result with `id` added |
| `session_info` | — | compact session summary |
| `events` | optional `topic` glob, `limit` (default 200) | journal query across the whole session |
| `tools` | — | builtin tools + loaded wits + skipped wits |
| `shutdown` | — | ack line, then clean exit |

Protocol errors are reported, not fatal: invalid JSON → `{"ok":0,"error":"invalid JSON"}`;
unknown command → `{"id":N,"ok":0,"error":"unknown command '...'}`. A response
that cannot be JSON-serialized degrades to an explicit error line instead of
killing the loop.

### Options

`--provider --model --base_url --api_key --db --workdir --resume ID
--timeout N --wit DIR (repeatable) --socket PATH | --stdio`. Stdio is the
default transport; `--socket` runs a select-loop server on a Unix socket
(chmod 0600, stale sockets unlinked at start and exit).

### Teardown guarantees (the zombie fix)

The old clam-sock leaked zombies because nothing owned its lifecycle. clamd:

1. **stdio**: the parent's pipe *is* the lifecycle — EOF on stdin (parent
   closed or died) exits cleanly with code 0. No shutdown command needed.
2. **signals**: SIGTERM/SIGINT trigger the same cleanup path.
3. **socket mode**: `shutdown` command, or socket unlink + exit; the socket
   file is removed on every exit path (END-guarded).

`t/09_driver.t` regression-tests both EOF teardown and shutdown teardown with
alarm-bounded `waitpid`.

---

## 3. Design notes & caveats

- **Why stdio by default.** A pipe gives the parent total lifecycle control
  for free (close → child exits), works over SSH, needs no filesystem or
  permissions, and is trivially testable with `IPC::Open2/3`. The socket mode
  exists for multi-client daemons; it is strictly more failure surface.
- **No live event streaming in v1.** Events are batched into each prompt's
  response (dispatch order) plus queryable via the journal (`events` command /
  `Driver::events`). One-response-per-request keeps the protocol dead simple;
  a streaming mode is a natural extension if a consumer needs it.
- **Timeouts are best-effort.** The driver sets an alarm around the whole
  prompt (same pattern as wit timeouts). A wit or provider that installs its
  own timer mid-turn replaces it — the timeout then protects only until that
  point. Sub-second precision requires `Time::HiRes` (core `alarm()` truncates
  to whole seconds, which silently disables fractional timeouts). The timeout
  die is caught inside the loop's provider-call eval and surfaces as a normal
  `{ok=>0,error}` result — the driver detects both shapes and sets
  `timed_out`.
- **Event capture must return undef.** Per-turn capture subscribes to `*` on
  the bus; `publish()` gathers *defined* handler results as hook responses, so
  a collector that returned a hashref could be misread by input/tool_call/
  message_end hooks.
- **IPC::Open3 landmine (for test authors).** Its DESCRIPTION says
  `(read, write, other)` but the actual argument order is
  **(write-to-child, read-from-child, stderr)** — `open2()` swaps its args
  when delegating to `_open3`, which is why open2's docs look right. And slot
  3 must be an explicit `gensym`: left undef it silently shares slot 1's
  handle and the child's stderr mixes into your protocol stream. Verified
  empirically on this box; see `spawn_clamd` in t/09_driver.t.

---

## 4. Testing

```sh
prove -l t/                      # offline: scripted providers, full plumbing (t/09)

CLAM_LIVE_BASE_URL=http://192.168.1.12:1234/v1 \
CLAM_LIVE_MODEL=qwen3.8-27b \
prove -lv t/10_e2e_live.t        # live smoke against a real model server
```

`t/10_e2e_live.t` is skipped unless `CLAM_LIVE_BASE_URL` is set, so the plain
suite stays offline-safe and CI-friendly. The live test drives clamd over
stdio through the full stack (driver → app → loop → provider → HTTP) and
asserts multi-query continuity: turn 2 must remember turn 1's exchange.

**Interleaving with other clients of the same model server works**: requests
are independent, LM Studio serializes concurrent generations on a loaded
model, and `ask()` is synchronous — worst case one side waits for the other's
generation to finish. (This documentation was written while both this agent
and clamd were sharing one LM Studio instance.)
