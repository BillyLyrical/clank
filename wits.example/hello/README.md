# hello — example wit

The smallest useful clam wit. Use it as a template for your own wits.

Demonstrates all three registration surfaces (see `docs/ROADMAP.md` §5):

- **tool** — `greet`: callable by the LLM via function calling
- **command** — `/hello [text]`: a REPL slash command
- **hook** — an example `input` transform (commented out; it rewrites every prompt)

## Layout

```
hello/
  lib/Clam/Wits/Hello.pm    # the wit module (standard layout)
  README.md
```

## Try it

```sh
# run clam with this example on the wit path:
clam -w /path/to/clam/wits.example/hello

# or install it:
cd /path/to/clam/wits.example/hello
cpanm .
```

Then in the REPL: `/hello there` — and ask the model to "greet alice" to see
the `greet` tool get called.
