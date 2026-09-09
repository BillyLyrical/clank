# hello — example wit

The smallest useful clank wit. Use it as a template for your own wits.

Demonstrates all three registration surfaces (see `docs/ROADMAP.md` §5):

- **tool** — `greet`: callable by the LLM via function calling
- **command** — `/hello [text]`: a REPL slash command
- **hook** — an example `input` transform (commented out; it rewrites every prompt)

## Layout

```
hello/
  lib/Clank/Wits/Hello.pm    # the wit module (standard layout)
  README.md
```

## Try it

```sh
# run clank with this example on the wit path:
clank -w /path/to/clank/wits.example/hello

# or install it:
cd /path/to/clank/wits.example/hello
cpanm .
```

Then in the REPL: `/hello there` — and ask the model to "greet alice" to see
the `greet` tool get called.
