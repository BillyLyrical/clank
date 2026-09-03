# Wits — Planning Document

Status: plan (v0.2 era). Supersedes the plugin section of `docs/DESIGN.md` §9;
the old design lives in `~/dev/clam-old/docs/concepts/wits.md`. The Wits-vs-CPAN
review that motivated this doc is archived at `_tmp/verdict`.

## 1. What a Wit Is

A wit is a loadable unit of behavior for the clam harness: tools the LLM can call,
REPL slash commands, and event hooks on the blackboard bus. A deck is a named batch
of wits with a manifest (`deck.toml`).

Two layers, one each — this is the whole argument:

| Layer | Question it answers | Answer in clam |
|---|---|---|
| **Runtime** | How does behavior get into a running process? | Wits: discovery roots, `register($api)`, error isolation, disable/unload. |
| **Distribution** | How does code get onto the machine in a tested state? | Git repos + `clam wits install` — with CPAN's *discipline* (declared deps, tests at install time, lockfile), not its machinery (PAUSE, Makefile.PL). |

The verdict from the review: **not either/or.** CPAN is a distribution and
dependency manager; wits are a runtime plugin architecture. Using `.wit` files as a
*distribution* format (what clam-old did) was a mistake — custom formats are a tax:
no editor support, no tooling, your own parser to maintain forever. And making every
30-line plugin a full CPAN dist with PAUSE queueing is overkill.

So: wits stay the runtime unit; git stays the distribution channel for v1; we steal
CPAN's three disciplines — declared dependencies, tests at install time, versioned
lockfile.

## 2. Layouts

Two layouts, both first-class, one primary.

### 2.1 Module wits (primary)

A wit is a Perl module with a `register($api)` method:

    <wit-dir>/
      lib/Clam/Wit/<Name>.pm     # the wit; helpers under Clam::Wit::<Name>::* only
      t/                         # tests, run at install time (see §6)
      README.md                  # first line = about text
      wit.toml                   # manifest: version, deps, about, usage

Why primary: "a wit is a .pm file" is the strongest onboarding story we have. Every
Perl programmer knows what that means; `perl -c`, perldoc, and every IDE just work.
It is also exactly CPAN dist layout, so a mature wit can graduate to PAUSE without
reformatting (see §8, P3-3).

### 2.2 Declarative wits (.wit files)

TOML metadata + embedded Perl heredoc — the clam-old format, kept byte-compatible in
`decks/`. Fine for small declarative things: a tool with no state and no helpers.
Not the foundation of the ecosystem: it is a custom file format, and every tool that
understands Perl stops working on it.

Rule: if your wit needs more than one subroutine or any helper module, it is a .pm
wit. Decks keep `deck.toml` as their manifest; standalone wits use `wit.toml`.

### 2.3 Stdio wits (external processes)

A third layout for units whose code we do not want in our process space — the answer
for untrusted or volatile user code (§7.1). The unit ships an executable script
instead of a module; any language with a shebang works:

    <wit-dir>/
      wit.toml               # manifest, plus handler/exec/timeout (below)
      bin/tool.pl            # or .sh/.py/... — anything the kernel will run
      t/                     # same install-time test gate as every other unit

    # wit.toml additions
    handler = "stdio"        # default: module (in-process); stdio spawns a process
    exec    = "bin/tool.pl"  # relative to the unit dir; cwd is set there at spawn
    timeout = 30             # seconds, hard kill deadline. Default 30.

The protocol — this is the entire contract:

1. clam spawns `exec` with env inherited (CLAM_HOME etc.) and cwd = unit dir
2. writes exactly one JSON object to its stdin: `{ "args": {...} }`, then closes it
3. reads exactly one JSON object from stdout:
     `{ "ok": true, ...result fields }`  → success; fields become the tool result
     `{ "error": "message" }`            → failure; message goes to the LLM as a tool error
4. stderr is captured as a log; on any failure its tail (last ~20 lines) rides along
   in the error message

