---
name: perl-style
description: Perl coding conventions for the Clank project. Use when writing or editing .pm files.
---

# Perl Style Guide for Clank

## Core Principles

- **Mastery through simplicity.** The best code is no code; the next best is simple code.
- **Pure functions.** Operate on values, return values. No side effects, no mutation, no hidden state.
- **Small, tight, single-purpose functions.** Composable abstractions over monolithic procedures.

## Conventions

- `use strict; use warnings;` on every line (combined: `use strict; use warnings;`)
- No comments unless asked. Code is self-documenting.
- No feature flags or backwards-compatibility shims.
- Prefer `require` over `use` for lazy loading (wit isolation).
- Module naming: `Clank::Something` (top-level namespace after rename from AI::Clam).
- Wit naming: `Clank::Wits::Deck::Name` (e.g., `Clank::Wits::Git::Status`).

## Sub signatures

Use explicit `my ($self, ...) = @_;` — no signatures (5.020 compat).

## Error handling

- `eval { ... }` around external calls (require, IPC, provider HTTP).
- Return error hashrefs: `{ output => "error: $msg", isError => 1 }`.
- Never die in library code — let the caller decide.

## Exporting

- Use `Exporter 'import'` with `@EXPORT_OK`.
- No `@EXPORT` — everything explicit.

## Testing

- `prove -l t/` must pass (768+ tests, all offline).
- Use `File::Temp::tempdir` for test scratch directories.
- Mock providers for deterministic tests — no live LLM calls in the default suite.
