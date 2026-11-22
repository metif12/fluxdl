# JSON-RPC reference

fluxdl serves the same loopback shape Fluxget talks to today:

- `POST /jsonrpc`, `Content-Type: application/json`;
- a JSON-RPC 2.0 envelope with `jsonrpc`, `id`, and either `result` or `error`;
- a **leading `token:<secret>` argument** on every call, not repeated inside
  `system.multicall`'s inner calls;
- `X-Rpc-Secret` and `?token=<secret>` are accepted as alternatives.

Every numeric field in a result is a **string** (`"completedLength":"1048576"`).
That is not a stylistic choice — it is what `aria2c 1.37.0` was measured to send
and what Fluxget parses.

Start the server with `fluxdl serve --secret <token>`. With no secret configured,
the token argument is optional. `GET /health` returns 200 once the session has
been restored, and 503 while the daemon is starting. A stall supervisor restarts
downloads that stay active without progress beyond `stall-timeout` seconds.

The live queue is capped at 10,000 downloads; an `addUri` past that limit returns
a JSON-RPC error. `pause` and `remove` signal the worker's cancellation token, so
a transfer stops at the next segment boundary and a removed row is never
recreated by its worker.

## Methods

### Downloads

| Method | Arguments | Result |
|---|---|---|
| `aria2.addUri` | `[token,] uris, options?` | `gid` (16 chars) |
| `aria2.addTorrent` | `[token,] path` | `gid` |
| `aria2.addMagnet` | `[token,] uri` | error until metadata exchange exists |
| `aria2.addMetalink` | `[token,] path` | array of `gid`s |
| `aria2.tellStatus` | `gid` | status object |
| `aria2.tellActive` | — | array of status objects with `status: "active"` |
| `aria2.tellWaiting` | — | array with `status: "waiting"` |
| `aria2.tellStopped` | — | array with `status: "complete"`, `"error"`, `"paused"` or `"removed"` |
| `aria2.pause` / `aria2.unpause` | `gid` | `gid` |
| `aria2.pauseAll` / `aria2.unpauseAll` | — | `"OK"` |
| `aria2.remove` | `gid` | `gid` |
| `aria2.removeDownloadResult` | `gid` | `gid` |
| `aria2.getFiles` | `gid` | array with one file object |
| `aria2.getUris` | `gid` | array of `{ uri, status }` rows |
| `aria2.getServers` | `gid` | `[]` — no BitTorrent trackers |
| `aria2.getPeers` | `gid` | `[]` — no BitTorrent peers |
| `aria2.getOption` | `gid` | per-download option map |
| `aria2.changeOption` | `gid, options` | `gid` |

### Session and options

| Method | Arguments | Result |
|---|---|---|
| `aria2.getGlobalStat` | — | speed and count strings |
| `aria2.getVersion` | — | `{ version, enabledFeatures }` |
| `aria2.getGlobalOption` | — | settings map, all strings |
| `aria2.changeGlobalOption` | `options` | `"OK"` |
| `aria2.saveSession` | — | `"OK"` — writes aria2-format session |
| `aria2.shutdown` | — | `"OK"` |
| `aria2.getNotices` | — | array of event strings (fluxdl extension) |

### System

| Method | Arguments | Result |
|---|---|---|
| `system.multicall` | `[token,] calls` | array of one-element result arrays, or error objects |
| `system.listMethods` | — | array of method names |

An unknown method returns JSON-RPC error `-32601`; a bad token returns `-32000`;
a parse failure returns `-32700`.

## The four wire quirks

These were established against `aria2c 1.37.0` with `curl`, not read from docs,
and are asserted in `rpc/rpc_test.v`:

1. The token is a **leading** argument and is not repeated in multicall's inner
   calls. Dispatch never sees it.
2. Every number is a **string**, including nested ones like `totalLength`.
3. `aria2.getUris` returns **one row per source, expanded** in aria2 — two URLs
   came back as five rows. fluxdl returns one row per source. This is a known,
   deliberate difference; see [compat/fluxget.md](compat/fluxget.md).
4. `aria2.tellStatus` answers with `errorCode` and `errorMessage` for a failed
   download, and **never** with an `error` field.

## Examples

Add a download with two mirrors:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "aria2.addUri",
  "params": ["token:change-me", ["https://a/f.bin", "https://b/f.bin"], {"dir": "D:/Downloads"}]
}
```

Batch the tick's calls:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "system.multicall",
  "params": ["token:change-me", [
    {"methodName": "aria2.tellActive", "params": []},
    {"methodName": "aria2.getGlobalStat", "params": []}
  ]]
}
```
