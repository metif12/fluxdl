// transfer.v - the engine half: decide which bytes to fetch, fetch them, and
// count what came back.
//
// This module is deliberately split in two. The arithmetic and the counting live
// here and are tested without a socket; the wire lives in http_fetcher.v behind
// the Fetcher interface. A fake Fetcher can therefore prove the manager's rules
// (resume, one segment when the server ignores Range, every byte accounted for)
// in a unit test, which is why those rules are here and not in the HTTP code.
module transfer

import fluxdl.plan
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
	cancel      &Cancel = unsafe { nil }
}

// Cancel is a shared stop flag. Pause and remove call stop(); the transfer
// checks it between segments so a queued download can be abandoned.
pub struct Cancel {
mut:
	mu      sync.Mutex
	stopped bool
}

// stop records that the owner no longer wants this transfer to continue.
pub fn (mut c Cancel) stop() {
	c.mu.lock()
	c.stopped = true
	c.mu.unlock()
}

// is_stopped reports whether stop() has been called.
pub fn (mut c Cancel) is_stopped() bool {
	c.mu.lock()
	v := c.stopped
	c.mu.unlock()
	return v
}

// Progress is a byte counter shared between the workers and the caller.
//
// Each worker owns one result slot, and only the collecting loop calls add,
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
	return download_with_meta(url, meta, known, done, path, opts, fetcher, mut progress)
}

// download_with_meta is the same transfer when the caller already probed the
// URL. A daemon that probed at addUri time must not probe a second time just
// to start the download — that is one extra round trip and one extra byte
// range on every queue item.
pub fn download_with_meta(url string, meta Meta, known i64, done i64, path string, opts Options, fetcher &Fetcher, mut progress Progress) !i64 {
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
	cancelled := fn (c &Cancel) bool {
		return c != unsafe { nil } && c.is_stopped()
	}
	if cancelled(opts.cancel) {
		return error('transfer: cancelled')
	}

	// Create the file once before any worker starts. N workers racing to
	// create the same path would each truncate it. Writes at an offset extend
	// the file, so only shrink a stale file that is longer than the plan:
	// padding a failed download with zeros would make it look complete.
	if !os.exists(path) {
		os.create(path)!
	}
	if os.file_size(path) > total {
		os.truncate(path, u64(total))!
	}

	// One segment needs no goroutine, channel or wait group. That is the
	// common case for small files and for servers that ignore Range.
	if segs.len == 1 {
		if cancelled(opts.cancel) {
			return error('transfer: cancelled')
		}
		n := fetcher.fetch(url, segs[0], path) or {
			return error('transfer: 1 segment(s) failed: ${err.msg()}')
		}
		progress.add(n)
		return n
	}

	// Each worker owns exactly one slot of `results`, so no lock or channel is
	// needed to collect them. The wait group is the only synchronisation.
	mut results := []Result{len: segs.len}
	mut wg := sync.new_waitgroup()
	for i, seg in segs {
		if cancelled(opts.cancel) {
			break
		}
		wg.add(1)
		go fetch_one_at(url, path, seg, i, fetcher, mut results, wg)
	}
	wg.wait()
	if cancelled(opts.cancel) {
		return error('transfer: cancelled')
	}

	mut written := i64(0)
	mut failures := 0
	mut first_error := ''
	for r in results {
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

fn fetch_one_at(url string, path string, seg plan.Segment, index int, fetcher &Fetcher, mut results []Result, wg &sync.WaitGroup) {
	defer {
		wg.done()
	}
	n := fetcher.fetch(url, seg, path) or {
		results[index] = Result{ err: err.msg() }
		return
	}
	results[index] = Result{ bytes: n }
}
