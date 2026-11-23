# Architecture

The shape of the repo is an answer to one question: which parts can be proven
without a network? Everything that can is kept pure, and everything that cannot
is pushed into one file.

## The dependency direction

```
main.v                 the CLI (also a library consumer)
  ├── plan              pure arithmetic
  ├── link              pure text
  ├── session           files, but no sockets
  ├── transfer          manager (pure) ──> Fetcher interface
  │                                       ├── http_fetcher.v ──> net.http
  │                                       ├── ftp/ ──> net.ftp
  │                                       └── sftp/ ──> external sftp client
  ├── transports        one registry mapping URL scheme → Fetcher factory
  ├── torrent           bencode, trackers, DHT, peer wire, seeding
  └── rpc/              JSON-RPC shape ──> transfer.Fetcher
        state.v         queue, caches, versions
        wire.v          request parsing and method dispatch
        encode.v        status-row JSON writer
        json.v          JSON value helpers
        supervise.v     readiness, notices, session restore, stall loop
        workers.v       download goroutines and queue mutations
```

`transports.Registry` is the single registration point: adding a scheme is one
`register()` call, and both the CLI and the RPC manager ask it for a fresh
fetcher. Adding an RPC method is one dispatch arm plus `method_names()`.

Dependencies only point down. `plan` does not know about HTTP. `transfer` knows
about byte ranges but not about sockets: it takes a `Fetcher` with two methods,
`head` and `fetch`. HTTP, FTP and SFTP are implementations behind that seam; the
BitTorrent modules are a separate transport path with their own framing and
verification. All of them stay behind CLI commands or the RPC server, never
inside `v test`.

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

`session/` writes aria2c's `--save-session` format on purpose. A file
the old engine wrote must be a file the new one reads, and the other way round;
that is what makes the cut-over reversible. Writes go to a sibling temporary
file and are renamed over the target, so a power cut leaves the file valid or
absent. A corrupt line costs one entry, never the queue.

See [ADR-0001](ADR-0001-session-format-is-arias-not-ours.md).

## The RPC layer

`rpc/` is a state machine plus a JSON encoder. It holds the queue and
the settings document behind one mutex, and answers the subset of `aria2.*`
Fluxget actually calls. Every numeric field on the wire is a string, and the
leading `token:` argument is stripped before dispatch — including for
`system.multicall`, whose inner calls do not repeat it.

Three details keep the hot paths cheap:

- The probe happens once. `aria2.addUri` gets the length, and the worker uses
  `transfer.download_with_meta` so the transfer does not probe a second time.
- Read-only RPC answers are cached at three levels: each `tellStatus` row is
  encoded once per `Download.version`, each whole `tell*` array once per queue
  version, and an identical read-only request reuses its entire envelope. State
  mutations bump the relevant version, so the next poll recomputes. Strings are
  escaped straight into the response builder rather than through a tree of
  dynamic values. The 5,000-poll / 100-row `tellActive` benchmark went from
  14.6 s originally to ~0.20 s with row and array caches, then to ~36 ms with
  envelope caching; the re-encoding path (500 polls that change every row) went
  from 1.65 s to ~0.29 s. `getGlobalStat` and `getGlobalOption` use the same
  version-keyed pattern (5,000 stat calls: 265 ms to 46 ms).
- A one-segment transfer skips the goroutine and wait group entirely; the
  benchmark for 5,000 small downloads went from 2.52 s to 0.16 s. Multi-segment
  transfers write into preallocated result slots instead of a channel (5,000
  four-segment transfers: 1.92 s to 1.62 s). Output files are only ever shrunk
  when stale, never padded with zeros, so a failed transfer cannot leave a
  full-size file that looks complete.

See [RPC.md](RPC.md) and [compat/fluxget.md](compat/fluxget.md).

## What is deliberately absent

- No HTTP stack of our own. TLS, redirects and chunked encoding belong to
  V's `net.http` ([ADR-0002](ADR-0002-do-not-own-the-transport.md)).
- No C shims. "Pure V" means no `C.` declarations and no vendored C
  ([ADR-0003](ADR-0003-pure-over-c-shim.md)).
- No OS-level service management. This repo exposes `/health` and a stall
  supervisor; Fluxget owns process restart and deployment.
- No BitTorrent uTP or protocol encryption. The core protocols are implemented,
  but the untrusted-data security surface still needs a sandbox boundary before
  the client is enabled by default in the desktop app.
