module transports

import fluxdl.plan
import fluxdl.transfer

struct SharedFetcher {}

pub fn (f SharedFetcher) head(url string) !transfer.Meta {
	return transfer.Meta{ length: 1, ranges: false }
}

pub fn (f SharedFetcher) fetch(url string, seg plan.Segment, path string) !i64 {
	return 1
}

fn test_with_http_reuses_the_supplied_fetcher() {
	shared := &SharedFetcher{}
	registry := with_http(shared)
	a := registry.fetcher_for('https://example.test/a') or { panic('missing') }
	b := registry.fetcher_for('http://example.test/b') or { panic('missing') }
	unsafe {
		assert voidptr(a) == voidptr(b), 'http and https must return the same fetcher'
	}
}

fn test_scheme_is_case_insensitive() {
	registry := new()
	assert registry.fetcher_for('HTTPS://example.test/f') != none, 'uppercase scheme'
}
