# aria2v roadmap

The milestones, what each one buys, and what is **not** in it. Ordered by "what
makes this usable", not by what is fun to write.

The rule this roadmap follows: every line that says *done* has a test that would
have caught it being wrong. The two columns that matter are **Proves** and
**Still absent** — the second is the one that keeps the first honest.

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
open its own file handle at its own offset. The file is now created and sized
once before the workers start — N workers racing to create it would each
truncate it, and the last truncate would win over bytes already written.

## Milestone 2 — the RPC surface and the cut-over ✅ DONE

The subset of `aria2.*` Fluxget already calls, on the same loopback HTTP JSON-RPC
shape, so the swap is a host/port change.

| | |
|---|---|
| **Adds** | `addUri`, `tellStatus`, `tellActive`, `tellWaiting`, `tellStopped`, `pause`, `unpause`, `pauseAll`, `unpauseAll`, `remove`, `removeDownloadResult`, `getFiles`, `getServers`, `getUris`, `getOption`, `changeOption`, `getPeers`, `getGlobalStat`, `getVersion`, `getGlobalOption`, `changeGlobalOption`, `saveSession`, `shutdown`, `system.multicall`, `system.listMethods` |
| **Proves** | string-valued numbers; the leading `token:` argument is stripped before dispatch and not repeated inside multicall; a failed download carries `errorCode`/`errorMessage` and never `error`; `saveSession` writes an aria2-format file |
| **Still absent** | BitTorrent, and the one deliberate wire difference: aria2 expands two mirrors into five `getUris` rows, aria2v returns one row per source |

**Why this order:** it makes the engine replaceable *before* it is good. The
furthest an incomplete engine can get is "runs the app's own contract", and
getting there early means every milestone after it is measured by the app rather
than by my own tests.

**What "done" does not mean here:** Fluxget's `platform/contract_test.v` has not
been run against this server in this repo. That is the cut-over test and it
belongs in Fluxget's tree, where the fake is swapped for us. The list above is
what makes that test possible, not a claim that it has passed.

## Milestone 3 — the engine Fluxget already has, in V ← NEXT

Supervision (restart, backoff, readiness), the session round trip, the mirror set
behaviour from Phase 4, and the notice queue.

| | |
|---|---|
| **Proves** | Fluxget's Phase 1–4 suites pass against aria2v without modification |
| **Still absent** | BitTorrent, Metalink, FTP |

This is the milestone where aria2v earns its keep: the same tests that prove
Fluxget works against `aria2c` now prove it works against something this repo
controls.

## Milestone 4 — FTP

`net.ftp` exists. Smallest of the missing protocols and a good test of whether the
architecture generalises.

## Milestone 5 — BitTorrent

The 80%. Swarm, peers, trackers, DHT/PEX, piece selection, rarest-first.

| | |
|---|---|
| **Proves** | a public-domain torrent finishes; a magnet resolves; a dead tracker does not stall the download |
| **Still absent** | seeding policy, encrypted streams, magnet extension negotiation |

**Open question, and it is the one that decides whether this milestone happens at
all:** whether the security surface is acceptable. A BitTorrent client parses
untrusted data from strangers in a process that also holds the user's files. The
answer may be "sandbox it", or it may be "Milestone 5 does not happen", and this
roadmap is not allowed to pretend otherwise.

## Milestone 6 — Metalink, checksums

The last of aria2's protocols, plus `md5`/`sha1`/`sha256` on a completed
download with the decided behaviour for a mismatch.

## Where the priorities came from

Read against Fluxget's own roadmap: aria2 feature parity is *not* the goal, and
none of these milestones is worth doing if Fluxget stops working to get it. The
order is chosen so that each one is reversible — Milestone 2's cut-over being the
key one, because a reversible cut-over is the only kind anyone will let you do.
