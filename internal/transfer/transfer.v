// transfer.v - the engine half: decide which bytes to fetch, fetch them, and
// count what came back.
//
// This module is deliberately split in two. The arithmetic and the counting live
// here and are tested without a socket; the wire lives in http_fetcher.v behind
// the Fetcher interface. A fake Fetcher can therefore prove the manager's rules
// (resume, one segment when the server ignores Range, every byte accounted for)
// in a unit test, which is why those rules are here and not in the HTTP code.
module transfer

import aria2v.internal.plan
import os
import sync

// Meta is what one short probe tells us about a URL before any real transfer.
//
// `ranges` is the important field. A server that answers a Range request with
// 200 and the whole body cannot be fetched with N connections: every segment
// would write the entire file at its own offset. Detecting that once, before
// spawning anything, is cheaper and safer than discovering it in a worker.
pub struct Meta {
pub:
	length i64
	ranges bool
}

// Fetcher is the seam between the manager and the transport.
//
// head does a bounded probe; fetch writes exactly one Segment into `path` and
// returns how many bytes it wrote. Nothing in this module knows that HTTP
// exists, which is what keeps the interesting tests network-free.
pub interface Fetcher {
	head(url string) !Meta
	fetch(url string, seg plan.Segment, path string) !i64
}

// Options are the per-download knobs Fluxget exposes.
pub struct Options {
pub:
	connections int
	min_segment i64
}

// Progress is a byte counter shared between the workers and the caller.
//
// Workers report through a channel, and only the collecting loop calls add,
// so no lock is needed. Keeping progress here rather than in the RPC layer is
// what lets a CLI download print the same number the daemon reports.
pub struct Progress {
pub mut:
	value i64
}

// add records bytes fetched by one segment.
pub fn (mut p Progress) add(n i64) {
	p.value += n
}

struct Result {
	bytes i64
	err   string
}

// download fetches `url` into `path`, resuming from `done` bytes already on disk.
//
// `known` is a length the caller already has (a HEAD from a previous step, or
// a session record). The probe's length wins when it is positive, because a
// stale record is exactly the case a resume has to survive.
//
// The returned number is how many bytes THIS call wrote, not the file size. A
// caller that wants completed bytes adds the resume offset itself.
pub fn download(url string, known i64, done i64, path string, opts Options, fetcher &Fetcher, mut progress Progress) !i64 {
	meta := fetcher.head(url) or {
		return error('transfer: cannot inspect ${url}: ${err.msg()}')
	}
	total := if meta.length > 0 { meta.length } else { known }
	if total <= 0 {
		return error('transfer: unknown length for ${url}')
	}

	segs := if meta.ranges {
		plan.resume_plan(total, opts.connections, opts.min_segment, done)
	} else {
		// No Range support: one connection from byte zero. Any `done` is
		// discarded too, since we cannot ask for the tail without Range.
		plan.plan(total, 1, 0)
	}
	if segs.len == 0 {
		return 0
	}

	// Create and size the file BEFORE any worker starts. N workers racing to
	// create the same path would each truncate it, and the last truncate wins
	// over bytes already written by the others.
	if !os.exists(path) {
		os.create(path)!
	}
	os.truncate(path, u64(total))!

	ch := chan Result{cap: segs.len}
	mut wg := sync.new_waitgroup()
	for seg in segs {
		wg.add(1)
		go fetch_one(url, path, seg, fetcher, ch, wg)
	}
	wg.wait()

	mut written := i64(0)
	mut failures := 0
	mut first_error := ''
	for _ in segs {
		r := <-ch
		if r.err != '' {
			failures++
			if first_error == '' {
				first_error = r.err
			}
			continue
		}
		written += r.bytes
		progress.add(r.bytes)
	}
	if failures > 0 {
		return error('transfer: ${failures} segment(s) failed: ${first_error}')
	}
	return written
}

fn fetch_one(url string, path string, seg plan.Segment, fetcher &Fetcher, ch chan Result, wg &sync.WaitGroup) {
	defer {
		wg.done()
	}
	n := fetcher.fetch(url, seg, path) or {
		ch <- Result{ err: err.msg() }
		return
	}
	ch <- Result{ bytes: n }
}
