# V module API

fluxdl is a V package with twelve public modules. Install it with
`v install mahdir-ir.fluxdl` and import any module by its last path component:

```v
import mahdir_ir.fluxdl.plan
import mahdir_ir.fluxdl.transfer
```

A git install (`v install --git https://github.com/mahdir-ir/fluxdl`) uses the
short prefix `fluxdl.*`. See [PACKAGE.md](PACKAGE.md) for installation details.
Because the org name contains a hyphen, V normalizes it to an underscore in
import paths: install `mahdir-ir.fluxdl`, write `mahdir_ir.fluxdl`.

## Conventions used by every module

- Fallible functions return `!T`. The error strings below are quoted exactly as
  the code produces them, with the `module: ` prefix intact, so a caller can
  match on them.
- Pure modules (`plan`, `link`, `session`, `util`, `checksum`, `metalink`) never
  touch the network. Anything that does is behind `transfer`, `ftp`, `sftp`,
  `torrent` or `rpc`, and `v test` never opens a socket.
- An empty plan, an empty queue and an empty peer list are normal values, not
  errors. Only corrupt or contradictory input is an error.

## plan — byte-range arithmetic

```v
import mahdir_ir.fluxdl.plan
```

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

Rules, in the order they are applied:

1. A download shorter than `min_segment` (per connection) is one connection.
   Splitting a 1 MiB file eight ways costs eight round trips and finishes no
   sooner. A `connections` value of zero or less also means one connection —
   the caller means "I do not know", not "no connections".
2. `length <= 0` yields an empty plan, never a negative range.
3. The split is even and the remainder goes to segment **zero**, matching
   aria2, so a progress bar never finishes 1% early and then sits there.
4. When even division cannot give every connection at least one byte, the plan
   collapses to one connection rather than emitting empty segments.

`resume_plan` shifts every segment of `plan(remaining, …)` forward by `done`.
`done <= 0` delegates to `plan`; `done` at or past `length` yields an empty
plan — an overshoot is a stale control file, not a panic.

`Segment.len()` returns 0 when `last` is before `first`, so a bug is visible
where it happens. `covers` is inclusive at both ends, like the header.

## link — addresses and filenames

```v
import mahdir_ir.fluxdl.link
```

Pure text: what an address means, and what to call the file it produces.

| Symbol | Purpose |
|---|---|
| `Kind` | `.url`, `.magnet`, `.file` — decides how an address is added |
| `Link` | `raw`, `kind`, `host`, `path`, `name`, `folder` |
| `parse(raw string) !Link` | classify and normalise an address |
| `magnet_name(raw string) string` | display name from a magnet's `dn=` parameter |
| `percent_decode(s string) string` | `%XX` escapes plus `+`-as-space |
| `base_name(path string) string` | last segment, on either separator |
| `safe_name(raw string) string` | Windows-safe filename, never empty |
| `suggest(raw string) string` | implied folder, or empty |

```v
l := link.parse('https://example.com/releases/v0.4.0/fluxdl.exe?token=abc')!
println(l.name)   // fluxdl.exe — the query string is not part of the name
println(l.folder) // v0.4.0    — the second-to-last segment, a suggestion only
```

`parse` accepts three shapes and nothing else:

- `magnet:…` → `kind: .magnet`, name from `dn=`, no host or folder.
- a path ending in `.torrent` (case-insensitive) → `kind: .file`, backslashes
  normalised, name from the last segment.
- `http://` or `https://` (case-insensitive) → `kind: .url`, query string and
  fragment stripped before the name is derived, a trailing slash falling back
  to the host as the name.

Anything else is `link: not a scheme Fluxget can fetch: …`; a blank string is
`link: empty`.

`magnet_name` percent-decodes the `dn=` value; a magnet with no `dn=` yields
`''`. `percent_decode` handles both `%20` and `+`, and leaves a malformed
escape's `%` literal rather than guessing. `safe_name` strips `: * ? " < > |`,
both slashes and control characters, trims whitespace, prefixes reserved
Windows device stems (`con`, `prn`, `aux`, `nul`, `com1`–`com4`, `lpt1`–`lpt3`)
with `_`, and returns `'download'` when nothing survives. `suggest` returns
`''` for any address that does not parse.

