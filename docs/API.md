# V module API

fluxdl is a V package with twelve public modules. Install it with
`v install mahdir-ir.fluxdl` and import any module by its last path component:

```v
import mahdir_ir.fluxdl.plan
import mahdir_ir.fluxdl.transfer
```

A git install (`v install --git https://github.com/mahdir-ir/fluxdl`) uses the
short prefix `fluxdl.*`. See [PACKAGE.md](PACKAGE.md) for installation details.

## plan — byte-range arithmetic

Pure functions, no sockets.

| Symbol | Purpose |
|---|---|
| `Segment` | `{ index, first, last }`; inclusive byte range |
| `plan(length i64, connections int, min_segment i64) []Segment` | even split, remainder on segment zero, one connection for small files |
| `resume_plan(length, connections, min_segment, done i64) []Segment` | same, minus a completed prefix; overshoot returns an empty plan |
| `s.range_header() string` | `bytes=first-last` |
| `s.len() i64`, `s.covers(pos i64) bool`, `total_len(segs []Segment) i64` | range helpers |

```v
for seg in plan.plan(1048576, 4, 0) {
	println(seg.range_header())
}
```

## link — addresses and filenames

| Symbol | Purpose |
|---|---|
| `Kind` | `.url`, `.magnet`, `.file` |
| `Link` | `raw`, `kind`, `host`, `path`, `name`, `folder` |
| `parse(raw string) !Link` | classify and normalise an address |
| `safe_name(raw string) string` | Windows-safe filename |
| `suggest(raw string) string` | implied folder, or empty |
| `magnet_name`, `percent_decode`, `base_name` | lower-level text helpers |

## session — the queue on disk

| Symbol | Purpose |
|---|---|
| `Entry` | `uri` plus aria2-compatible option names in `options` |
| `encode(entries []Entry) string`, `decode(raw string) ([]Entry, int)` | flat text format; one corrupt line costs one entry |
| `save(path string, entries []Entry) !`, `load(path string) ([]Entry, int)` | atomic temp-file-plus-rename write |

## transfer — the manager

`Fetcher` is the transport seam. Implement `head(url) !Meta` and
`fetch(url, seg, path) !i64` to add a transport.

| Symbol | Purpose |
|---|---|
| `Meta` | `length`, `ranges`; from a one-byte probe |
| `Fetcher` | interface with `head` and `fetch` |
| `Options` | `connections`, `min_segment`, `cancel` |
| `Cancel`, `new_cancel()` | lock-free stop token; `stop()`, `is_stopped()` |
| `Progress` | `value`, `add(n)`; single-writer byte counter |
| `HttpFetcher`, `new_http_fetcher()` | HTTP(S) transport with cookies and robots rules |
| `download(...)`, `download_with_meta(...)` | plan, fetch concurrently, account for bytes |

```v
mut fetcher := transfer.new_http_fetcher()
meta := fetcher.head(url) or { return }
mut progress := &transfer.Progress{}
transfer.download_with_meta(url, meta, meta.length, 0, path, transfer.Options{
	connections: 4
}, fetcher, mut progress) or { return }
```

## transports — scheme registry

| Symbol | Purpose |
|---|---|
| `Registry`, `new()` | built-in http/https/ftp/sftp factories |
| `with_http(fetcher &transfer.Fetcher) &Registry` | share one HTTP fetcher (cookies/robots across downloads) |
| `register(scheme string, factory Factory)` | add or replace a transport |
| `fetcher_for(url string) ?&transfer.Fetcher` | case-insensitive scheme lookup |

Adding a protocol is one `register()` call; see
[Extend fluxdl](GUIDES.md#extend-fluxdl).

## rpc — JSON-RPC daemon

| Symbol | Purpose |
|---|---|
| `Manager`, `new_manager(secret, session_path) &Manager` | queue, caches, supervisor |
| `handle_payload(raw string) string` | answer one JSON-RPC request |
| `serve(addr, secret, session_path)` | block on a loopback HTTP server |
| `restore_session() int` | re-queue a saved session at startup |
| `drain_notices() []string` | pending human-readable events |
| `is_ready() bool` | readiness after restore |
| `supervise()` | stall-restart loop (started by `serve`) |

Wire details are in [RPC.md](RPC.md).

## util — shared validators

| Symbol | Purpose |
|---|---|
| `all_digits`, `int_or`, `i64_or` | strict numeric parsing; V's `int()` accepts trailing garbage |
| `decode_hex_pair` | one `%XX` escape to a byte |
| `secure_equal` | constant-time secret comparison |

## checksum, metalink, ftp, sftp, torrent

| Module | Key API | Purpose |
|---|---|---|
| `checksum` | `hash_bytes`, `hash_file`, `verify_file` | streaming md5/sha1/sha256; mismatch fails a download |
| `metalink` | `MetalinkFile`, `parse` | Metalink 4 files, URLs, hashes |
| `ftp` | `Fetcher`, `new_fetcher`, `parse_target` | whole-file FTP downloads |
| `sftp` | `Fetcher`, `new_fetcher`, `parse_target` | whole-file SFTP via the system client |
| `torrent` | `Torrent`, `parse`, `parse_magnet`, `download`, `resolve_magnet`, `seed`, `new_dht`, `announce`, `handshake` | bencode, trackers, DHT/PEX/magnets, peer wire, SHA1 pieces, seeding |

A runnable consumer is in [`examples/library.v`](../examples/library.v).
