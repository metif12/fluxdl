module ftp

fn test_parse_target_with_credentials() {
	t := parse_target('ftp://user:pass@example.test:2121/pub/f.bin') or { panic(err.msg()) }
	assert t.addr == 'example.test:2121', t.addr
	assert t.user == 'user', t.user
	assert t.pass == 'pass', t.pass
	assert t.path == '/pub/f.bin', t.path
}

fn test_parse_target_defaults() {
	t := parse_target('ftp://example.test/f.bin') or { panic(err.msg()) }
	assert t.addr == 'example.test:21', t.addr
	assert t.user == 'anonymous', t.user
	assert t.path == '/f.bin', t.path
}

fn test_parse_target_rejects_other_schemes() {
	parse_target('https://example.test/f') or {
		assert err.msg().contains('not an ftp'), err.msg()
		return
	}
	assert false, 'https must be rejected'
}
