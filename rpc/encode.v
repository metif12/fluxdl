module rpc

import strings

struct RowBuilder {
mut:
	sb    strings.Builder
	first bool = true
}

fn (mut b RowBuilder) sep() {
	if !b.first {
		b.sb.write_byte(`,`)
	}
	b.first = false
}

fn hex_digit(n u8) string {
	if n < 10 {
		return [u8(n + `0`)].bytestr()
	}
	return [u8(n - 10 + `a`)].bytestr()
}

// write_json_string escapes directly into the row builder. json2.encode is
// correct but allocates a new string for every one of the ~12 string fields
// in a tellStatus row.
fn write_json_string(mut sb strings.Builder, value string) {
	sb.write_byte(`"`)
	for i := 0; i < value.len; i++ {
		c := value[i]
		match c {
			`"` {
				sb.write_string('\\"')
			}
			`\\` {
				sb.write_string('\\\\')
			}
			`\n` {
				sb.write_string('\\n')
			}
			`\r` {
				sb.write_string('\\r')
			}
			`\t` {
				sb.write_string('\\t')
			}
			else {
				if c < 0x20 {
					sb.write_string('\\u00')
					sb.write_string(hex_digit(c >> 4))
					sb.write_string(hex_digit(c & 0x0f))
				} else {
					sb.write_u8(c)
				}
			}
		}
	}
	sb.write_byte(`"`)
}

fn (mut b RowBuilder) add_str(key string, value string) {
	b.sep()
	b.sb.write_byte(`"`)
	b.sb.write_string(key)
	b.sb.write_string('":')
	write_json_string(mut b.sb, value)
}

fn (mut b RowBuilder) add_num(key string, value string) {
	b.sep()
	b.sb.write_byte(`"`)
	b.sb.write_string(key)
	b.sb.write_string('":"')
	b.sb.write_string(value)
	b.sb.write_byte(`"`)
}

fn (mut b RowBuilder) add_raw(key string, value string) {
	b.sep()
	b.sb.write_byte(`"`)
	b.sb.write_string(key)
	b.sb.write_string('":')
	b.sb.write_string(value)
}

fn (mut b RowBuilder) done() string {
	b.sb.write_byte(`}`)
	res := b.sb.str()
	unsafe {
		b.sb.free()
	}
	return res
}

// encode_status is the cache miss path: build the exact tellStatus shape as
// bytes, so a row with a large path or error message does not allocate a map
// and a sum-type wrapper for every one of its fields.
fn encode_status(d Download) string {
	mut uris := []string{}
	for u in d.uris {
		mut ub := RowBuilder{ sb: strings.new_builder(96) }
		ub.sb.write_byte(`{`)
		ub.add_str('uri', u)
		state := if d.active_uri == '' || d.active_uri == u { 'used' } else { 'waiting' }
		ub.add_str('status', state)
		uris << ub.done()
	}

	mut fb := RowBuilder{ sb: strings.new_builder(256) }
	fb.sb.write_byte(`{`)
	fb.add_str('index', '1')
	fb.add_str('path', d.path)
	fb.add_num('length', d.total.str())
	fb.add_num('completedLength', d.completed.str())
	fb.add_str('selected', 'true')
	fb.add_raw('uris', '[' + uris.join(',') + ']')
	files_json := fb.done()

	mut b := RowBuilder{ sb: strings.new_builder(512) }
	b.sb.write_byte(`{`)
	b.add_str('gid', d.gid)
	b.add_str('status', d.status)
	b.add_num('totalLength', d.total.str())
	b.add_num('completedLength', d.completed.str())
	b.add_num('uploadLength', '0')
	b.add_num('bitfield', '0')
	b.add_num('downloadSpeed', '0')
	b.add_num('uploadSpeed', '0')
	b.add_str('infoHash', '')
	b.add_num('numSeeders', '0')
	b.add_str('seeder', 'false')
	b.add_num('pieceLength', '1048576')
	b.add_num('numPieces', '1')
	b.add_num('connections', '1')
	b.add_str('errorCode', d.error_code)
	b.add_str('errorMessage', d.error_message)
	b.add_str('dir', d.dir)
	b.add_raw('files', '[' + files_json + ']')
	return b.done()
}

// status_json encodes one row once per version. Callers hold m.mu, so the
// cache is safe to read and write here.
fn (mut m Manager) status_json(gid string) string {
	d := m.downloads[gid]
	if gid in m.status_cache {
		cached := m.status_cache[gid]
		if cached.version == d.version {
			return cached.json
		}
	}
	encoded := encode_status(d)
	m.status_cache[gid] = StatusCache{
		version: d.version
		json:    encoded
	}
	return encoded
}
