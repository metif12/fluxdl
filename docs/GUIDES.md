# Guides

Task-oriented walkthroughs. For exhaustive symbol lists see [API.md](API.md);
for CLI flags see [CLI.md](CLI.md).

## Install

```powershell
v install metif12.fluxdl                            # from vpm
v install --git https://github.com/metif12/fluxdl   # from source
```

From inside another project, `v install` also records the dependency in that
project's `v.mod`. `v link` in this checkout symlinks it into the modules folder
for local development.

## Download a file

```powershell
v build -o fluxdl.exe .
./fluxdl.exe download https://example.com/big.iso -x 8 -d D:/Downloads
```

Use `plan` first to see the byte ranges without touching the network. On a
server that ignores `Range`, the one-byte probe detects the 200 response and the
download falls back to one connection.

To continue an interrupted transfer, run the same command again. The file size
is the resume position; a stale file that is too long is truncated, never
padded with zeros.

## Download other protocols

```powershell
./fluxdl.exe download ftp://user:pass@host:21/pub/file.iso -d D:/Downloads
./fluxdl.exe download sftp://user@host:22/home/user/file.iso -d D:/Downloads
```

FTP and SFTP fetch whole files (no range REST), so they use one connection. SFTP
requires the system `sftp` client; its arguments are passed as an argv vector,
never through a shell.

## Download and seed a torrent

```powershell
./fluxdl.exe torrent ubuntu.iso.torrent -d D:/Downloads
./fluxdl.exe seed ubuntu.iso.torrent -d D:/Downloads -p 6881
```

A magnet URI with `xt=urn:btih:` works too. Metadata is resolved from tracker
peers or DHT and verified against the info hash before use. Every piece is
verified with SHA1 before it is written. Seeding is opt-in.

## Run the JSON-RPC daemon

```powershell
./fluxdl.exe serve --addr 127.0.0.1:9009 --secret change-me --session D:/Downloads/fluxdl.session
```

A readiness probe:

```powershell
curl http://127.0.0.1:9009/health
# {"status":"ok"}
```

Test a request:

```powershell
curl -s -X POST http://127.0.0.1:9009/jsonrpc -H 'Content-Type: application/json' `
  -d '{"jsonrpc":"2.0","id":1,"method":"aria2.getVersion","params":["token:change-me"]}'
```

The `aria2.*` method names are the application-facing protocol contract; see
[RPC.md](RPC.md#why-method-names-start-with-aria2) for why they are unchanged.

## Extend fluxdl

### Add a transport

1. Implement `transfer.Fetcher`: `head(url) !Meta` and
   `fetch(url, seg, path) !i64`.
2. Register a factory in `transports/registry.v` with `register("scheme", ...)`.
3. Add a test in `transports/` proving `fetcher_for` returns the new fetcher.

No CLI or RPC changes are needed: both ask the registry.

### Add an RPC method

1. Add a dispatch arm in `rpc/wire.v`.
2. Add one `MethodSpec` row in `rpc/methods.v` — it drives `listMethods` and
   the read-only response cache.
3. Add a request/response test in `rpc/rpc_test.v` and document the method in
   [RPC.md](RPC.md).

### Add a validation helper

Put it in `util/` with a test in `util/util_test.v`. The digit and hex helpers
already live there so every caller shares one implementation.

## Test

```powershell
v test .            # network-free suite
v fmt -verify .     # formatting gate
```

Tests never open sockets. Live protocol checks are manual commands above or
opt-in integration runs outside the default suite.
