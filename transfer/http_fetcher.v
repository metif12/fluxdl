// http_fetcher.v - the only file in the engine that touches a socket.
//
// It uses V's net.http for TLS, redirects and chunked encoding (ADR-0002). The
// one thing it adds is a progress callback that writes each chunk into the
// shared output file at the segment's offset: net.http writes from zero, and a
// multi-connection download needs N independent cursors into one file.
module transfer

import fluxdl.plan
import net.http
import os

pub struct HttpFetcher {}

// head probes one byte to learn the length and whether Range is honoured.
//
// A 206 with Content-Range means the server supports ranges and tells us the
// total. A 200 means it ignored the header and sent the whole body; we still
// get Content-Length, and report ranges = false so the manager collapses to a
// single connection. The probe body is capped at 64 bytes.
pub fn (f HttpFetcher) head(url string) !Meta {
	mut h := http.Header{}
	h.set(.range, 'bytes=0-0')
	// stop_receiving_limit matters when the server ignores Range: without it,
	// a one-byte probe would still pull the entire body over the wire before
	// discarding all but 64 bytes.
	res := http.fetch(
		method:               .get
		url:                  url
		header:               h
		validate:             true
		stop_copying_limit:   64
		stop_receiving_limit: 64
	)!
	if res.status_code == 206 {
		cr := res.header.get(.content_range) or {
			return error('transfer: a 206 without Content-Range from ${url}')
		}
		slash := last_slash(cr)
		if slash < 0 {
			return error('transfer: malformed Content-Range "${cr}"')
		}
		length := cr[slash + 1..].i64()
		if length <= 0 {
			return error('transfer: bad length in Content-Range "${cr}"')
		}
		return Meta{
			length: length
			ranges: true
		}
	}
	length := (res.header.get(.content_length) or { '0' }).i64()
	return Meta{
		length: length
		ranges: false
	}
}

// fetch streams exactly one segment into path at its byte offset.
//
// net.http's own StreamingDownloader only forwards chunks for a 200 answer,
// which is the wrong filter here: a successful ranged answer is 206. Using
// FetchConfig.on_progress_body directly receives every body chunk with its
// status code, so we can accept 206 and still never write a redirect body.
pub fn (f HttpFetcher) fetch(url string, seg plan.Segment, path string) !i64 {
	mut h := http.Header{}
	h.set(.range, seg.range_header())
	mut w := &ChunkWriter{ file: os.open_file(path, 'r+b')! }
	w.file.seek(seg.first, .start)!
	defer {
		w.file.close()
	}
	res := http.fetch(
		method:             .get
		url:                url
		header:             h
		validate:           true
		user_ptr:           voidptr(w)
		on_progress_body:   write_chunk
		stop_copying_limit: 64
	)!
	if res.status_code != 200 && res.status_code != 206 {
		return error('transfer: HTTP ${res.status_code} for ${seg.range_header()}')
	}
	// A short segment is a corrupt download, not a success. The file has been
	// pre-sized, so a length check is the only thing that catches it.
	if w.written != seg.len() {
		return error('transfer: segment ${seg.index} wrote ${w.written} of ${seg.len()} bytes')
	}
	return w.written
}

fn last_slash(s string) int {
	for i := s.len - 1; i >= 0; i-- {
		if s[i] == `/` {
			return i
		}
	}
	return -1
}

// ChunkWriter is the state the callback needs: an open handle and a cursor.
// It lives on the heap because the address is passed through user_ptr.
struct ChunkWriter {
mut:
	file    os.File
	written i64
}

fn write_chunk(request &http.Request, chunk []u8, _ u64, _ u64, status_code int) ! {
	if status_code != 200 && status_code != 206 {
		return
	}
	mut w := unsafe { &ChunkWriter(request.user_ptr) }
	w.file.write(chunk)!
	w.written += chunk.len
}