Protocol rules: stdout carries exactly one JSON object — logs go to stderr, always.
Scripts must ignore unknown input keys (forward compatibility). Anything else on
stdout (multiple objects, non-JSON prefix) is a protocol violation → tool error with
the captured output attached.

Timeouts and reaping port the pattern from `~/arc/suck` (GPL — adapt with attribution,
do not copy verbatim): IO::Select polling against a deadline rather than alarm() — we
buffer all output instead of streaming it live, so no signal acrobatics are needed; on
expiry kill TERM, wait ≤5s, escalate to KILL. Internal exit-code semantics follow GNU
timeout (124 = hard timeout); the LLM only ever sees the composed error string.

What a stdio wit is NOT:

- **Not a hook channel.** It can be called by the loop, never subscribe to it — hooks
  and bus agents stay in-process (§5). A tool that fires per call is exactly the right
  shape for a process; an event listener is not.
- **Not a daemon (v1).** One-shot request/response. A long-lived stdio mode with a
  persistent pipe is possible later; nothing here forces it out.

Implementation: `Clam::Wit::Stdio` (~60 lines, core deps only — IO::Select + JSON::PP)
plus one loader branch that builds an ordinary Clam::Tool around the spawn. Above the
tool boundary the loop, prompt assembly, `/tools`, and disable/enable cannot tell the
difference; that invisibility is the design.

What we take from suck: hard timeout, TERM→KILL escalation, separate stderr pipe.
What we drop: silence timeout (a well-behaved one-shot either outputs or exits — defer
as an optional per-unit field), quiet/ring mode (we always buffer; the ring becomes a
cap on captured stderr for error messages), panic-on-stderr (stderr is normal logging).

## 3. Metadata: about / usage (required)

Every installable unit declares, in its manifest:

    # wit.toml
    name    = "git-guardrails"        # directory name; unique across roots
    version = "0.1.0"                 # semver
    author  = "..."
    license = "Artistic-2.0"
    about   = "Blocks dangerous git commands before they run"
    usage   = "Load in any repo you trust the model with; vetoes rm/reset --hard/push -f via tool_call hook"
    requires_perl = ["PPI"]           # optional, checked at install time
    requires_bin  = ["git"]           # optional

`about`: one line. What it does. This is what `clam wits list` prints and what a
human greps for.

`usage`: two to four lines. When to load it, what it changes, what it costs. This is
what the LLM sees when deciding whether to use a wit's tools (tool-selection context)
and what a newcomer reads before installing.

Both are **required**. Loader behavior: missing → the wit loads but is flagged
`undocumented` in `wits list`; install refuses with a message. A plugin you cannot
describe in one line is not finished.

### 3.1 Grepability — the point of this section

