module metalink

const sample = '<?xml version="1.0"?><metalink version="4.0"><files>' +
	'<file name="a.bin"><url>https://a/f.bin</url><url>https://b/f.bin</url>' +
	'<hash type="sha256">abc123</hash></file>' +
	'<file name="ignored.bin"></file>' +
	'</files></metalink>'

fn test_parse_extracts_urls_and_hashes() {
	files := parse(sample) or { panic(err.msg()) }
	assert files.len == 1, '${files.len}'
	assert files[0].name == 'a.bin', files[0].name
	assert files[0].urls.len == 2, '${files[0].urls.len}'
	assert files[0].urls[0] == 'https://a/f.bin', files[0].urls[0]
	assert files[0].hashes['sha256'] == 'abc123', files[0].hashes['sha256']
}

fn test_empty_url_lists_are_skipped() {
	files := parse('<metalink><files><file name="x"></file></files></metalink>') or {
		panic(err.msg())
	}
	assert files.len == 0, 'a file with no URLs cannot be downloaded'
}
