# AGENTS.md — how to work in fluxdl

Rules that differ from, or add to, Fluxget's own AGENTS.md. Where the two
disagree, the stricter one wins: this code will run in Fluxget's process space.

## 1. Purity

- `plan`, `link` and `session` are **pure**. No sockets,
  no `http.`, no `net.`, no `time.` outside `main.v`, `transfer` and
  `rpc`.
- `transfer/transfer.v` stays pure by taking a `Fetcher` interface. The
  only production implementation that opens a socket is
  `transfer/http_fetcher.v`. A new network path must go behind the same
  interface or this rule is broken.
- `v test` never touches the network and never starts a download. Anything that
  does is behind an env var and capped at 1 MiB, the same ceiling Fluxget uses.
- A test that cannot fail is worse than no test. Disable the rule, watch the
  assertion go red, restore it, and say in the commit which rule you broke.

## 2. V 0.5.2 traps this repo has already paid for

Read once, and add to the list when you meet a new one:

- `String.index` returns `?int`. `if i := s.index(x)` does not compile where a
  comparison follows; use `or { -1 }`. The unknown method also cascades into
  unrelated-looking errors three lines later.
- `String.replace(a, b)` replaces **every** occurrence. There is no `replace_all`.
- There is no `trim_string_right` / `trim_string_left` with a cutset. Write the
  loop.
- A struct name must start with a capital letter.
- `is` only works on sum types. To assert a rejection, reach the `or` block.
- `assert cond, msg` takes a single string. `assert n == 1, n` does not compile;
  use `assert n == 1, '... ${n}'`.
- Numeric literal suffixes (`1i64`, `1.4f64`) are "unsuitable digit". Cast.
- `import json` was replaced by `json2`; `json.encode(x)` is now
  `json2.encode(x)`.
- `os.read_bytes` refuses a path containing `..`, and `os.join_path` **quotes** an
  argument starting with `..`. Build the path yourself and normalise it by hand.
- `http.download_file_with_progress` only forwards chunks to a custom Downloader
  when the status is **200**; a ranged answer is 206 and receives no chunks. Use
  `FetchConfig.on_progress_body` instead — it fires for 206 too, with the status
  code as an argument. Its `user_ptr` is a `voidptr`; cast it inside `unsafe`.

## 3. The session file is the contract, not an implementation detail

- It is written in `aria2c`'s format on purpose. See `session/session.v`:
  the shape that survives the app not running is the one the other engine can also
  read, and a cut-over you cannot reverse is a cut-over nobody will let you do.
- A corrupt line costs **one** entry, never the queue. This is asserted by
  `test_a_corrupt_line_loses_one_entry_not_the_queue`; if you change it, that test
  changes in the same commit and the commit says why.
- Writes are a temp file plus a rename. "Half written" and "valid" are the only
  two states a session file is allowed to be in.

## 4. Definition of done

- `v test .` green (the `./...` form finds zero test files in V 0.5.2), and green
  on the tree you are about to commit.
- `v fmt -w .` clean.
- New public behaviour has a test in the same commit.
- A `README.md` line if it changes what the engine can do — including what it
  **still cannot**, which is the section a reader will trust most.
