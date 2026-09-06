# Wits — Implementation Spec

Status: architecture spec. Vision and roadmap live in `docs/ROADMAP.md`.
This document covers the wit system design: CPAN modules, discovery, registration,
lifecycle, and distribution model.

## 1. What a Wit Is

A wit is a CPAN module in the `Clam::Wits::*` namespace that extends the clam
harness: tools the LLM can call, REPL slash commands, and event hooks on the
blackboard bus.

The `Clam::Wit::*` namespace is harness infrastructure (API, Scanner, etc.).
User wits live in `Clam::Wits::*`.

One system, one source of truth: **wits are CPAN modules.**

| Concern | Mechanism | Custom code? |
|---------|-----------|-------------|
| Distribution | `cpanm Clam::Wits::Foo` | No |
| Discovery | `grep -r "# CLAM-WIT:" @INC/Clam/Wit/` | No |
| Metadata | `# CLAM-WIT:` comment in module file | No |
| Dependencies | `META.json` + cpanm | No |
| Runtime state | SQLite DB (loaded, enabled) | Yes (exists) |
| Loading | `require` + `register($api)` | Yes (exists) |
| Isolation | `eval { require ... }` | Yes (exists) |

## 2. Module Layout

A wit is a standard CPAN module in the `Clam::Wits::*` namespace with a
`register($api)` method:

    Clam/Wits/Foo.pm           # entry point: register($api)
    Clam/Wits/Foo/Helper.pm    # optional sub-tree (Clam::Wits::Foo::* only)

The `# CLAM-WIT:` comment at the top provides grep-able metadata.
The `register($api)` method integrates the wit at runtime.

Helpers live under the wit's own namespace (`Clam::Wits::Foo::*`).
No files outside `Clam::Wits::Foo::` — namespace discipline.

The `Clam::Wit::*` namespace is harness infrastructure (API, Dispatch, Scanner,
Session). User wits never go there.

## 3. The `# CLAM-WIT:` Comment Format

Every wit module has a `# CLAM-WIT:` comment block near the top. This is the
single source of truth for discovery metadata — grep finds it without loading
the module.

### Format

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

### Rules

- `# CLAM-WIT:` prefix marks a metadata line
- `key=value` after the prefix (split on first `=` only — values can contain `=`)
- One key per line; continuation lines use the same prefix
- Unknown keys are ignored by old parsers (forward-compatible)

### Fields

| Field | Required | Default | Purpose |
|-------|----------|---------|---------|
| `name` | no | package suffix (`Clam::Wits::Foo` → `Foo`) | Module identity |
| `version` | no | `0.0.1` | Semantic version |
| `about` | yes | — | One-line human description |
| `usage` | no | — | When to load, what it changes, what it costs |
| `hint` | yes | — | Dense keywords for LLM tool selection |
| `author` | no | — | Who wrote it |
| `license` | no | — | Artistic-2.0, GPL, etc. |

### Field Descriptions

**`about`** — one line. What it does. This is what `wits list` prints and what a
human greps for. Example: "Blocks dangerous git commands before they run."

**`usage`** — two to four lines. When to load it, what it changes, what it costs.
This is what the LLM sees when deciding whether to load a wit's tools (tool-selection
context) and what a newcomer reads before installing.

**`hint`** — dense keywords for the LLM's tool-selection context. When the LLM sees
available tools, it needs a short, keyword-rich description to decide which to use.
Example: "Git safety: vetoes rm, reset --hard, push -f, force." No grammar, no
sentences — just keywords the LLM can match against.

### Grep

```bash
# Find all installed user wits
grep -r "# CLAM-WIT:" $(perl -e 'print join ":", @INC')/Clam/Wits/

# List all wits with about text
grep -h "# CLAM-WIT:.*about=" @INC/Clam/Wits/*.pm

# Search for wits matching a keyword
grep -l "# CLAM-WIT:.*hint=.*git" @INC/Clam/Wits/*.pm
```

### DB Cache

After the first grep scan, metadata is cached in the SQLite DB. Subsequent
lookups query the DB, not the filesystem. The DB is the runtime view; the
`# CLAM-WIT:` comment is the source of truth.

## 4. Registration: `register($api)`

The comment is for discovery. The `register($api)` function is for runtime
integration. After `require`, the PluginManager creates a `Clam::Wit::API`
object and calls `$wit->register($api)`.

### What the API provides

```perl
sub register {
    my ($self, $api) = @_;

    # Register tools the LLM can call
    $api->register_tool(
        name        => 'git_guard_vetoes',
        description => 'Check if a git command is dangerous',
        parameters  => { type => 'object', properties => { ... } },
        execute     => sub { my ($args) = @_; ... },
    );

    # Register REPL slash commands
    $api->register_command('guard-status',
        description => 'show git guard status',
        handler     => sub { my ($ctx, $args) = @_; ... },
    );

    # Register bus event listeners
    $api->on('tool_call', sub {
        my ($ev) = @_;
        # Block dangerous git commands
    });

    # Register help text
    $api->help('GitGuard blocks dangerous git commands...');
}
```

### Context passed to handlers

Command handlers receive:
```perl
{
    bus     => $app->bus,      # pub/sub bus
    store   => $app->store,    # SQLite store
    session => $app->session,  # current session
    app     => $app,           # the Clam::App object
}
```

Tool handlers receive the tool arguments hash.

Bus handlers receive the event hash `{id, correlation_id, topic, sender, payload}`.

## 5. Discovery and Loading

