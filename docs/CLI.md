# CLI reference

`fluxdl` is a single binary with two kinds of commands: pure ones that inspect
the engine's decisions, and live ones that touch the network.

Build with V 0.5.2:

```powershell
v build -o fluxdl.exe .
```

## Pure commands

These never open a socket. They are safe to run against arbitrary input and are
what the module tests are built around.

### `fluxdl plan <url> <bytes> [connections] [min-segment]`

Prints the byte ranges a download would fetch, both fresh and resumed from half
the file. The point is the arithmetic: even segments, the remainder on segment
zero, nothing past the end.

```powershell
./fluxdl.exe plan https://example.com/big.bin 1048576 4
```

### `fluxdl session <path>`

Reads an aria2-format session file and prints how many downloads came back and
how many lines were lost to corruption. A corrupt line costs one entry, never
the queue; the loss count is the interesting half of the output.

### `fluxdl suggest <url>`

Prints the folder a URL implies. The last path segment is the file, the one
before it is the suggestion. It is deliberately shallow — a guess that reaches
further is a guess the user has to undo.

## Live commands

These open network connections and take the same path the RPC server takes.
`download` also accepts `ftp://` and `sftp://` URLs; `torrent` and `seed` use
the BitTorrent modules.

### `fluxdl download <url> [options]`

Fetches one URL into one file, resuming from the bytes already on disk.

| Option | Meaning | Default |
|---|---|---|
| `-d <dir>` | output directory | `FLUXDL_DIR`, else the current directory |
| `-o <name>` | output file name | derived from the URL and sanitised |
| `-x <n>` | connections (byte ranges) | `4` |
| `--min-segment <bytes>` | below this, use one connection | `0` |

```powershell
./fluxdl.exe download https://example.com/big.iso -x 8 -d D:/Downloads
```

The output file is created once before the workers start and is only shrunk when
a stale copy is longer than the plan. Each worker opens its own handle at its
own offset, so a resume writes only the remainder and a failed transfer cannot
leave a padded file that looks complete. If the server ignores `Range` and
answers 200, the one-byte probe catches it and the download collapses to a
single connection from byte zero.

### `fluxdl serve [options]`

Runs the loopback JSON-RPC server Fluxget talks to. Bind it to loopback: the
secret is a bearer token, and this is not a public API.

| Option | Meaning | Default |
|---|---|---|
| `--addr <host:port>` | listen address | `127.0.0.1:9009` |
| `--secret <token>` | required leading `token:` argument | `FLUXDL_SECRET` |
| `--session <path>` | aria2-format session file | `FLUXDL_SESSION`, else `~/.fluxdl/session` |

```powershell
./fluxdl.exe serve --addr 127.0.0.1:9009 --secret change-me --session D:/Downloads/fluxdl.session
```

A minimal readiness check (the server also answers `GET /health` with 200 once
the session is restored):

```powershell
curl -s -X POST http://127.0.0.1:9009/jsonrpc `
  -H 'Content-Type: application/json' `
  -d '{"jsonrpc":"2.0","id":1,"method":"aria2.getVersion","params":["token:change-me"]}'
```

See [RPC.md](RPC.md) for every method and its shape.

### `fluxdl torrent <path> [-d dir]`

Downloads a `.torrent` — or a magnet URI with `xt=urn:btih:...` — using HTTP
trackers, DHT fallback, PEX and the peer wire protocol. Pieces are chosen
rarest-first and verified against the SHA1 hashes in the metainfo.

### `fluxdl seed <path> [-d dir] [-p port]`

Serves a completed torrent to inbound peers over TCP. Seeding is opt-in; a
download does not automatically become an upload.

### `fluxdl metalink <path>`

Prints the files, URLs and hashes declared by a Metalink 4 document. To queue
the downloads, use the `aria2.addMetalink` JSON-RPC method instead.

### `fluxdl --version`

Prints the version and exits. Equivalent to `-V`.
