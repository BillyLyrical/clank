---
name: testing
description: Testing patterns and conventions for Clank. Use when writing or debugging tests.
---

# Testing Guide

## Running Tests

```sh
prove -l t/                    # all core tests (768+, all offline)
prove -l wits/*/t/             # all wit tests
prove -l t/05_tools.t          # specific test file
prove -lv t/                   # verbose output
```

## Test File Conventions

- File naming: `t/NN_name.t` (numbered, underscore-separated)
- Wit tests: `wits/deck/t/01_basic.t`
- Use `use lib 'lib';` at the top
- Use `File::Temp::tempdir(CLEANUP => 1)` for scratch dirs
- End with `done_testing();`

## Patterns

### Testing tools (builtin)
```perl
use Clank::Tools::Bash;
my $b = Clank::Tools::Bash->new;
my $r = $b->run({ command => 'echo hello' });
is($r->{isError}, 0, 'ok');
like($r->{output}, qr/hello/, 'stdout captured');
```

### Testing wit registration
```perl
my $api = MockAPI->new();
Clank::Wits::Foo->register($api);
my ($tool) = grep { $_->{name} eq 'foo_tool' } @{$api->{tools}};
ok($tool, 'tool registered');
my $result = $tool->{execute}->({ ... });
is($result->{output}, 'expected', 'correct output');
```

### Testing with Clank::Exec (subprocess isolation)
```perl
use Clank::Exec qw(exec_cmd);
my $r = exec_cmd(command => ['perl', '-e', 'print "ok"']);
is($r->{stdout}, 'ok', 'subprocess output');
is($r->{exit_code}, 0, 'exit 0');
```

### Testing with in-memory store
```perl
use Clank::Store;
my $store = Clank::Store->new(db => ':memory:');
```

## Mock API Pattern

Wits call `$api->register_tool(...)`, `$api->on(...)`, etc. Mock them:
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
```

## Boolean Assertions

Perl `!!0` is `''` (empty string), not `0`. Use `ok(!$r->{ok}, ...)` instead of `is($r->{ok}, 0, ...)`.
