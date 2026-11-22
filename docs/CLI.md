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

These use `net.http` and take the same path the RPC server takes.

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

The file is created and sized once before the workers start. Each worker opens
its own handle at its own offset, so a resume writes only the remainder. If the
server ignores `Range` and answers 200, the one-byte probe catches it and the
download collapses to a single connection from byte zero.

### `fluxdl serve [options]`

Runs the loopback JSON-RPC server Fluxget talks to. Bind it to loopback: the
secret is a bearer token, and this is not a public API.

| Option | Meaning | Default |
|---|---|---|
| `--addr <host:port>` | listen address | `127.0.0.1:9009` |
| `--secret <token>` | required leading `token:` argument | `FLUXDL_SECRET` |
| `--session <path>` | aria2-format session file | `FLUXDL_SESSION`, else a temp path |

```powershell
./fluxdl.exe serve --addr 127.0.0.1:9009 --secret change-me --session D:/Downloads/fluxdl.session
```

A minimal readiness check:

```powershell
curl -s -X POST http://127.0.0.1:9009/jsonrpc `
  -H 'Content-Type: application/json' `
  -d '{"jsonrpc":"2.0","id":1,"method":"aria2.getVersion","params":["token:change-me"]}'
```

See [RPC.md](RPC.md) for every method and its shape.

### `fluxdl --version`

Prints the version and exits. Equivalent to `-V`.
