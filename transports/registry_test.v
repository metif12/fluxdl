module transports

import fluxdl.plan
import fluxdl.transfer

struct DummyFetcher {}

pub fn (f DummyFetcher) head(url string) !transfer.Meta {
	return transfer.Meta{ length: 1, ranges: false }
}

pub fn (f DummyFetcher) fetch(url string, seg plan.Segment, path string) !i64 {
	return 1
}

fn test_built_in_schemes_are_registered() {
	registry := new()
	assert registry.fetcher_for('https://example.test/f') != none, 'https'
	assert registry.fetcher_for('ftp://example.test/f') != none, 'ftp'
	assert registry.fetcher_for('sftp://example.test/f') != none, 'sftp'
	assert registry.fetcher_for('gopher://example.test/f') == none, 'unknown scheme'
}

fn test_a_new_scheme_needs_only_one_registration() {
	mut registry := new()
	registry.register('gopher', fn () &transfer.Fetcher {
		return &DummyFetcher{}
	})
	assert registry.fetcher_for('gopher://example.test/f') != none, 'custom transport'
}
