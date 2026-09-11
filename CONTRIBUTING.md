# Contributing to Clank

Clank is very new, very experimental, and very ambitious. I'm still
figuring out how to use it — especially the command line syntax and
sigil system. Nothing is settled yet.

If you're a Perl hacker and this looks interesting, I'd love your
input and opinions. Open an issue, send a PR, or just tell me what
you think is stupid.

## Getting Started

```bash
git clone https://github.com/BillyLyrical/Clank
cd Clank
cpanm --installdeps .
perl link_wits.pl
prove -l t/
```

## What I Need Help With

- **CLI design** — the sigil system (`/commands`, `@agents`, `%pipelines`, etc.) is functional but rough. If you have opinions on how a Perl AI harness should feel at the prompt, I want to hear them.
- **Wit authoring** — the plugin system works but the ergonomics could be better. If you write a wit and it's painful, that's a bug.
- **Documentation** — the docs/ folder has architecture notes and design docs, but they're written for me. If something is unclear, that's useful feedback.
- **Testing** — 1487 tests, all offline. If you break something, add a test for it.

## Code Style

- Strict + warnings, always.
- No comments unless the logic is genuinely non-obvious.
- Keep it simple. If you need a comment to explain it, rewrite it.
- Follow the patterns in the existing code.

## License

Artistic License 2.0. Same as Perl.