## session — the queue on disk

```v
import mahdir_ir.fluxdl.session
```

The aria2 `--save-session` flat format: one URL line, option lines with a
leading space, blank line between entries. Option names are aria2's own
dash-separated words (`max-connection-per-server`, `split`, `bt-max-peers`).
The format is compatible on purpose — the file the old engine wrote is one
this engine reads, so the cut-over is reversible. See
[ADR-0001](ADR-0001-session-format-is-arias-not-ours.md).

| Symbol | Purpose |
|---|---|
| `Entry` | `uri` plus `options map[string]string`, in read order |
| `encode(entries []Entry) string` | render; option keys sorted for stable bytes |
| `decode(raw string) ([]Entry, int)` | read; skips what it cannot understand |
| `save(path string, entries []Entry) !` | atomic temp-file-plus-rename write |
| `load(path string) ([]Entry, int)` | read a file; missing file is an empty queue |

```v
entries, skipped := session.decode(raw)
println('${entries.len} restored, ${skipped} line(s) dropped')
session.save(dir + '/fluxdl.session', entries)!
```

The one rule this module exists for: **a corrupt line loses one download, not
the queue.** `decode` returns the entries plus a skipped-line count, so a
caller can report "4 of 12 came back" instead of silently showing 8. A second
URL with no blank line is repaired (both load, neither counted as skipped);
an option line with an unacceptable name is skipped and the entry survives.
Reads are capped at 10 000 entries, so a hostile file cannot exhaust memory.

`save` creates missing parent directories, writes to `path + '.tmp'` and
renames over the target — the file is either fully written or not there at
all, and "not there" is a state the caller recovers from by starting empty.
`load` treats a missing file as a first run: `([]Entry{}, 0)`, no error.

## transfer — the manager

```v
import mahdir_ir.fluxdl.transfer
```

The engine half: decide which bytes to fetch, fetch them, count what came
back. The arithmetic and the counting live here and are tested without a
socket; the wire lives behind the `Fetcher` interface.

| Symbol | Purpose |
|---|---|
| `Meta` | `{ length, ranges }` from one short probe |
| `Fetcher` | interface with `head` and `fetch` — the transport seam |
| `Options` | `{ connections, min_segment, cancel &Cancel }` per-download knobs |
| `Cancel`, `new_cancel()` | shared stop flag; `stop()`, `is_stopped()` |
| `Progress` | `{ value }` byte counter; `add(n)` |
| `HttpFetcher`, `new_http_fetcher()` | HTTP(S) transport with cookies and robots rules |
| `HttpState` | cookie jar and robots cache shared by one fetcher's downloads |
| `download(...)`, `download_with_meta(...)` | plan, fetch concurrently, account for bytes |

```v
mut fetcher := transfer.new_http_fetcher()
meta := fetcher.head(url) or { return }
mut progress := &transfer.Progress{}
transfer.download_with_meta(url, meta, meta.length, 0, path, transfer.Options{
	connections: 4
}, fetcher, mut progress) or { return }
```

`head` implementations probe once; `fetch(url, seg, path)` writes exactly one
`plan.Segment` into `path` at its offset and returns the bytes written.
Nothing in this module knows that HTTP exists, which is what keeps the
interesting tests network-free — a fake `Fetcher` proves resume, single-
connection fallback and byte accounting in a unit test.

`download(url, known, done, path, opts, fetcher, progress)` probes first, then
delegates. `download_with_meta` skips the probe for callers that already have
one (a daemon that probed at add time must not pay a second round trip per
queue item). The probe's length wins when positive; a stale record is exactly
the case a resume has to survive. Unknown length is
`transfer: unknown length for …`.

