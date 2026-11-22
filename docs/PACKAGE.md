# fluxdl as a V package

`fluxdl` is a V package with five public modules and no third-party dependencies.
It builds with V 0.5.2.

## Install

From vpm (after registration):

```powershell
v install metif12.fluxdl
```

From git, today:

```powershell
v install --git https://github.com/metif12/fluxdl
```

`v install` run inside another project also records the dependency in that
project's `v.mod`. For local development, `v link` from this checkout symlinks
it into the modules directory; `v unlink` removes the link.

## Import paths

A VPM package is imported under its full publisher-qualified name. A git
install uses the `v.mod` name only:

| Installed as | Import prefix | Example |
|---|---|---|
| `metif12.fluxdl` (vpm) | `metif12.fluxdl` | `import metif12.fluxdl.plan` |
| `fluxdl` (`--git`) | `fluxdl` | `import fluxdl.plan` |

In either case the module name you write code against is just the last
component (`plan`, `link`, …), because V flattens module prefixes.

## Public modules

| Module | What it gives you | Good for |
|---|---|---|
| `plan` | `Segment`, `plan`, `resume_plan`, `range_header`, `covers`, `total_len` | computing byte ranges without a socket |
| `link` | `Kind`, `Link`, `parse`, `safe_name`, `suggest`, `magnet_name`, `percent_decode`, `base_name` | deriving names and folders from addresses |
| `session` | `Entry`, `encode`, `decode`, `save`, `load` | aria2-format queue files |
| `transfer` | `Meta`, `Fetcher`, `Options`, `Progress`, `HttpFetcher`, `download`, `download_with_meta` | fetching ranges, with an injectable transport |
| `rpc` | `Manager`, `new_manager`, `Handler`, `serve`, `version` | the loopback JSON-RPC surface Fluxget calls |
| `util` | `all_digits`, `int_or`, `i64_or`, `secure_equal` | validating untrusted numbers and comparing secrets |
| `checksum` | `hash_bytes`, `hash_file`, `verify_file` | md5/sha1/sha256 verification |
| `metalink` | `MetalinkFile`, `parse` | Metalink 4 files, URLs and hashes |
| `ftp` | `Fetcher`, `new_fetcher`, `parse_target` | whole-file FTP downloads |
| `sftp` | `Fetcher`, `new_fetcher`, `parse_target` | whole-file SFTP downloads via the system client |
| `torrent` | `Torrent`, `parse`, `parse_magnet`, `download`, `announce`, `handshake` | bencode, trackers, peer wire, SHA1 pieces |

`transfer.Fetcher` is the seam for callers that want to own the transport:
implement `head` and `fetch`, then call `transfer.download` with your
implementation. The default `HttpFetcher` is the production one.

A complete library example is in [`examples/library.v`](../examples/library.v).

## Publishing a new version

1. Update `version:` in `v.mod` and the `rpc.version` constant together.
2. Keep `v test .` green and `v fmt -verify .` clean.
3. Commit and push to `main`; `repo_url` and `repo_branch` in `v.mod` point
   there.
4. Register the package once at <https://vpm.vlang.io/new> with GitHub login.
   The registry combines the account and repo into `metif12.fluxdl`; the entry
   cannot be edited after submission, so check the name and URL first.
5. Tag the repository with `vlang` and `vlang-package` for discoverability.

The package name in `v.mod` stays `fluxdl` — the publisher prefix is added by
vpm, not by the module name.

## What this package is not

It is a library and a CLI, not a daemon supervisor. Fluxget still owns restart,
backoff and readiness. BitTorrent, Metalink and checksums are not implemented;
see [ROADMAP.md](../ROADMAP.md).