### Production (installed via cpanm)

1. **Scan**: `grep -r "# CLAM-WIT:" @INC/Clam/Wits/` finds all installed wits
2. **Cache**: Store metadata in SQLite DB (one-time scan)
3. **Select**: Query DB to decide which wits to load (based on config/context)
4. **Load**: `require Clam::Wits::Foo` → Perl finds it in `@INC` (installed by cpanm)
5. **Register**: Call `$wit->register($api)`

### Development (in-tree wits)

1. **Scan**: `grep -r "# CLAM-WIT:" wits/*/lib/Clam/Wits/` finds dev wits
2. **Select**: Same as production
3. **Load**: Add each wit's `lib/` to `@INC`, then `require`
4. **Register**: Same as production

Same loader, same code. Just different `@INC` setup.

### Isolation

eval around `require` + `register`. A broken wit warns and skips. The harness
always runs. This is proven (527 tests, all passing).

## 6. Lifecycle: Load, Disable

### States

```
LOADED → ACTIVE ⇄ DISABLED
```

- **ACTIVE**: registered tools callable by the LLM, commands in the REPL, hooks on the bus.
- **DISABLED**: all registrations reverted; module still compiled in memory; re-enable is instant.

### Revertible Effects

Every registration a wit makes goes through `Clam::Wit::API`, which tracks
tools, commands, and bus subscriptions per wit. Disable runs every reverse:

- `bus->unsubscribe($id)` for each hook
- Tools and commands dropped from the merged registries

No leftover listeners, no ghost tools.

### What We Do NOT Promise

True hot-unload of a compiled Perl package is fragile (END blocks, circular refs,
global state in helpers). The honest Unix answer: **disable now, restart clamd to
fully unload.**

## 7. Distribution Model

### CPAN Distributions

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

`cpanm Clam` installs the core. Session wit is included (it's part of the
harness). All other wits are separate dists.

**Wit dists: `Clam-Wits-Foo`** — one per wit (or one per related group).

```
Clam-Wits-Foo/
  lib/Clam/Wits/Foo.pm
  lib/Clam/Wits/Foo/Helper.pm
  META.json
  t/
```

`cpanm Clam-Wits-Foo` installs the wit. `META.json` declares `requires => { Clam => '1.0' }`.

### Install Tree

After installation, everything lands in one `@INC` tree:

```
@INC/
  Clam.pm
  Clam/
    App.pm
    Loop.pm
    Bus.pm
    Store.pm
    Provider/
    Tool.pm
    Tools/
    Wit/
      API.pm
      Session.pm
    Wits/
      Foo.pm          # cpanm Clam-Wits-Foo put this here
      Foo/
        Helper.pm
      Bar.pm          # cpanm Clam-Wits-Bar put this here
```

One tree. `grep -r "# CLAM-WIT:" @INC/Clam/Wit/` finds everything.

### Dev Tree

In the git repo, wits live in `wits/` as separate dist directories:

```
clam/
  lib/                  # core modules (shipped in Clam dist)
    Clam.pm
    Clam/
      App.pm
      ...
  wits/                 # wit modules (separate dists)
    Foo/
      lib/Clam/Wits/Foo.pm
      META.json
      t/
    Bar/
      lib/Clam/Wits/Bar.pm
      META.json
      t/
  bin/clam
```

The `Clam` dist's `META.json` lists only core modules. The `wits/` directory
is a staging area for development, not shipped in the core dist.

### Packaging

Each wit directory is a separate CPAN dist. The packaging tool reads
`# CLAM-WIT:` markers and `META.json` to build separate tarballs.

### Dependencies

Declared in `META.json` (standard CPAN). cpanm resolves them. No custom
`requires_perl`/`requires_bin` fields — CPAN handles this.

```json
{
  "name": "Clam-Wits-Foo",
  "version": "1.0",
  "requires": { "perl": "5.040001", "Clam": "1.0" },
  "provides": {
    "Clam::Wits::Foo": { "file": "lib/Clam/Wits/Foo.pm", "version": "1.0" }
  }
}
```

## 8. Security and Trust

Third-party code runs in your process with no sandbox; CPAN does not solve this
either (cpanm happily executes arbitrary build scripts). Security is provenance
+ policy:

- **In-tree wits** (in `wits/`): trusted — they ship with the harness
- **Installed wits**: you ran `cpanm`; CPAN records the version
- **Project wits**: the repo's choice for this checkout

eval isolation protects against bad modules. A broken wit warns and skips.
The harness always runs.

### Curation

Trust comes from provenance, not self-declaration. The `# CLAM-WIT:` comment
is not a trust signal — it's metadata. Curation is external (maintainer review,
curation catalog).

## 9. What Goes Away

| Old Mechanism | Replaced By |
|---------------|-------------|
| `wit.toml` / `deck.toml` | `# CLAM-WIT:` comment + `META.json` |
| `wits.lock` | CPAN versioning |
| `wits.index.json` | SQLite DB cache |
| `clam wits install/upgrade/uninstall` | `cpanm` |
| Directory-based discovery | `grep -r "# CLAM-WIT:"` |
| Declarative `.wit` files | CPAN modules |

## 10. What Stays

- `register($api)` contract — runtime integration
- eval isolation — bad modules don't kill the harness
- Bus, tools, commands — all the runtime behavior
- SQLite store — runtime state (loaded, enabled, session history)
- Namespace discipline — `Clam::Wits::Foo` may only ship `Clam::Wits::Foo::*`
