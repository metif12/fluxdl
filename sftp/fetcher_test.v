module sftp

fn test_parse_target_with_user_and_port() {
	t := parse_target('sftp://alice@example.test:2222/uploads/f.bin') or { panic(err.msg()) }
	assert t.host == 'example.test', t.host
	assert t.user == 'alice', t.user
	assert t.port == 2222, '${t.port}'
	assert t.path == '/uploads/f.bin', t.path
}

fn test_parse_target_defaults() {
	t := parse_target('sftp://example.test/f.bin') or { panic(err.msg()) }
	assert t.port == 22, '${t.port}'
	assert t.user == '', t.user
}

fn test_parse_target_rejects_other_schemes() {
	parse_target('ftp://example.test/f') or {
		assert err.msg().contains('not an sftp'), err.msg()
		return
	}
	assert false, 'ftp must be rejected'
}