Discovery must work with the tools Unix people already reach for:

    grep -l "about" ~/.clam/wits/*/wit.toml
    clam wits list                 # name + about, one per line
    clam wits search guardrail     # substring match on about+usage across installed units
    clam wits info git-guardrails  # full manifest + dir + version + source

To make `search` instant instead of a grep storm over every file, install maintains
an index: `~/.clam/wits.index.json`, one entry per unit:

    { "git-guardrails": { "about": "...", "usage": "...", "version": "0.1.0",
                          "dir": "~/.clam/wits/git-guardrails", "source": "git+sha" } }

Rebuilt by `wits install/uninstall/upgrade`; verified at startup (stale entries
dropped, missing ones added). The index is a cache; the manifests are truth.

For module wits the same fields also live in the module as a plain-text package
variable — so `grep -r "about" ~/.clam/wits/*/lib` works even without a manifest:

    our $WIT = {
        about => 'Blocks dangerous git commands before they run',
        usage => 'Vetoes rm/reset --hard/push -f via tool_call hook.',
    };

The loader reads `$WIT` after require and cross-checks it against the manifest;
mismatch → warning. The manifest is the source of truth for humans; the in-module
copy exists so a bare .pm dropped on `CLAM_WITS_PATH` is still self-describing.

Later step (P3-1): index rows feed an FTS5 table, and wit/tool selection becomes
retrieval-based instead of "dump every schema into the prompt" — the RATS pattern
from `docs/plan.txt`. The about/usage fields are exactly the text that makes that
work; writing them now is what buys us that option later.

## 4. Discovery and Loading (current behavior, two fixes)

Discovery roots, in priority order (later wins on name collision):

    1. CLAM_WITS_PATH   (colon list; explicit override)
    2. ./.clam/wits     (project — the repo's choice for this checkout)
    3. ~/.clam/wits     (user — your choice, all projects)
    4. -w/--wit DIR     (per-invocation)

This layering is good Unix (/etc → ~/.config → ./local). Keep it. CPAN does not give
you per-project override at all; that is a feature of this design, not an accident.

Loading stays as-is where it works: eval around require + register, broken wit warns
and skips, the harness always runs (`Clam::PluginManager.pm`, `load_dir`). Two fixes:

**Fix 1 — @INC pollution.** `load_dir` does `unshift @INC, "$dir/lib"` and never takes
it back; two wits shipping the same module name shadow each other silently. Rule
(enforced at load time): a wit may only ship files under its own namespace —
`Clam/Wit/<Name>.pm` and `Clam/Wit/<Name>/*.pm`. The loader scans the directory before
touching @INC; anything else → refuse to load, name the offending file.

**Fix 2 — dependency declaration for module wits.** Declarative wits already declare
`requires_perl`/`requires_bin` and get skipped with a note when missing. Module wits
have no such channel: a failing `use PPI;` just dies inside require and the whole unit
is skipped with a raw "Can't locate PPI.pm" — true, but not actionable. The manifest's
`requires_perl`/`requires_bin` becomes the single declaration point for both layouts;
the loader checks before load and reports:

    [wits] git-guardrails: missing perl deps: PPI  (fix: cpanm PPI)

**Fix 3 — the manifest is the unit test.** `_wit_dirs` currently sniffs for `.pm`,
`.wit`, or `lib/`; a stdio unit (§2.3) has none of those and would be invisible to
discovery. Rule: a directory carrying a manifest (`deck.toml`/`wit.toml`) is a unit,
full stop — the manifest becomes the single source of truth for "is this a wit". The
sniff stays only as a fallback for bare manifest-less dirs (a lone .pm dropped on
CLAM_WITS_PATH, the §3.1 self-describing case).

## 5. Lifecycle: Load, Disable, Unload

The stated goal is "plugins loaded (and unloaded as required)". Be honest about what
Perl can do, then design around it — the Cordis framework does this well and we steal
its one real idea: **revertible effects**.

### 5.1 States

    UNLOADED → LOADED → ACTIVE ⇄ DISABLED
                 │
                 └── (declarative wits only) → UNLOADED   [full, in-process]

- **ACTIVE**: registered tools callable by the LLM, commands in the REPL, hooks on the bus.
- **DISABLED**: all registrations reverted; module still compiled in memory; re-enable is instant.
- **UNLOADED** (declarative only): record gone from the dispatcher hash; nothing left but files on disk.

### 5.2 Revertible effects (the Cordis idea, ported)

Every registration a wit makes goes through `Clam::Wit::API`, which already collects
tools and commands per wit. Extend it so every effect is tracked with its reverse:

    $api->on($topic, \&h)       → bus->subscribe returns an id; API stores (id, topic)
    $api->register_tool(%def)   → stored in api->{tools}; removal = delete by name
    $api->register_command(...) → same

`disable($wit)` runs every reverse: `bus->unsubscribe($id)` for each hook (the method
already exists — `Clam::Bus.pm`, line 47), tools and commands dropped from the merged
registries. No leftover listeners, no ghost tools. This is exactly Cordis's
`ctx.effect()` bookkeeping, minus the fibers: we do not need coroutines to track a
reverse operation, just a list of them.

`enable($wit)` re-runs `register($api)` on the existing object (module wits) or
recompiles the closures (declarative). Idempotent, like today's load path.

### 5.3 What we do NOT promise

True hot-unload of a compiled Perl package — deleting the stash and %INC entry — is
possible and fragile (END blocks, circular refs, global state in helpers). We do not
do it for module wits. The honest Unix answer: **disable now, restart clamd to fully
unload.** clamd is a long-lived daemon with clean signal handling; restarting it is a
feature, not an apology. Declarative wits get full unload because they are just
closures in a hash — that is where the design leans. Stdio wits sidestep this entirely:
their code *is* a process, and disable stops spawning it — true unload without touching
Perl's limits (§2.3).

### 5.4 Dependency-aware loading (Cordis `inject`, ported)

A wit may declare `requires_wit = ["rag"]` in its manifest. The loader resolves load
order from the dependency graph, not directory order:

- dep missing → unit is **PENDING**, reported by `wits list`; loads automatically when
  the dep appears (next startup; mid-session auto-load is P2)
- a loaded wit gets disabled/unloaded → dependents are auto-disabled with a note

This replaces clam-old's `priority` numbers and `depends_on` registry lookups with one
mechanism. Wits that need harness services do not declare them — bus/store/session/ui
are always present (the "host plane", below).

### 5.5 Two planes (naming, not new machinery)

Cordis splits plugins into host composition (process-level infrastructure) and agent
presets (session-level behavior). Clam already has this split implicitly: bus, store,
and providers are process-level; wits are session-scoped in intent but loaded at
process start today. v1 keeps that (all wits load when clam/clamd starts); per-session
wit selection is a later step, and the state machine above is what makes it safe.

REPL surface: `/wits` (list with states), `/wit disable NAME`, `/wit enable NAME`,
`/wit unload NAME` (declarative only; module wits get "disabled — restart to unload").

## 6. Install Flow: CPAN's Discipline Without Its Machinery

CPAN's most valuable property is not the mirror network or PAUSE — it is that
`cpanm Foo::Bar` resolves dependencies and **runs the code's tests on your machine
before installing**. We replicate exactly that, in about twenty lines of shell logic:

    clam wits install <dir>            # name/catalog resolution arrives with P2-4
      1. fetch     copy dir (git clone --depth 1 for catalog sources — P2-4)
      2. validate  manifest present; name/version/about/usage all set; namespace rule
                   holds (§4 fix 1); no files outside the wit's own directories
      3. deps      requires_perl/requires_bin checked → actionable message on miss
                   (cpanm PPI / apt install git) — or --assume-deps to skip
      4. test      run each t/*.t with plain perl, no prove dependency (refuse on
                   failure; a unit without t/ installs untested — the lockfile's
                   tested=false says so honestly)
      5. place     copy into ~/.clam/wits/<name>  (or ./.clam/wits with --project)
      6. record    write lockfile entry + rebuild wits.index.json

`~/.clam/wits.lock` — one JSON object, the upgrade story:

    { "git-guardrails": { "version": "0.1.0",
                          "source": "https://github.com/x/gg#abc1234",
                          "installed_at": 1756800000, "tested": true } }

`clam wits upgrade [NAME]` re-runs the flow against recorded sources; a version going
down is refused without --force. `uninstall` removes dir + lockfile entry + index row.

What we deliberately do NOT build: a Makefile.PL per wit, PAUSE uploads, XS build
steps. A wit that needs an XS dependency declares it in requires_perl and tells the
user to cpanm it — same as any Unix tool with system deps.

## 7. Security and Trust (the honest version)

Both approaches run third-party code in your process with no sandbox; CPAN does not
solve this either (cpanm happily executes arbitrary build scripts). So security is a
wash, and what actually matters is provenance + policy:

- **In-tree decks** (`decks/`): trusted — they ship with the harness.
- **Installed wits**: you ran `wits install`; the lockfile records exactly which git sha.
- **Project wits** (`.clam/wits`): the repo's choice for this checkout — same trust as
  running the repo's Makefile.

v1 has no sandboxing of wit code (the old docs say so too). The planned `perl_eval`
wit will use a Safe compartment for *LLM-generated* code; that is a different threat
model and stays in the wit layer, not the loader.

### 7.1 Curation: provenance tiers, not self-declaration

Trust comes from where a unit came from — never from fields it writes about itself
(a user can put `curated = true` in their own wit.toml; we do not parse lies):

- **Curated**: ships in-tree (`decks/`) or is listed in the curation catalog — a small
  JSON file of index-shaped rows (name/version/source/about/usage) that maintainers
  edit. Curated units may use any layout, including in-process module wits with full
  bus access.
- **User**: everything else. The mechanical gate floor (§6: manifest fields, tests at
  install, deps, namespace rule) applies to everyone — curated included; curation adds
  review on top of the gates, it does not replace them. Recommended template for user
  units with real logic is stdio (§2.3): the process boundary buys crash containment
  and true unload, which in-process code cannot give.

Optional strict mode (P2-4): a config flag that refuses non-curated in-process module
wits at load time ("user units: stdio or declarative only"). Off by default — the
recommendation does most of the work; the flag is for people who want the wall.

## 8. Build List (priority order)

| # | Item | § | Effort | Status |
|---|------|---|--------|--------|
| P0-1 | about/usage manifest fields + `wits.index.json` + `list/search/info` output | 3 | ~1 day | ✅ cb71b16 (t/13) |
| P0-2 | Effect tracking in Wit::API (bus sub ids, tool/command removal) + `/wit disable\|enable` | 5.2 | 1–2 days | ✅ f732c24 (t/14) |
| P1-1 | Install-time test run + dep check with actionable messages | 6 | ~half day | ✅ 885a9eb (t/15) |
| P1-2 | `~/.clam/wits.lock` + `wits upgrade` | 6 | hours | ✅ 5834c02 (t/15) |
| P1-3 | Namespace rule enforced at load time (refuse non-Clam::Wit::<Name> files) | 4 | small | ✅ cfe3f2e (t/13 §4) |
| P2-1 | requires_wit dependency graph: PENDING state, ordered load, auto-disable dependents | 5.4 | ~2 days |
| P2-2 | Full in-process unload for declarative wits (`/wit unload`) | 5.3 | medium — bookkeeping only |
| P2-3 | stdio handler type: `Clam::Wit::Stdio` (spawn, JSON contract, hard timeout + TERM→KILL per the suck pattern) + manifest-based discovery (§4 fix 3) | 2.3, 4 | ~1 day |
| P2-4 | curation catalog + `wits install <name>` resolution; optional strict mode for non-curated in-process wits | 6, 7.1 | half a day |
| P3-1 | FTS5 index of about/usage → retrieval-based tool/wit selection (RATS) | 3.1 | later |
| P3-2 | Per-session wit loading (agent presets); mid-session auto-load of PENDING deps | 5.4–5.5 | later |
| P3-3 | Graduation path: publish a mature wit to PAUSE as Clam-Wit-<Name> (layout already compatible) | 2.1 | when one earns it |

Sequencing note: P0-2 before P2-2 — disable is the 80% of unload, and effect tracking
is what makes both safe. P2-3 is independent of P2-1/P2-2 and unblocks the user-code
story (§7.1); P2-4 builds on it only for the strict-mode check. Every item keeps
`prove -l t/` green; each gets its own test file (t/13_wit_meta.t,
t/14_wit_lifecycle.t, ...).

## 9. What This Doc Deliberately Does Not Change

- The bus stays the spine: wits talk to everything via topics, never direct calls.
- Pi-parity loop semantics and tool prompts are untouched.
- `.wit` file format stays byte-compatible with clam-old; we add fields, do not break old decks.
- `Clam::Driver`/clamd protocol unchanged — lifecycle commands get NDJSON verbs later
  (`{"command":"wit_disable","name":...}`) once the REPL surface exists.
