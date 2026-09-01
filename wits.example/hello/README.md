# hello — example wit

The smallest useful clam wit. Use it as a template for your own wits.

Demonstrates all three registration surfaces (see `docs/DESIGN.md` §5):

- **tool** — `greet`: callable by the LLM via function calling
- **command** — `/hello [text]`: a REPL slash command
- **hook** — an example `input` transform (commented out; it rewrites every prompt)

## Layout

```
hello/
  lib/Clam/Wit/Hello.pm    # the wit module (standard layout)
  README.md
```

Tiny wits may also be a single `.pm` file at the wit root (no `lib/`); the
declared package name is read from the source.

## Try it

```sh
# run clam with this example on the wit path:
clam -w /path/to/clam/wits.example/hello

# or install it to ~/.clam/wits:
clam wits install /path/to/clam/wits.example/hello
```

Then in the REPL: `/hello there` — and ask the model to "greet alice" to see
the `greet` tool get called.
