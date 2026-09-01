# Decks — installable batches of Wits

A **deck** is a batch of wits that can be imported and installed separately,
after the initial clam install. Each deck directory is self-contained:

```
decks/<deck>/
  deck.toml            # manifest: name, description, version, wit list
  <group>/<wit>.wit    # declarative wits (clam-old format)
```

A `.wit` file is TOML metadata with an embedded Perl source heredoc — the
format from `~/dev/clam-old`, kept unchanged. The handler contract:

```perl
my ($self, $input, %ctx) = @_;   # returns a result hashref or undef ("no fire")
```

`%ctx` provides (see `lib/Clam/WitLoader.pm`):

| key         | meaning                                                        |
|-------------|----------------------------------------------------------------|
| `wits`      | dispatcher — `$ctx{wits}->execute('deduction.axiom', $input)`  |
| `state`     | persistent hashref for stateful wits (Store kv, per wit name)  |
| `bus`       | the blackboard bus (reply-semantics adapter, see below)        |
| `store`     | the SQLite store                                               |
| `session`   | current session                                                |
| `config`    | harness config (empty in v1)                                   |
| `clam_home` | `~/.clam` path                                                 |
| `workdir`   | coderef creating a scratch dir under `~/.clam/work/`           |

Wits with `subscribes=[...]` also act as **bus agents**: on each published
event they execute and publish their result to the first `publishes` topic
(or `<topic>.result`). Recursion is capped at depth 5 (same cap as the old
Bus) — a result topic can match its own subscription pattern, e.g.
`search.*` vs `search.results`. Wits declare optional dependencies via
`requires_perl=[...]` / `requires_bin=[...]`; when a host lacks one, the wit
is skipped with a note (visible in `$pm->skipped`) instead of erroring.

## Deviations from clam-old

The port keeps every `.wit` file byte-identical except where the old code was
provably broken or written against an API that never existed:

1. **`git/git/log.wit`** — the `--pretty=format:%H|%h|...` argument is now
   shell-quoted; unquoted, its pipes were parsed as pipelines and the command
   could never work on any POSIX shell.
2. **`search/search/local.wit`** — `_ref => "$src:$item->{id}" // "..."` was a
   dead fallback (the left side is always defined) that warned on missing ids;
   it now falls back id → name → bare source name.
3. **`ctx{bus}` reply semantics** — the old Bus `publish()` was fire-and-forget,
   which left `search.local`/`search.search` (both written to read a reply from
   `publish`) as dead code. The new loader hands wits a thin adapter that keeps
   all real-bus side effects but returns the first hashref handler result, so
   bus-based local search actually works.

## Installing a deck

```sh
clam wits install <path-to-deck>     # copies to ~/.clam/wits/<deck>
# or point discovery at it directly:
CLAM_WITS_PATH=<path-to-decks-parent> clam ...
clam -w <path-to-deck> "..."
```

Discovery order (unchanged): `CLAM_WITS_PATH` → `./.clam/wits` →
`~/.clam/wits` → `-w/--wit` paths. A deck installed to `~/.clam/wits/<deck>`
is picked up automatically on the next start. Decks may live anywhere — this
directory is just where they are developed; nothing here is required by the
core harness (`lib/`).

## Ported decks (verified in t/08_decks.t)

| deck     | wits | contents                                                        |
|----------|------|-----------------------------------------------------------------|
| `logic`  | 47   | deduction chains, classification rules, SAT (picosat), induction |
| `critic` | 12   | code critique heuristics (style/quality/security/perf/...)      |
| `git`    | 10   | git operations: status/log/diff/blame/branch/commit/stash/...   |
| `fs`     | 18   | filesystem ops: read/write/edit/list/search/copy/move/snapshot  |
| `search` | 9    | local search + web providers (need network/API keys at runtime) |

## Not ported yet (from clam-old, and why)

The loader is generic — any old-format wit directory dropped into a deck dir
loads. These groups were left out of the initial port:

- **cloud providers** (`aws`, `azure`, `gcp`, `aliyun`, `digitalocean`,
  `hetzner`, `linode`, `oci`, `scaleway`, `vultr`, `cloudflare`, `k8s`): need
  vendor CLIs and credentials; untestable here.
- **agent orchestration** (`swarm`, `band`, `orchestration`, `federation`,
  `mollusk`, `user`, `agent`, `ai`, `clam`, `architect`, `cognitive`): depend
  on old-tree infrastructure (Swarm/Blackboard/Pipeline objects in `%ctx`)
  that the new harness does not provide yet.
- **C toolchain** (`c`): needs Inline::C / FFI / gcc.
- **media readers** (`read`): need PDF::Extract, ffprobe, ImageMagick.

To port one later: copy `clam-old/lib/Clam/Wits/<group>` into a new deck dir
(keeping the group subdir so names stay `<group>.<wit>`), add a `deck.toml`,
and extend t/08_decks.t with its verification cases.
