# fluxdl

[![docs](https://img.shields.io/badge/docs-fluxdl.dev-blue)](https://metif12.github.io/fluxdl/)
[![V 0.5.2](https://img.shields.io/badge/V-0.5.2-7f8caa.svg)](https://vlang.io)
[![license: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**fluxdl** is a pure-V download engine for Fluxget: multi-connection HTTP(S),
resumable transfers, aria2-format session files, and the same JSON-RPC surface
Fluxget already calls. It is the transfer manager, not a fork of aria2 — so the
cut-over is a host-and-port change, and reverting is the same change backwards.

**[Project site and documentation](https://metif12.github.io/fluxdl/)** ·
[Quick start](docs/CLI.md) · [Architecture](docs/ARCHITECTURE.md) ·
[RPC reference](docs/RPC.md) · [vpm package](docs/PACKAGE.md) ·
[Roadmap](ROADMAP.md)

## Install as a V package

```powershell
v install metif12.fluxdl                            # from vpm once registered
v install --git https://github.com/metif12/fluxdl   # from source today
```

Add it to a project's `v.mod` with `v install` from inside that project. VPM
packages are imported under their full name (`metif12.fluxdl.plan`); a git
install of this repo uses the short prefix (`fluxdl.plan`):

```v
import metif12.fluxdl.plan
import metif12.fluxdl.link

fn main() {
	segs := plan.plan(1048576, 4, 0)
	for s in segs {
		println(s.range_header())
	}
	l := link.parse('https://example.com/archive.bin?token=abc') or { return }
	println(link.safe_name(l.name)) // archive.bin
}
```

The five public modules are `plan`, `link`, `session`, `transfer` and `rpc`.
See [docs/PACKAGE.md](docs/PACKAGE.md) for the API surface and publishing notes.

## Why this exists

Fluxget is a download manager built on top of `aria2c` as a child process. That
was the right call and it is documented in
[ADR-0003](https://github.com/metif12/fluxget/blob/main/docs/ADR/0003-compete-without-owning-the-transfer.md):
owning the transfer means owning BitTorrent's attack surface, and a download
manager with a webview in it should not.

This repo exists for the three reasons a fork of C++ is not a good answer, and
it is scoped to those:

1. **Fluxget runs on Windows only today, and aria2c ships as a GPL binary from a
   script.** A pure-V engine is built by the same `v` that builds the app.
2. **The protocol a desktop download manager actually needs is HTTP.** BitTorrent
   is the 30% that costs 80% of the code, and it is not needed for a first release.
3. **A compile error is a build failure; a segfault in `aria2c 1.37.0` at 3am is a
   bug report with no stack.**

## What it does today

| | |
|---|---|
| **Multi-connection downloads over HTTP(S)** | One file, N ranges, `Range: bytes=first-last`. The split is even with the remainder on segment zero, which is what aria2 does and what makes the progress bar finish when it looks finished. |
| **Resume** | Reads what is on disk and plans only the remainder. An offset that overshoots the file yields an empty plan rather than a request for a byte that does not exist. |
| **Servers that ignore `Range`** | A one-byte probe detects a 200 answer and collapses the download to one connection instead of writing N copies of the body into one file. |
| **Session save/restore in aria2's own format** | `--save-session` written flat, atomic by rename, and a reader that loses **one** line on corruption rather than the whole queue. |
| **Mirror sets** | De-duplicated, ordered, and labelled by kind — a `.torrent` path is bytes, a magnet is its own protocol, a URL is HTTP. |
| **Per-download options** | Where aria2's own option names apply. |
| **The JSON-RPC subset Fluxget calls** | `addUri`, `tellStatus`, `tellActive/Waiting/Stopped`, pause/unpause, remove, `getFiles`, `getUris`, `getOption`, `changeOption`, global stat/options, `saveSession`, `shutdown`, `system.multicall`, `system.listMethods` — on the same loopback POST shape, with string-valued numbers and the leading `token:` argument. |

What it reads is what `aria2c 1.37.0` was measured to write on this machine: a
multi-mirror `addUri` comes back from `aria2.getUris` as **five rows for two
URLs**, because aria2 expands the set internally. fluxdl reports one row per
source instead; that difference is deliberate and is called out in
[the compatibility note](docs/compat/fluxget.md).

## What it does not do

Honest, because a list like this is the only thing that makes the list useful.

- **BitTorrent.** The whole protocol: swarm, peers, trackers, DHT, PEX, piece
  selection, the rarest-first policy. This is the 80%.
- **Metalink.**
- **FTP / SFTP** (aria2's `net.ftp` has something to build on).
- **Checksums** — algorithm dispatch, and the resume question of which checksum
  wins when two definitions disagree.
- **Cookie/robots handling, mirror liveness probing.**
- **The daemon part** — Fluxget already owns supervision (restart, backoff,
  readiness) in `aria2ctl/`. This is the engine and its RPC server.

## Install and use

```powershell
git clone https://github.com/metif12/fluxdl.git
cd fluxdl
v build -o fluxdl.exe .          # V 0.5.2

# See what a 100 MiB download would fetch in eight ranges:
./fluxdl.exe plan https://example.com/big.bin 104857600 8

# Fetch it for real:
./fluxdl.exe download https://example.com/big.bin -x 8 -d D:/Downloads

# Run Fluxget's JSON-RPC surface on loopback:
./fluxdl.exe serve --addr 127.0.0.1:9009 --secret change-me --session D:/Downloads/fluxdl.session
```

Full CLI reference: [docs/CLI.md](docs/CLI.md).

## Layout

```
v.mod
main.v                    the CLI
plan/      plan.v         how one download is split into byte ranges
link/      link.v         what an address means, and what to call the file
session/   session.v      the queue on disk, in aria2's format
transfer/                 the engine: probe, concurrent fetch, byte accounting
  transfer.v              pure manager; the HTTP path is injected
  http_fetcher.v          the only file here that opens a socket
rpc/                      loopback JSON-RPC, exactly the subset Fluxget calls
docs/                     the GitHub Pages site and the decision records
```

`plan`, `link` and `session` are pure: no sockets, no files except the session's
own temp files, no time. `transfer` keeps its manager pure by taking a `Fetcher`
interface; only `http_fetcher.v` uses `net.http`. That is why the interesting
bugs are found without a network.

## Testing

```powershell
v test .                  # 62 tests across five module test files
v fmt -w .                # v fmt is law
```

V 0.5.2 is required. Tests are network-free. The `download` and `serve`
commands are the only paths that touch a socket, and both are exercised by hand
or by Fluxget's own contract suite, not by `v test`.

## Network use

Tests are network-free and stay that way. Every network path is behind a CLI
command or the RPC server. The probe in `transfer/http_fetcher.v`
reads one byte to learn whether the server honours `Range` and what the total
length is; nothing is fetched speculatively.

## License

MIT — see [LICENSE](LICENSE).
