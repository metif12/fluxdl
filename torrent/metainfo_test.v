module torrent

const sample = 'd8:announce14:http://tracker4:infod4:name5:a.bin12:piece lengthi4e6:pieces20:xxxxxxxxxxxxxxxxxxxx6:lengthi4eee'

fn test_bencode_decodes_scalars_and_containers() {
	value := decode(sample.bytes()) or { panic(err.msg()) }
	root := match value {
		map[string]BValue {
			value
		}
		else {
			assert false, 'root must be a dict'
			return
		}
	}
	assert string_field(root, 'announce') == 'http://tracker', 'announce'
}

fn test_parse_torrent_metadata() {
	t := parse(sample.bytes()) or { panic(err.msg()) }
	assert t.name == 'a.bin', t.name
	assert t.announce == 'http://tracker', t.announce
	assert t.piece_length == 4, '${t.piece_length}'
	assert t.length == 4, '${t.length}'
	assert t.pieces.len == 1, '${t.pieces.len}'
	assert t.pieces[0] == 'xxxxxxxxxxxxxxxxxxxx', t.pieces[0]
	assert t.info_hash_raw.len == 20, '${t.info_hash_raw.len}'
	assert t.files.len == 1 && t.files[0].path == 'a.bin', 'single-file torrent'
}

fn test_parse_magnet() {
	m := parse_magnet('magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Arch+Linux') or {
		panic(err.msg())
	}
	assert m.name == 'Arch Linux', m.name
	assert m.info_hash_raw.len == 20, '${m.info_hash_raw.len}'
}

fn test_bencode_integer_requires_digits() {
	decode('i12xe'.bytes()) or {
		assert err.msg().contains('malformed integer'), err.msg()
		return
	}
	assert false, 'trailing garbage in an integer must be rejected'
}

fn test_magnet_percent_decode_handles_hex_letters() {
	m := parse_magnet('magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=caf%C3%A9') or {
		panic(err.msg())
	}
	assert m.name == 'café', m.name
}

fn test_malformed_bencode_is_an_error() {
	decode('i12'.bytes()) or {
		assert err.msg().contains('unterminated'), err.msg()
		return
	}
	assert false, 'unterminated integer must fail'
}
