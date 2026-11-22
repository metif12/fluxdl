# Architecture

The shape of the repo is an answer to one question: which parts can be proven
without a network? Everything that can is kept pure, and everything that cannot
is pushed into one file.

## The dependency direction

```
main.v
  ├── internal/plan      pure arithmetic
  ├── internal/link      pure text
  ├── internal/session   files, but no sockets
  ├── internal/transfer  manager (pure) ──> Fetcher interface
  │                                          └── http_fetcher.v ──> net.http
  └── internal/rpc       JSON-RPC shape ──> transfer.Fetcher
```

Dependencies only point down. `plan` does not know about HTTP. `transfer` knows
about byte ranges but not about sockets: it takes a `Fetcher` with two methods,
`head` and `fetch`. `http_fetcher.v` is the only implementation that exists in
production and the only file in the engine that opens a connection.

That seam is the reason `v test` is network-free. A test can supply a fetcher
that writes deterministic bytes at a segment offset and still exercise resume,
failure handling and the collapsed-to-one-segment path.

## Why the split is worth it

A download manager's interesting failures are in the manager, not the wire:

- a range that overlaps by one byte, or ends one byte past the file;
- a resume that trusts a stale offset and refetches from zero;
- a progress counter that finishes at 150%;
- a server that ignores `Range`, turning N connections into N full copies.

All four are arithmetic and accounting. They are tested against strings and
temp files, which means they are tested on every commit rather than only when
someone has a spare network.

## The transfer path

1. **Probe.** `HttpFetcher.head` requests `bytes=0-0`. A 206 gives the total via
   `Content-Range` and means ranges are honoured; a 200 means they are not, and
   the total comes from `Content-Length`.
2. **Plan.** `plan.resume_plan` subtracts the bytes already on disk. If ranges
   are unsupported, `plan.plan(total, 1, 0)` is used instead and the resume
   offset is discarded — without `Range` there is no way to ask for the tail.
3. **Create once.** The output file is created and sized before any worker
   starts. Workers then open it with `r+b` and seek to their own offset.
4. **Fetch concurrently.** One `http.Downloader` per segment writes chunks at
   its offset. Results come back over a channel; a failed segment fails the
   whole download.
5. **Account.** Only the collecting loop updates the progress counter, so no
   mutex is needed for it.

## The session file is the contract

`internal/session` writes aria2c's `--save-session` format on purpose. A file
the old engine wrote must be a file the new one reads, and the other way round;
that is what makes the cut-over reversible. Writes go to a sibling temporary
file and are renamed over the target, so a power cut leaves the file valid or
absent. A corrupt line costs one entry, never the queue.

See [ADR-0001](ADR-0001-session-format-is-arias-not-ours.md).

## The RPC layer

`internal/rpc` is a state machine plus a JSON encoder. It holds the queue and
the settings document behind one mutex, and answers the subset of `aria2.*`
Fluxget actually calls. Every numeric field on the wire is a string, and the
leading `token:` argument is stripped before dispatch — including for
`system.multicall`, whose inner calls do not repeat it.

See [RPC.md](RPC.md) and [compat/fluxget.md](compat/fluxget.md).

## What is deliberately absent

- No HTTP stack of our own. TLS, redirects and chunked encoding belong to
  V's `net.http` ([ADR-0002](ADR-0002-do-not-own-the-transport.md)).
- No C shims. "Pure V" means no `C.` declarations and no vendored C
  ([ADR-0003](ADR-0003-pure-over-c-shim.md)).
- No supervision in this repo. Fluxget owns restart, backoff and readiness.
- No BitTorrent. The security surface is an open question, not a hidden yes.
