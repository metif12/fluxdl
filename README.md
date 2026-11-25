# fluxdl

[![docs](https://img.shields.io/badge/docs-fluxdl.dev-blue)](https://mahdir-ir.github.io/fluxdl/)
[![V 0.5.2](https://img.shields.io/badge/V-0.5.2-7f8caa.svg)](https://vlang.io)
[![license: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**fluxdl** is a download engine built from scratch in pure V, designed for speed
and a small, predictable binary. Multi-connection HTTP(S), BitTorrent, FTP/SFTP
and Metalink sit behind one transport interface, with the JSON-RPC surface
Fluxget already uses. No C shims, no second HTTP stack, no legacy code to carry.

**[Project site and documentation](https://mahdir-ir.github.io/fluxdl/)** ·
[Guides](docs/GUIDES.md) · [V module API](docs/API.md) ·
[Quick start](docs/CLI.md) · [Architecture](docs/ARCHITECTURE.md) ·
[RPC reference](docs/RPC.md) · [vpm package](docs/PACKAGE.md) ·
[Roadmap](ROADMAP.md)

## Install as a V package

```powershell
v install mahdir-ir.fluxdl                            # from vpm
v install --git https://github.com/mahdir-ir/fluxdl   # from source today
```

Add it to a project's `v.mod` with `v install` from inside that project. VPM
packages are imported under their full name (`mahdir_ir.fluxdl.plan` — the `-`
in the org name becomes `_` in V imports); a git
install of this repo uses the short prefix (`fluxdl.plan`):

```v
import mahdir_ir.fluxdl.plan
import mahdir_ir.fluxdl.link

fn main() {
	segs := plan.plan(1048576, 4, 0)
	for s in segs {
		println(s.range_header())
	}
	l := link.parse('https://example.com/archive.bin?token=abc') or { return }
	println(link.safe_name(l.name)) // archive.bin
}
```

The public modules are `plan`, `link`, `session`, `transfer`, `rpc`, `util`,
`checksum`, `metalink`, `ftp`, `sftp`, `transports` and `torrent`. See
[docs/PACKAGE.md](docs/PACKAGE.md) for the API surface and publishing notes.

## Why a new engine

A download manager needs transfers it can reason about. fluxdl starts from that
requirement: a small codebase where the manager is pure, the transports are
interchangeable, and the hot paths are measured rather than assumed.

1. **Speed by construction.** One-segment downloads skip goroutines entirely,
   range planning is arithmetic, status answers are cached by version, and
   checksums stream instead of loading whole files.
2. **One binary, one toolchain.** Pure V with no C shims or downloaded GPL
   binary; V's `net.http` owns the wire and this engine owns the manager.
3. **Replaceable protocols.** HTTP, FTP, SFTP and BitTorrent sit behind clear
   seams, so a new transport is one registration rather than a rewrite.
4. **Speak the app's language.** The loopback JSON-RPC method names and the
   flat session-file shape mean Fluxget can adopt it without a migration.

## What it does today

| | |
|---|---|
| **Multi-connection downloads over HTTP(S)** | One file, N ranges, `Range: bytes=first-last`. Even segments, remainder on segment zero, nothing past EOF — arithmetic that makes the progress bar finish when it looks finished. |
| **Resume** | Reads what is on disk and plans only the remainder. An offset that overshoots the file yields an empty plan rather than a request for a byte that does not exist. |
| **Servers that ignore `Range`** | A one-byte probe detects a 200 answer and collapses the download to one connection instead of writing N copies of the body into one file. |
| **Session save/restore in a compatible flat format** | `--save-session` shape, written atomically by rename, and a reader that loses **one** line on corruption rather than the whole queue. |
| **Mirror sets** | De-duplicated, ordered, and labelled by kind — a `.torrent` path is bytes, a magnet is its own protocol, a URL is HTTP. |
| **Per-download options** | Option names from the established session vocabulary apply per download. |
| **The JSON-RPC subset Fluxget calls** | `addUri`, `tellStatus`, `tellActive/Waiting/Stopped`, pause/unpause, remove, `getFiles`, `getUris`, `getOption`, `changeOption`, global stat/options, `saveSession`, `shutdown`, `system.multicall`, `system.listMethods`, plus `addTorrent`, `addMagnet`, `addMetalink` and `getNotices` — on the same loopback POST shape, with string-valued numbers and the leading `token:` argument. |
| **FTP** | An `ftp://` URL uses a `net.ftp`-backed fetcher. Whole-file only, because V's FTP client has no range REST. |
| **BitTorrent core** | Bencode, `.torrent` metadata, HTTP trackers, the peer wire protocol, rarest-first piece selection and SHA1 verification of every piece. |
| **Metalink and checksums** | Metalink 4 files and URLs, plus `md5`/`sha1`/`sha256` verification of a completed download. |
| **SFTP** | `sftp://` URLs use an argv-based `sftp` client through a batch file; no shell quoting. |
| **BitTorrent discovery and seeding** | DHT fallback, PEX and magnet metadata exchange; opt-in seeding over inbound TCP. |
| **Cookies and robots** | A cookie jar on HTTP responses and `robots.txt` checks before a request. |
| **Readiness and supervision** | `GET /health` plus a stall supervisor that restarts stuck downloads. |

Fluxget compatibility is deliberate and documented: `getUris` reports one row
per source, while the legacy engine expanded two URLs into five rows. The exact
differences are in [the compatibility note](docs/compat/fluxget.md).

## What it does not do

Honest, because a list like this is the only thing that makes the list useful.

- **Encrypted BitTorrent streams.** uTP and protocol encryption are not implemented.
- **The Fluxget cut-over test.** `platform/contract_test.v` lives in Fluxget and
  has not been run against this server.
- **External process management.** The daemon has a `/health` readiness check and
  a stall supervisor; Fluxget still owns OS-level restart of the daemon itself.

## Install and use

```powershell
git clone https://github.com/mahdir-ir/fluxdl.git
cd fluxdl
v build -o fluxdl.exe .          # V 0.5.2

# See what a 100 MiB download would fetch in eight ranges:
./fluxdl.exe plan https://example.com/big.bin 104857600 8

# Fetch it for real:
./fluxdl.exe download https://example.com/big.bin -x 8 -d D:/Downloads

# Fetch a torrent (tracker, DHT and magnet metadata all work):
./fluxdl.exe torrent ubuntu.iso.torrent -d D:/Downloads

# Seed a completed torrent to inbound peers:
./fluxdl.exe seed ubuntu.iso.torrent -d D:/Downloads -p 6881

# Inspect a Metalink document:
./fluxdl.exe metalink release.metalink

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
session/   session.v      the queue on disk, in a compatible flat format
transfer/                 the engine: probe, concurrent fetch, byte accounting
  transfer.v              pure manager; the transport is injected
  http_fetcher.v          the HTTP transport
ftp/                      an FTP transfer.Fetcher (whole file)
sftp/                     an SFTP transfer.Fetcher via the system client
transports/               one registry mapping URL schemes to fetchers
util/                     shared digit/hex/secret validators
checksum/                 md5/sha1/sha256 verification
metalink/                 Metalink 4 files and URLs
torrent/                  bencode, trackers, peer wire, SHA1 pieces
rpc/                      loopback JSON-RPC, split by concern
  rpc.v / methods.v       queue, caches, method registry
  wire.v                  request parsing and dispatch
  encode.v / json.v       status JSON writer and value helpers
  supervise.v / workers.v readiness, notices, download goroutines
docs/                     the GitHub Pages site and the decision records
```

`plan`, `link` and `session` are pure: no sockets, no files except the session's
own temp files, no time. `transfer` keeps its manager pure by taking a `Fetcher`
interface; HTTP, FTP and SFTP are separate transports. That is why the
interesting bugs are found without a network.

## Testing

```powershell
v test .                  # 102 tests across fourteen test files
v fmt -w .                # v fmt is law
```

V 0.5.2 is required. Tests are network-free. Network paths live behind the
`download`, `serve`, `torrent` and `seed` commands and the FTP/SFTP/BitTorrent
modules; they are exercised by hand or by Fluxget's contract suite, not by
`v test`.

## Network use

Tests are network-free and stay that way. Every network path is behind a CLI
command or the RPC server. The probe in `transfer/http_fetcher.v`
reads one byte to learn whether the server honours `Range` and what the total
length is; nothing is fetched speculatively.

## License

MIT — see [LICENSE](LICENSE).
