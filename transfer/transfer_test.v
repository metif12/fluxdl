module transfer

import fluxdl.plan
import os

// A fetcher that writes deterministic bytes at the segment's offset. It is the
// whole reason the manager can be tested without a network: every rule below
// is a rule about planning and accounting, not about TCP.
struct FakeFetcher {
pub mut:
	length     i64  = 1024
	ranges     bool = true
	fail_first bool
}

pub fn (f FakeFetcher) head(url string) !Meta {
	return Meta{
		length: f.length
		ranges: f.ranges
	}
}

pub fn (f FakeFetcher) fetch(url string, seg plan.Segment, path string) !i64 {
	if f.fail_first && seg.index == 0 {
		return error('fake: segment failed')
	}
	mut file := if os.exists(path) { os.open_file(path, 'r+b')! } else { os.create(path)! }
	file.seek(seg.first, .start)!
	mut buf := []u8{len: int(seg.len())}
	for i in 0 .. buf.len {
		buf[i] = u8((seg.first + i) % 251)
	}
	file.write(buf)!
	file.close()
	return seg.len()
}

fn scratch(name string) string {
	dir := os.join_path(os.temp_dir(), 'fluxdl-transfer-test')
	os.mkdir_all(dir) or {}
	p := os.join_path(dir, name)
	os.rm(p) or {}
	return p
}

fn test_every_byte_is_accounted_for() {
	p := scratch('full.bin')
	mut f := &FakeFetcher{}
	mut progress := &Progress{}
	n := download('https://example.test/full.bin', 1024, 0, p, Options{ connections: 4 }, f, mut progress) or {
		assert false, err.msg()
		return
	}
	assert n == 1024, 'got ${n} bytes written'
	assert progress.value == n, 'progress ${progress.value} != written ${n}'
	assert os.file_size(p) == 1024, 'file is ${os.file_size(p)} bytes'
}

fn test_resume_only_fetches_the_remainder() {
	p := scratch('resume.bin')
	mut f := &FakeFetcher{}
	mut progress := &Progress{}
	n := download('https://example.test/r.bin', 1024, 400, p, Options{ connections: 4 }, f, mut progress) or {
		assert false, err.msg()
		return
	}
	assert n == 624, 'resume fetched ${n}, expected 624'
	assert progress.value == 624, 'progress ${progress.value}'
	assert os.file_size(p) == 1024, 'file is ${os.file_size(p)} bytes'
}

fn test_a_server_that_ignores_range_collapses_to_one_segment() {
	p := scratch('noranges.bin')
	mut f := &FakeFetcher{ ranges: false }
	mut progress := &Progress{}
	n := download('https://example.test/n.bin', 1024, 400, p, Options{ connections: 8 }, f, mut progress) or {
		assert false, err.msg()
		return
	}
	// The 400-byte resume is deliberately dropped: without Range there is no
	// way to ask for the tail, so the only correct plan is from byte zero.
	assert n == 1024, 'got ${n} bytes, expected a full refetch'
	assert os.file_size(p) == 1024, 'file is ${os.file_size(p)} bytes'
}

fn test_a_failed_segment_fails_the_download() {
	p := scratch('failed.bin')
	mut f := &FakeFetcher{ fail_first: true }
	mut progress := &Progress{}
	download('https://example.test/f.bin', 1024, 0, p, Options{ connections: 2 }, f, mut progress) or {
		assert err.msg().contains('1 segment(s) failed'), err.msg()
		return
	}
	assert false, 'a failed segment must not look like success'
}

fn test_an_unknown_length_is_an_error_not_a_zero_byte_file() {
	p := scratch('unknown.bin')
	mut f := &FakeFetcher{ length: 0 }
	mut progress := &Progress{}
	download('https://example.test/u.bin', 0, 0, p, Options{ connections: 2 }, f, mut progress) or {
		assert err.msg().contains('unknown length'), err.msg()
		return
	}
	assert false, 'unknown length must not be reported as an empty download'
}

// CountingFetcher records probes through a shared pointer, so its method can
// keep the immutable receiver the Fetcher interface requires.
struct CountingFetcher {
	length i64
	heads  &int
}

pub fn (f CountingFetcher) head(url string) !Meta {
	unsafe {
		*f.heads = *f.heads + 1
	}
	return Meta{ length: f.length, ranges: true }
}

pub fn (f CountingFetcher) fetch(url string, seg plan.Segment, path string) !i64 {
	return seg.len()
}

fn test_download_with_meta_does_not_probe_a_second_time() {
	p := scratch('oneprobe.bin')
	mut heads := 0
	f := &CountingFetcher{ length: 1024, heads: &heads }
	meta := f.head('https://example.test/once.bin') or { panic(err.msg()) }
	assert heads == 1, 'one probe before starting'
	mut progress := &Progress{}
	n := download_with_meta('https://example.test/once.bin', meta, meta.length, 0, p, Options{ connections: 2 }, f, mut progress) or {
		assert false, err.msg()
		return
	}
	assert n == 1024, 'got ${n}'
	assert heads == 1, 'the transfer probed a second time: ${heads}'
}

fn test_a_single_segment_transfer_uses_the_fast_path() {
	p := scratch('single.bin')
	mut f := &FakeFetcher{}
	mut progress := &Progress{}
	n := download('https://example.test/single.bin', 1024, 0, p, Options{ connections: 1 }, f, mut progress) or {
		assert false, err.msg()
		return
	}
	assert n == 1024, 'got ${n}'
	assert os.file_size(p) == 1024, 'file is ${os.file_size(p)} bytes'
}

// A failed single-segment transfer must not leave a full-size file: the next
// run would read its size as "already complete" and never fetch the bytes.
fn test_a_failed_transfer_does_not_leave_a_full_size_file() {
	p := scratch('failed-size.bin')
	mut f := &FakeFetcher{ fail_first: true }
	mut progress := &Progress{}
	download('https://example.test/fsize.bin', 1024, 0, p, Options{ connections: 1 }, f, mut progress) or {
		assert err.msg().contains('1 segment(s) failed'), err.msg()
		assert os.file_size(p) < 1024, 'failed transfer left a ${os.file_size(p)}-byte file'
		return
	}
	assert false, 'a failed segment must not look like success'
}