Planning: `Range` support means `plan.resume_plan(total, …)` from the resume
offset; without it, one connection from byte zero — any `done` is discarded,
since the tail cannot be requested without `Range`. An empty plan writes 0
bytes and succeeds. The file is created once before any worker starts; a stale
file longer than the plan is truncated, never padded — padding a failed
download would make it look complete.

Concurrency: one segment needs no thread, channel or wait group — the common
case for small files and for servers that ignore `Range`. Otherwise each
worker owns one result slot and a wait group is the only synchronisation.
Failures report `transfer: N segment(s) failed: <first error>`; a cancelled
queue reports `transfer: cancelled`. The return value is how many bytes **this
call** wrote, not the file size — add the resume offset for completed bytes.

`Cancel` is a lock-free stop flag checked between segments; pause and remove
call `stop()`. `Progress.value` is written only by the collecting loop, so no
lock is needed, and the CLI and the daemon print the same number.

### `HttpFetcher` — the HTTP transport

`new_http_fetcher()` creates a fetcher with an empty cookie jar and robots
cache, shared across every download that uses the instance. Sharing one
instance preserves both across downloads; use
`transports.with_http(fetcher)` for that.

`head(url)` sends `Range: bytes=0-0` with a 64-byte probe cap — without the
cap, a server that ignores `Range` would make a one-byte probe pull the whole
body. A `206` with `Content-Range` reports `ranges: true` and the total; a
`200` reports `ranges: false` so the manager collapses to one connection.
Malformed answers are errors: a 206 without `Content-Range`, a bad range, or
a non-positive length.

`fetch(url, seg, path)` streams exactly one segment. V's
`http.download_file_with_progress` only forwards chunks for a 200, and a
ranged answer is 206 — so this uses `FetchConfig.on_progress_body`, which fires
for 206 too, writing each chunk at the segment's offset. Only 200 and 206
bodies are written; anything else is `transfer: HTTP <code> for …`. A short
segment is a corrupt download, not a success:
`transfer: segment <i> wrote <n> of <m> bytes`.

Both methods honour `robots.txt` (`User-agent: *` or mentioning `fluxdl`,
longest-match `Allow` beating `Disallow`, cached per origin, at most 1024
origins) and refuse with `transfer: robots.txt disallows …`. `Set-Cookie`
responses are remembered and replayed. A malformed URL is
`transfer: bad URL …`.

## transports — scheme registry

```v
import mahdir_ir.fluxdl.transports
```

The one place where URL schemes map to `transfer.Fetcher` implementations.
Adding a transport means registering a factory here; the CLI and RPC both ask
the registry, so there is no second registration site.

| Symbol | Purpose |
|---|---|
| `Factory` | `fn () &transfer.Fetcher` |
| `new() &Registry` | registry with the built-in http/https/ftp/sftp transports |
| `with_http(fetcher) &Registry` | reuse one HTTP fetcher (cookies/robots persist); FTP/SFTP still get a fresh fetcher per lookup |
| `register(scheme, factory)` | add or replace a transport |
| `fetcher_for(url) ?&Fetcher` | fresh fetcher for the URL's scheme, or none |

```v
mut reg := transports.new()
fetcher := reg.fetcher_for(url) or {
	eprintln('no transport for ${url}')
	return
}
```

