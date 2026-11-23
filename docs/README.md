# fluxdl documentation

Short documents about decisions, for the same reason Fluxget writes them down: a
choice you can only reconstruct from a conversation is a choice the next person
makes differently.

The [project site](index.html) is the readable entry point; these files are the
source of truth it links to.

## Index

| Document | Question it answers |
|---|---|
| [API.md](API.md) | every public V module, its symbols and a small example |
| [GUIDES.md](GUIDES.md) | task guides: install, downloads, torrents, RPC, extension points |
| [PACKAGE.md](PACKAGE.md) | how to install and import fluxdl as a vpm package |
| [CLI](CLI.md) | what each command does, and what flags it takes |
| [Architecture](ARCHITECTURE.md) | where the purity boundary is and why the files are arranged this way |
| [RPC](RPC.md) | the JSON-RPC methods, their shapes, and the four wire quirks |
| [ROADMAP.md](../ROADMAP.md) | what was built, what remains outside this repo, and the declared non-goals |
| [ADR-0001](ADR-0001-session-format-is-arias-not-ours.md) | why the session file uses the compatible flat shape when we could design a better one |
| [ADR-0002](ADR-0002-do-not-own-the-transport.md) | why `net.http` does the wire work and this repo does not rewrite it |
| [ADR-0003](ADR-0003-pure-over-c-shim.md) | what "pure V" is allowed to mean |
| [compat/fluxget.md](compat/fluxget.md) | the exact `aria2.*` subset Fluxget calls, so the cut-over is a list and not a guess |

## What is deliberately not here

- **No CHANGELOG.** `git log` is the changelog and the messages are written to be
  read. A file that repeats them drifts.
- **No design doc for each module.** The modules carry their own doc comments, and
  the rule this repo works to is that the code and its explanation live together.
- **No FAQ.** If the same question is asked twice it belongs in a doc above.
