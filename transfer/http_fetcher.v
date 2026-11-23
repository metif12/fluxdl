// http_fetcher.v - the only file in the engine that touches a socket.
//
// It uses V's net.http for TLS, redirects and chunked encoding (ADR-0002). The
// one thing it adds is a progress callback that writes each chunk into the
// shared output file at the segment's offset: net.http writes from zero, and a
// multi-connection download needs N independent cursors into one file.
module transfer

import fluxdl.plan
import fluxdl.util
import net.http
import net.urllib
import os
import sync

struct RobotsRules {
	allow    string
	disallow string
}

pub struct HttpState {
mut:
	mu      sync.Mutex
	cookies map[string]string
	// One entry per host, not per path: robots.txt does not change between URLs.
	robots map[string]RobotsRules
}

pub struct HttpFetcher {
	state &HttpState
}

// new_http_fetcher creates a fetcher with a cookie jar and robots cache.
pub fn new_http_fetcher() &HttpFetcher {
	return &HttpFetcher{
		state: &HttpState{
			cookies: map[string]string{}
			robots:  map[string]RobotsRules{}
		}
	}
}

fn (mut s HttpState) remember(key string, rules RobotsRules) {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	// A bounded cache: an origin stream must not grow this without limit.
	if s.robots.len >= 1024 {
		s.robots.clear()
	}
	s.robots[key] = rules
}

fn (s &HttpState) allowed(key string) ?RobotsRules {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if key in s.robots {
		return s.robots[key] or { return none }
	}
	return none
}

fn (mut s HttpState) store_cookie(header string) {
	first := header.split(';')[0]
	parts := first.split('=')
	if parts.len < 2 || parts[0].trim_space() == '' {
		return
	}
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	s.cookies[parts[0].trim_space()] = parts[1..].join('=').trim_space()
}

fn (f HttpFetcher) cookie_snapshot() map[string]string {
	f.state.mu.lock()
	defer {
		f.state.mu.unlock()
	}
	return f.state.cookies.clone()
}

fn origin_of(url string) !string {
	parsed := urllib.parse(url) or { return error('transfer: bad URL ${url}') }
	port_text := parsed.port()
	scheme := parsed.scheme
	default_port := if scheme == 'https' { '443' } else { '80' }
	p := if port_text == '' { default_port } else { port_text }
	return '${scheme}://${parsed.host}:${p}'
}

fn path_of(url string) string {
	rest := url[url.index('://') or { return '/' } + 3..]
	slash := rest.index('/') or { return '/' }
	return rest[slash..]
}

// robots_allowed caches parsed rules per host, so a second URL on the same
// origin never fetches /robots.txt again.
fn robots_allowed(state &HttpState, url string) !bool {
	origin := origin_of(url) or { return true }
	path := path_of(url)
	mut rules := RobotsRules{}
	if cached := state.allowed(origin) {
		rules = cached
	} else {
		rules = parse_robots(origin)
		state.remember(origin, rules)
	}
	if rules.disallow == '' {
		return true
	}
	if !path.starts_with(rules.disallow) {
		return true
	}
	// Longest matching prefix wins over a shorter Disallow.
	return rules.allow != '' && path.starts_with(rules.allow) && rules.allow.len > rules.disallow.len
}

fn parse_robots(origin string) RobotsRules {
	response := http.fetch(
		method:               .get
		url:                  origin + '/robots.txt'
		validate:             true
		stop_receiving_limit: 65536
	) or {
		return RobotsRules{}
	}
	if response.status_code != 200 {
		return RobotsRules{}
	}
	return parse_robots_text(response.body)
}

fn parse_robots_text(body string) RobotsRules {
	mut applies := false
	mut allow := ''
	mut disallow := ''
	for raw in body.split_into_lines() {
		line := raw.trim_space()
		if line.starts_with('#') || line == '' {
			continue
		}
		colon := line.index(':') or { continue }
		name := line[..colon].trim_space().to_lower()
		value := line[colon + 1..].trim_space().to_lower()
		if name == 'user-agent' {
			applies = value == '*' || value.contains('fluxdl')
			continue
		}
		if !applies {
			continue
		}
		if name == 'allow' && value.len > allow.len {
			allow = value
		}
		if name == 'disallow' && value != '' && value.len > disallow.len {
			disallow = value
		}
	}
	return RobotsRules{ allow: allow, disallow: disallow }
}

// head probes one byte to learn the length and whether Range is honoured.
//
// A 206 with Content-Range means the server supports ranges and tells us the
// total. A 200 means it ignored the header and sent the whole body; we still
// get Content-Length, and report ranges = false so the manager collapses to a
// single connection. The probe body is capped at 64 bytes.
pub fn (f HttpFetcher) head(url string) !Meta {
	allowed := robots_allowed(f.state, url) or { true }
	if !allowed {
		return error('transfer: robots.txt disallows ${url}')
	}
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
		cookies:              f.cookie_snapshot()
		stop_receiving_limit: 64
	)!
	if cookie := res.header.get_custom('set-cookie') {
		f.state.store_cookie(cookie)
	}
	if res.status_code == 206 {
		cr := res.header.get(.content_range) or {
			return error('transfer: a 206 without Content-Range from ${url}')
		}
		slash := last_slash(cr)
		if slash < 0 {
			return error('transfer: malformed Content-Range "${cr}"')
		}
		length := util.i64_or(cr[slash + 1..], 0)
		if length <= 0 {
			return error('transfer: bad length in Content-Range "${cr}"')
		}
		return Meta{
			length: length
			ranges: true
		}
	}
	length := util.i64_or(res.header.get(.content_length) or { '0' }, 0)
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
	allowed := robots_allowed(f.state, url) or { true }
	if !allowed {
		return error('transfer: robots.txt disallows ${url}')
	}
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
		cookies:            f.cookie_snapshot()
		on_progress_body:   write_chunk
		stop_copying_limit: 64
	)!
	if cookie := res.header.get_custom('set-cookie') {
		f.state.store_cookie(cookie)
	}
	if res.status_code != 200 && res.status_code != 206 {
		return error('transfer: HTTP ${res.status_code} for ${seg.range_header()}')
	}
	// A short segment is a corrupt download, not a success. The output file is
	// only shrunk when stale, not padded to the planned size, so this byte
	// count is the check that catches a truncated body.
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