The scheme is the lowercased prefix before `://`. FTP/SFTP get a fresh fetcher
per lookup on purpose: each caches a whole file body per URL, so sharing one
across downloads would be wrong. See [GUIDES.md](GUIDES.md#extend-fluxdl) for
the three-step transport recipe.

## ftp — whole-file FTP

```v
import mahdir_ir.fluxdl.ftp
```

A `transfer.Fetcher` backed by V's `net.ftp` client. `net.ftp` exposes
whole-file GET only, so an FTP URL is fetched once into a per-URL cache by
`head()` and written from there by `fetch()`. Ranges are reported as
unsupported, and the manager collapses to one connection.

| Symbol | Purpose |
|---|---|
| `Target` | `{ addr, user, pass, path }` |
| `parse_target(raw) !Target` | read `ftp://[user:pass@]host[:port]/path` |
| `Fetcher`, `new_fetcher()` | fetcher with an empty per-URL body cache |
| `head(url) !transfer.Meta` | download once, remember the bytes, report `{ length, ranges: false }` |
| `fetch(url, seg, path) !i64` | write the cached body at the segment offset |

Defaults: anonymous login (`anonymous` / `anonymous@`), port 21 when no port
is given. Errors keep the `ftp: ` prefix: not an `ftp://` URL, connect
failure, login failure, GET failure, and `ftp: no cached body for …` when
`fetch` is called without a prior `head` for the same URL.

## sftp — whole-file SFTP

```v
import mahdir_ir.fluxdl.sftp
```

An SFTP `transfer.Fetcher`. V has no SSH library, so this shells out to the
system `sftp` client with an argv vector and a batch file: no shell is
involved, and every path is a separate argument, so whitespace in filenames
cannot change the command.

| Symbol | Purpose |
|---|---|
| `Target` | `{ host, user, port, path }` |
| `parse_target(raw) !Target` | read `sftp://[user@]host[:port]/path`; default port 22 |
| `Fetcher`, `new_fetcher()` | fetcher with an empty per-URL body cache |
| `head(url) !transfer.Meta` | download via `sftp` into a temp file, cache it, report `{ length, ranges: false }` |
| `fetch(url, seg, path) !i64` | write the cached body at the segment offset |

A remote path must be absolute and contain no control character, `"` or `\` —
a batch file is line-oriented, and a newline in a path would become a new
command. Violations are `sftp: unsafe remote path …`; other failures are
`sftp: bad port …`, `sftp: no host`, `sftp: cannot write batch file`,
`sftp: client exited <code>`, `sftp: no file was downloaded`, and
`sftp: no cached body for …` on an unprimed `fetch`. Temp files live in the OS
temp dir as `fluxdl-sftp-<pid>-<mono>.bin`/`.batch` and are removed after the
probe.

## checksum — verify what arrived

```v
import mahdir_ir.fluxdl.checksum
```

md5/sha1/sha256 over bytes or a completed file. A checksum is only useful when
a mismatch changes the outcome, so `verify_file` returns a boolean the caller
must act on rather than logging a warning.

| Symbol | Purpose |
|---|---|
| `hash_bytes(data []u8, algo string) !string` | lowercase hex digest; algo names case-insensitive |
| `hash_file(path string, algo string) !string` | stream a file through the digest in 64 KiB chunks |
| `verify_file(path string, expected string) !bool` | pick the algorithm from the digest length and compare |

```v
ok := checksum.verify_file(path, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')!
```

Supported algorithms are `md5`, `sha1`, `sha256`; anything else is
`checksum: unsupported algorithm …`. `hash_file` never loads the whole file —
a 4 GiB download must not become a 4 GiB string to be verified.
`verify_file` trims and lowercases the expected digest and selects the
algorithm by length (32 → md5, 40 → sha1, 64 → sha256); any other length is
`checksum: expected digest must be 32, 40 or 64 hex chars`.

## metalink — files, URLs and hashes

```v
import mahdir_ir.fluxdl.metalink
```

The useful subset of a Metalink 4 document: files, their URLs and their
hashes. A Metalink is untrusted input, so unknown elements are ignored and
empty fields are skipped rather than trusted as filenames.

| Symbol | Purpose |
|---|---|
| `MetalinkFile` | `{ name, urls []string, hashes map[string]string }` |
| `parse(raw string) ![]MetalinkFile` | files declared in the document |

```v
for f in metalink.parse(raw)! {
	if 'sha256' in f.hashes {
		println('${f.name} ${f.hashes['sha256']}')
	}
}
```

Only `<file>` entries with a non-empty `name` attribute **and** at least one
non-empty `<url>` are returned. Hash elements are keyed by their `type`
attribute, defaulting to `sha256` when absent — the RPC layer prefers sha256,
then sha1, then md5 when it turns a Metalink into downloads.

## util — shared validators

```v
import mahdir_ir.fluxdl.util
```

Small validators used by the CLI, RPC and HTTP layers. One implementation of
"is this string really a number" matters: V's `String.int()`/`i64()` stop at
the first non-digit, so a successful parse is not validation. Every untrusted
numeric input goes through these helpers.

| Symbol | Purpose |
|---|---|
| `all_digits(s string) bool` | non-empty ASCII digits only |
| `int_or(s string, default_value int) int` | decimal int, or the default |
| `i64_or(s string, default_value i64) i64` | decimal i64, or the default |
| `decode_hex_pair(s string) ?u8` | exactly two hex digits into one byte |
| `secure_equal(a string, b string) bool` | constant-time comparison |

`int_or`/`i64_or` return the default for anything that is not all digits —
empty strings, signs, trailing garbage. `decode_hex_pair` returns `none` for
any input that is not exactly two hex digits. `secure_equal` loops over the
longer length without early exit, so timing depends only on the public lengths,
not on the contents; it guards the RPC secret on every request.

## torrent — bencode to seeding

```v
import mahdir_ir.fluxdl.torrent
```

Bencode, `.torrent` metadata, HTTP trackers, the peer wire protocol,
rarest-first piece selection with SHA1 verification of every piece, DHT/PEX
peer discovery, magnet metadata resolution and opt-in seeding. Every byte here
is untrusted: lengths are checked before slices, malformed values are errors
rather than panics.

### Metainfo and magnets (`metainfo.v`)

| Symbol | Purpose |
|---|---|
| `BValue` | `i64 \| string \| []BValue \| map[string]BValue` — one bencoded value |
| `Decoder` | `{ data, pos, info_raw }`; `info_raw` captures the info dict's exact bytes for the info hash |
| `decode(data []u8) !BValue` | parse one bencoded value |
| `TorrentFile` | `{ path, length }` |
| `Torrent` | `{ announce, name, piece_length, pieces, length, files, info_hash_raw }` |
| `parse(data []u8) !Torrent` | parse a `.torrent` file |
| `parse_magnet(uri string) !Torrent` | parse a magnet URI into a metadata-less torrent |

```v
meta := torrent.parse(os.read_file('ubuntu.iso.torrent')!)!
println('${meta.name}: ${meta.pieces.len} pieces of ${meta.piece_length} bytes')
```

`decode` rejects truncated integers, lists and dicts, non-string dict keys,
malformed string lengths and out-of-range slices. `parse` requires a dict root
with an info dict, a `pieces` string of whole 20-byte hashes, a non-empty
`name` and a positive piece length; multi-file torrents join each file's
`path` list with `/`, and a single-file torrent yields one `TorrentFile`.
`info_hash_raw` is the SHA1 of the info dict's exact bytes — the swarm's
identity for this torrent.

`parse_magnet` understands `xt=urn:btih:` in 40-char hex **or** 32-char
base32, plus `dn=` (percent- and `+`-decoded, falling back to the hash) and
the first `tr=` tracker. No `btih` is `torrent: magnet has no btih`.

### Trackers (`tracker.v`)

| Symbol | Purpose |
|---|---|
| `Peer` | `{ ip, port }` |
| `parse_compact_peers(raw []u8) ![]Peer` | decode 6-byte IP/port pairs |
| `announce(url, info_hash, peer_id, port, left) ![]Peer` | ask an HTTP tracker for peers |

`announce` sends `info_hash`, `peer_id`, `port`, `uploaded=0`,
`downloaded=0`, `left` and `compact=1` with `event=started`, and understands
both compact (binary string) and dictionary peer lists. An empty URL is
`torrent: magnet has no tracker`; a non-200 answer and a malformed bencoded
response are errors, never an empty list masquerading as success.

### Peers (`peer.v`)

| Symbol | Purpose |
|---|---|
| `Message` | `{ id, payload }` — one length-prefixed message; id 255 is a keepalive |
| `Conn` | an open peer connection (opaque handle) |
| `handshake(peer, info_hash, peer_id) !&Conn` | open and validate the 68-byte reply |
| `next_message() !Message` | read one message |
| `interested() !` | announce interest |
| `has_piece(index int) bool` | bitfield lookup |
| `wait_until_unchoke() !` | process messages until the peer allows requests |
| `piece(t, index) ![]u8` | download one piece, SHA1-verified |
| `close()` | release the socket |

`handshake` requires 20-byte `info_hash` and `peer_id`, sends the protocol
string with the extension-protocol bit (BEP 10, for magnet metadata and PEX)
set, and rejects a bad greeting or an info-hash mismatch. Messages larger than
1 MiB are rejected. `wait_until_unchoke` gives up after 100 messages or on a
choke. `piece` fetches in 16 KiB blocks and compares the SHA1 against the
metainfo — a mismatch is `torrent: piece <i> failed SHA1 verification`, and
the piece is never written. PEX peers discovered in extended messages (id 20)
accumulate on the connection, capped at 2048, and feed the download's peer
pool.

### Discovery (`dht.v`, `metadata.v`)

| Symbol | Purpose |
|---|---|
| `Dht`, `new_dht() &Dht` | KRPC client (BEP 5) with a random node ID |
| `find_peers(info_hash []u8) ![]Peer` | iterative lookup over bootstrap nodes |
| `fetch_metadata(mut c Conn, info_hash []u8) ![]u8` | BEP 9 `ut_metadata` download, SHA1-checked |
| `parse_pex(payload []u8) ![]Peer` | decode a `ut_pex` added list |

DHT is a fallback, not a routing table: `find_peers` walks
`router.bittorrent.com:6881` and `dht.transmissionbt.com:6881` in 4 rounds of
up to 8 parallel queries (a slow node no longer serialises the lookup),
capped at 2048 peers and 4096 queued nodes, ignoring replies from other
transactions. `fetch_metadata` caps metadata at 16 MiB and returns it only
when its SHA1 equals the magnet's info hash.

### Download and seed (`client.v`, `seed.v`)

| Symbol | Purpose |
|---|---|
| `resolve_magnet(magnet &Torrent) !&Torrent` | tracker → DHT → `ut_metadata` into a full `Torrent` |
| `download(t &Torrent, dir string) !string` | fetch a torrent, return the completed file path |
| `seed(meta &Torrent, dir string, port int) !` | serve completed pieces to inbound peers; blocks |

```v
meta := torrent.parse(os.read_file('ubuntu.iso.torrent')!)!
path := torrent.download(meta, 'D:/Downloads')!
println('complete: ${path}')
```

`download` resolves magnets first, refuses absurd lengths (empty or over
16 GiB — a malicious `.torrent` must not conjure a huge sparse file), creates
and sizes the output once, then connects: tracker peers first, DHT on empty,
handshake plus unchoke per peer, PEX-discovered peers joining up to 30
connections. Pieces go rarest-first — availability is counted across all
peers, sorted once (`O(n log n)`, which matters at tens of thousands of
pieces) — and each piece is SHA1-verified before it is written at its file
offset. `torrent: no peers …`, `torrent: no usable peers` and
`torrent: no peer supplied piece <i>` are distinct failures worth
distinguishing in a log.

Seeding is opt-in: a download never becomes an upload on its own. `seed`
requires the completed file to exist and then listens until the process ends,
answering handshakes (wrong info hash: silent drop), bitfield/unchoke, and
request messages up to 1 MiB from a file handle shared across peer threads.

## rpc — the JSON-RPC daemon

```v
import mahdir_ir.fluxdl.rpc
```

The aria2 JSON-RPC subset Fluxget already calls: same loopback HTTP shape,
same method names, same string-valued numbers. Fluxget's contract test is the
real definition of done; the wire quirks are recorded in
[compat/fluxget.md](compat/fluxget.md). Method reference and shapes live in
[RPC.md](RPC.md).

| Symbol | Purpose |
|---|---|
| `version` | `'0.4.0'` — reported by `getVersion`; keep in sync with `v.mod` |
| `Download` | one queue row: `gid`, `uri`, `uris`, `status`, `total`, `completed`, `path`, `dir`, `out`, `options`, `error_code`, `error_message`, `active_uri` |
| `Manager` | the queue, settings, caches and worker state (mutex-guarded) |
| `new_manager(secret, session_path) &Manager` | empty queue with aria2-like defaults |
| `Handler` | serves `POST /jsonrpc`; `handle(req) http.Response` |
| `serve(addr, secret, session_path)` | restore, mark ready, supervise, block on loopback |
| `handle_payload(raw string) string` | answer one JSON-RPC body |
| `supervise()` | restart stalled downloads per `supervisor-interval` / `stall-timeout` |
| `is_ready() bool` | readiness after session restore |
| `drain_notices() []string` | pending human-readable events, cleared on read |
| `restore_session() int` | re-queue the aria2-format session file; returns the entry count |
| `any_num_str(v json2.Any) string` | string-or-number to string (numbers arrive as strings on this wire) |

```v
mut m := rpc.new_manager('change-me', 'D:/Downloads/fluxdl.session')
m.restore_session()
println(m.handle_payload('{"jsonrpc":"2.0","id":1,"method":"aria2.getVersion","params":["token:change-me"]}'))
```

GIDs are zero-padded 16-digit counters (`0000000000000001`, …). Queue cap is
10 000 downloads; notices are bounded at 1024. Statuses are `active`,
`waiting`, `paused`, plus terminal states; `tellStopped` returns everything
that is not active, paused or waiting.

`new_manager` defaults: `dir` from `FLUXDL_DIR` or `~/Downloads`,
`max-connection-per-server` 4, `min-split-size` 1048576, `continue` true,
`max-retries` 0, `retry-delay` 1000, `supervisor-interval` 30,
`stall-timeout` 300.

`Handler.handle`: `GET /health` is 200 `{"status":"ok"}` once ready, 503
`{"status":"starting"}` before; anything but POST is 405. Three secrets are
accepted — leading `token:<secret>` param, `X-Rpc-Secret` header, `?token=`
query — and a wrong header/query token is rejected before parsing. A request
without an id is a notification: no body, HTTP 204.

`handle_payload`: a wrong `token:` is `-32000 Unauthorized`; unknown methods
are `-32601`; bad params are `-32602`. Numbers in results are strings,
including nested. Read-only methods (`tellStatus`, `tellActive/Waiting/
Stopped`, `getFiles/Uris/Servers/Peers`, `getOption`, `getGlobalStat`,
`getVersion`, `getGlobalOption`, `listMethods`) are served from a response
cache keyed by the secret-scrubbed request and invalidated on any queue or
settings mutation; per-row status JSON is cached per download version.
`system.multicall` fans out without repeating the token in inner calls.

`supervise` loops every `supervisor-interval` seconds and re-queues downloads
that have been `active` with zero progress longer than `stall-timeout`; either
option at zero disables it. Fluxget owns OS-level restart; this only restarts
stuck queue items. `serve` restores the session, marks ready, starts
supervision in the background and blocks — bind it to loopback, because the
secret is a bearer token, not a public API.

A runnable consumer of the package (not the daemon) is in
[`examples/library.v`](../examples/library.v).

## See also

- [GUIDES.md](GUIDES.md) — task walkthroughs: install, downloads, torrents, RPC, extension points.
- [PACKAGE.md](PACKAGE.md) — install, import paths, and the publishing checklist.
- [CLI.md](CLI.md) — every command and flag.
- [RPC.md](RPC.md) — the aria2 method subset and the wire quirks.
- [ARCHITECTURE.md](ARCHITECTURE.md) — the purity boundary and the transfer path.
- [compat/fluxget.md](compat/fluxget.md) — the exact compatibility differences.
