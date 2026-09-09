---
name: wit-authoring
description: How to write, register, and test Clank wits. Use when creating new wits or modifying existing ones.
---

# Wit Authoring Guide

## What a Wit Is

A wit is a CPAN module in `Clank::Wits::*` that extends the harness: tools the LLM can call, REPL slash commands, and event hooks on the bus.

## File Layout

```
wits/deck-name/lib/Clank/Wits/Deck/Name.pm
wits/deck-name/t/01_basic.t
```

## CLANK-WIT Comment

Every wit module has a `# CLANK-WIT:` comment block near the top:

```perl
# CLANK-WIT: name=Name
# CLANK-WIT: version=1.0.0
# CLANK-WIT: about=One-line description
# CLANK-WIT: usage=Input: { ... } Output: { ... }
# CLANK-WIT: hint=keyword1, keyword2, keyword3
# CLANK-WIT: author=You
# CLANK-WIT: license=Artistic-2.0
```

The `hint` field is essential — dense keywords for LLM tool selection.

## Registration

```perl
sub register {
    my ($self, $api) = @_;

    # Tools the LLM can call
    $api->register_tool(
        name        => 'deck_tool_name',
        description => 'What it does',
        parameters  => { type => 'object', properties => {...}, required => [...] },
        execute     => sub { my ($args) = @_; ... return { output => '...', isError => 0 }; },
    );

    # REPL slash commands
    $api->register_command(name => 'cmd', description => '...', handler => sub { ... });

    # Bus event hooks
    $api->on('topic.pattern', sub { my ($ev) = @_; ... });
}
```

## Testing

```perl
package MockAPI {
    sub new { bless { tools => [] }, shift }
    sub register_tool { my ($self, %def) = @_; push @{$self->{tools}}, \%def; return $def{name} }
    sub register_command { return }
    sub on { return 1 }
    sub track_sub { return 1 }
    sub ui { return undef }
    sub bus { return undef }
    sub store { return undef }
    sub session { return undef }
    sub wit_name { return 'test' }
}

my $api = MockAPI->new();
Clank::Wits::Deck::Name->register($api);
ok(@{$api->{tools}} > 0, 'tools registered');
```

## Key Rules

- eval around `require` + `register`. A broken wit warns and skips.
- Never die in register() — catch and warn.
- Wit state lives in the SQLite store, not in Perl closures.
- The harness always runs — one broken wit never kills the loop.
