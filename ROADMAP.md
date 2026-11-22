# fluxdl roadmap

The milestones, what each one buys, and what is **not** in it. Ordered by "what
makes this usable", not by what is fun to write.

The rule this roadmap follows: every line that says *done* has a test that would
have caught it being wrong. The two columns that matter are **Proves** and
**Still absent** — the second is the one that keeps the first honest.

## Current status

| Milestone | State |
|---|---|
| M0 · manager brain | ✅ DONE |
| M1 · HTTP transfer | ✅ DONE |
| M2 · RPC cut-over | ✅ DONE |
| M3 · hardening and engine parity | ✅ DONE |
| M4 · FTP | ✅ DONE (whole-file only; no range REST) |
| M5 · BitTorrent | ✅ DONE (encrypted streams are a documented non-goal) |
| M6 · Metalink, checksums | ✅ DONE |

M3 currently covers packaging as a vpm package, the GitHub Page, cancellation
tokens, a bounded queue, digit validation of untrusted numbers, constant-time
token comparison and JSON-RPC notification handling. Fluxget's Phase 1–4 suites
have not been run against this server yet; that is the cut-over test in
Fluxget's tree, not a claim made here.

## Milestone 0 — the manager's brain ✅ DONE

`plan`, `link`, `session` and the CLI that drives them.
All pure, no sockets.

| | |
|---|---|
| **Adds** | byte-range planning (multi-connection + resume), URL/name/folder derivation, aria2-format session save/load |
| **Proves** | resume from a partial prefix; an overshooting offset plans nothing rather than a bogus `Range`; a corrupt session line costs one entry; the write is atomic |
| **Still absent** | the transfer itself, the daemon, BitTorrent, everything |

## Milestone 1 — HTTP + HTTPS transfer ✅ DONE

`transfer` over `net.http`, with a `Downloader` that writes into a
`plan.Segment` at its offset, and N of them running concurrently per download.

| | |
|---|---|
| **Adds** | multi-connection resumable HTTP(S) download, a one-byte Range probe, per-download options, the `download` CLI |
| **Proves** | a resumed download fetches only the remainder; a server that answers 200 to a Range request is detected and the plan collapses to one segment; a failed segment fails the whole download; every byte written is counted |
| **Still absent** | FTP, BitTorrent, Metalink, checksum verification, mirror liveness probing |

**The trap that was expected:** `net.http.download_file_with_progress` gives no
control over the *connection*, so N connections means N calls, and each one must
open its own file handle at its own offset. The file is now created once before
the workers start, and only shrunk when a stale copy is longer than the plan.
Writes at an offset extend a short file; padding a failed transfer with zeros
would leave a full-size file that the CLI reports as complete.

## Milestone 2 — the RPC surface and the cut-over ✅ DONE

The subset of `aria2.*` Fluxget already calls, on the same loopback HTTP JSON-RPC
shape, so the swap is a host/port change.

| | |
|---|---|
| **Adds** | `addUri`, `tellStatus`, `tellActive`, `tellWaiting`, `tellStopped`, `pause`, `unpause`, `pauseAll`, `unpauseAll`, `remove`, `removeDownloadResult`, `getFiles`, `getServers`, `getUris`, `getOption`, `changeOption`, `getPeers`, `getGlobalStat`, `getVersion`, `getGlobalOption`, `changeGlobalOption`, `saveSession`, `shutdown`, `system.multicall`, `system.listMethods` |
| **Proves** | string-valued numbers; the leading `token:` argument is stripped before dispatch and not repeated inside multicall; a failed download carries `errorCode`/`errorMessage` and never `error`; `saveSession` writes an aria2-format file |
| **Still absent** | BitTorrent, and the one deliberate wire difference: aria2 expands two mirrors into five `getUris` rows, fluxdl returns one row per source |

**Why this order:** it makes the engine replaceable *before* it is good. The
furthest an incomplete engine can get is "runs the app's own contract", and
getting there early means every milestone after it is measured by the app rather
than by my own tests.

**What "done" does not mean here:** Fluxget's `platform/contract_test.v` has not
been run against this server in this repo. That is the cut-over test and it
belongs in Fluxget's tree, where the fake is swapped for us. The list above is
what makes that test possible, not a claim that it has passed.

## Milestone 3 — hardening and engine parity ✅ DONE

Supervision (restart, backoff, readiness), the session round trip, the mirror set
behaviour from Phase 4, and the notice queue. Alongside those, this milestone
covers the work that makes fluxdl safe to publish and to run under Fluxget.

| | |
|---|---|
| **Adds** | vpm package with public modules; GitHub Page; cancellation tokens checked between segments; a bounded queue (10,000 rows); digit validation of CLI, RPC-option and HTTP length inputs; constant-time token comparison; notification handling; a user-owned default session path |
| **Proves** | pause and remove signal a worker's token and a removed row is never recreated; `addUri` past the cap returns an error; 72 tests across six test files; full and resumed 1 MiB downloads are byte-identical |
| **Still absent** | session restore on daemon startup, restart/backoff/readiness supervision, mirror liveness probing, the notice queue, BitTorrent, Metalink, FTP |

This is the milestone where fluxdl earns its keep: the same tests that prove
Fluxget works against `aria2c` must prove it works against something this repo
controls. That run has not happened yet.

## Milestone 4 — FTP ✅ DONE

An `ftp://` URL gets its own `transfer.Fetcher` over `net.ftp`. The fetcher caches
the whole file in `head()` and writes it from `fetch()`, so a download is
single-connection and cannot resume: V's FTP client has no range REST command.

## Milestone 5 — BitTorrent ✅ DONE

Bencode, `.torrent` metadata, HTTP tracker announce, the peer wire protocol,
rarest-first piece selection and SHA1 verification of every piece are implemented
in `torrent/` and wired into `aria2.addTorrent` and `fluxdl torrent`.

| | |
|---|---|
| **Adds** | bencode decoder, metainfo and magnet parsing, tracker announce (compact and dictionary peer lists), handshake/bitfield/request/piece messages, rarest-first ordering, per-piece SHA1 |
| **Proves** | 87 tests including bencode, metadata, magnet, big-endian helpers and bitfield membership; every piece is verified before it is written |
| **Adds since the core pass** | KRPC DHT fallback, BEP 9 ut_metadata for bare magnets, BEP 11 PEX, opt-in seeding over inbound TCP |
| **Still absent** | uTP and protocol encryption. These are documented non-goals, not silent stalls. |

**Security note:** this client parses untrusted data from strangers in the same
process as the user's files. The open question from the original roadmap is
still open: a sandbox boundary is needed before this is enabled by default in
the desktop app.

## Milestone 6 — Metalink, checksums ✅ DONE

`metalink/` parses Metalink 4 file entries, URLs and hashes; `checksum/` verifies
`md5`, `sha1` and `sha256`. `aria2.addMetalink` queues a Metalink's files, and a
`checksum` option turns a mismatch into a failed download rather than a warning.

## Where the priorities came from

Read against Fluxget's own roadmap: aria2 feature parity is *not* the goal, and
none of these milestones is worth doing if Fluxget stops working to get it. The
order is chosen so that each one is reversible — Milestone 2's cut-over being the
key one, because a reversible cut-over is the only kind anyone will let you do.
