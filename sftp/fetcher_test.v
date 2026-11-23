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

fn test_batch_path_rejects_command_injection() {
	assert valid_batch_path('/pub/f.bin'), 'ordinary path'
	assert !valid_batch_path('/pub/f.bin\nput /etc/passwd /tmp/x'), 'newline is a batch command separator'
	assert !valid_batch_path('relative/path'), 'remote path must be absolute'
	assert !valid_batch_path('/pub/a"b'), 'quotes would break batch quoting'
}

fn test_parse_target_rejects_other_schemes() {
	parse_target('ftp://example.test/f') or {
		assert err.msg().contains('not an sftp'), err.msg()
		return
	}
	assert false, 'ftp must be rejected'
}
