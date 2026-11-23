// metainfo.v - bencode, .torrent metadata and magnet links.
//
// This is the parsing surface of the BitTorrent client: every byte here is
// untrusted, so lengths are checked before slices and malformed values are
// errors rather than panics.
module torrent

import crypto.sha1
import encoding.base32
import encoding.hex
import net.urllib
import strings

pub type BValue = i64 | string | []BValue | map[string]BValue

pub struct Decoder {
pub mut:
	data     []u8
	pos      int
	info_raw []u8
}

pub fn decode(data []u8) !BValue {
	mut d := Decoder{ data: data }
	return d.value()
}

fn (mut d Decoder) value() !BValue {
	if d.pos >= d.data.len {
		return error('bencode: unexpected end')
	}
	c := d.data[d.pos]
	match c {
		`i` {
			d.pos++
			start := d.pos
			for d.pos < d.data.len && d.data[d.pos] != `e` {
				d.pos++
			}
			if d.pos >= d.data.len {
				return error('bencode: unterminated integer')
			}
			text := d.data[start..d.pos].bytestr()
			d.pos++
			digits := if text.starts_with('-') { text[1..] } else { text }
			if !all_digits(digits) {
				return error('bencode: malformed integer ${text}')
			}
			return i64(digits.i64()) * if text.starts_with('-') { -1 } else { 1 }
		}
		`l` {
			d.pos++
			mut out := []BValue{}
			for {
				if d.pos >= d.data.len {
					return error('bencode: unterminated list')
				}
				if d.data[d.pos] == `e` {
					d.pos++
					return out
				}
				out << d.value() or { return err }
			}
		}
		`d` {
			d.pos++
			mut out := map[string]BValue{}
			for {
				if d.pos >= d.data.len {
					return error('bencode: unterminated dict')
				}
				if d.data[d.pos] == `e` {
					d.pos++
					return out
				}
				key_value := d.value() or { return err }
				key := match key_value {
					string { key_value }
					else { return error('bencode: dict key is not a string') }
				}
				start := d.pos
				item := d.value() or { return err }
				if key == 'info' {
					d.info_raw = d.data[start..d.pos].clone()
				}
				out[key] = item
			}
		}
		else {}
	}
	// A string is <length>:<bytes>.
	mut colon := d.pos
	for colon < d.data.len && d.data[colon] != `:` {
		colon++
	}
	if colon >= d.data.len {
		return error('bencode: malformed string length')
	}
	len_text := d.data[d.pos..colon].bytestr()
	if !all_digits(len_text) {
		return error('bencode: bad string length ${len_text}')
	}
	length := int(len_text.i64())
	if length < 0 || colon + 1 + length > d.data.len {
		return error('bencode: string length out of range')
	}
	out := d.data[colon + 1..colon + 1 + length].bytestr()
	d.pos = colon + 1 + length
	return out
}

fn all_digits(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

pub struct TorrentFile {
pub:
	path   string
	length i64
}

pub struct Torrent {
pub:
	announce      string
	name          string
	piece_length  int
	pieces        []string
	length        i64
	files         []TorrentFile
	info_hash_raw []u8
}

fn get(obj map[string]BValue, key string) ?BValue {
	if key in obj {
		return obj[key] or { return none }
	}
	return none
}

fn as_string(v BValue) string {
	match v {
		string {
			return v
		}
		else {
			return ''
		}
	}
}

fn as_int(v BValue) i64 {
	match v {
		i64 {
			return v
		}
		else {
			return 0
		}
	}
}

fn string_field(obj map[string]BValue, key string) string {
	if value := get(obj, key) {
		return as_string(value)
	}
	return ''
}

fn int_field(obj map[string]BValue, key string) i64 {
	if value := get(obj, key) {
		return as_int(value)
	}
	return 0
}

pub fn parse(data []u8) !Torrent {
	mut dec := Decoder{ data: data }
	root := dec.value() or { return err }
	top := match root {
		map[string]BValue {
			root
		}
		else {
			return error('torrent: root is not a dictionary')
		}
	}
	if dec.info_raw.len == 0 {
		return error('torrent: no info dictionary')
	}
	info_value := top['info'] or { return error('torrent: no info') }
	info := match info_value {
		map[string]BValue {
			info_value
		}
		else {
			return error('torrent: info is not a dictionary')
		}
	}
	pieces_raw := string_field(info, 'pieces')
	if pieces_raw.len < 20 || pieces_raw.len % 20 != 0 {
		return error('torrent: pieces is not a list of 20-byte hashes')
	}
	mut pieces := []string{}
	for i := 0; i < pieces_raw.len; i += 20 {
		pieces << pieces_raw[i..i + 20]
	}
	name := string_field(info, 'name')
	if name == '' {
		return error('torrent: no name')
	}
	piece_length := int(int_field(info, 'piece length'))
	if piece_length <= 0 {
		return error('torrent: bad piece length')
	}
	mut length := int_field(info, 'length')
	mut files := []TorrentFile{}
	if file_values := get(info, 'files') {
		if file_values is []BValue {
			for entry in file_values {
				if entry is map[string]BValue {
					mut parts := []string{}
					if paths := get(entry, 'path') {
						if paths is []BValue {
							for p in paths {
								parts << as_string(p)
							}
						}
					}
					path := if parts.len > 0 { parts.join('/') } else { name }
					file_len := int_field(entry, 'length')
					length += file_len
					files << TorrentFile{ path: path, length: file_len }
				}
			}
		}
	}
	if files.len == 0 {
		files << TorrentFile{ path: name, length: length }
	}
	return Torrent{
		announce:      string_field(top, 'announce')
		name:          name
		piece_length:  piece_length
		pieces:        pieces
		length:        length
		files:         files
		info_hash_raw: sha1.sum(dec.info_raw)
	}
}

// parse_magnet extracts the info hash and display name from a magnet URI.
pub fn parse_magnet(uri string) !Torrent {
	if !uri.starts_with('magnet:') {
		return error('torrent: not a magnet URI')
	}
	q := uri.index('?') or { return error('torrent: magnet has no query') }
	mut hash_hex := ''
	mut name := ''
	mut tracker := ''
	for pair in uri[q + 1..].split('&') {
		parts := pair.split('=')
		if parts.len != 2 {
			continue
		}
		if parts[0] == 'xt' && parts[1].starts_with('urn:btih:') {
			value := parts[1][9..]
			hash_hex = if value.len == 40 {
				value.to_lower()
			} else if value.len == 32 {
				decoded := base32.decode(value.to_upper().bytes()) or {
					return error('torrent: bad base32 btih')
				}
				hex.encode(decoded, hex.EncodeParams{})
			} else {
				return error('torrent: bad btih length')
			}
		}
		if parts[0] == 'dn' {
			name = percent_decode(parts[1])
		}
		if parts[0] == 'tr' && tracker == '' {
			tracker = urllib.query_unescape(parts[1]) or { parts[1] }
		}
	}
	if hash_hex.len != 40 {
		return error('torrent: magnet has no btih')
	}
	if name == '' {
		name = hash_hex
	}
	return Torrent{
		announce:      tracker
		name:          name
		piece_length:  0
		pieces:        []
		length:        0
		files:         []
		info_hash_raw: hex.decode(hash_hex) or { return error('torrent: bad hex hash') }
	}
}

fn percent_decode(s string) string {
	mut out := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		if s[i] == `%` && i + 2 < s.len {
			hexpair := s[i + 1..i + 3]
			if all_digits(hexpair) || is_hex_letters(hexpair) {
				out.write_u8(u8(hexpair.i64()))
				i += 3
				continue
			}
		}
		if s[i] == `+` {
			out.write_u8(` `)
		} else {
			out.write_u8(s[i])
		}
		i++
	}
	res := out.str()
	unsafe {
		out.free()
	}
	return res
}

fn is_hex_letters(s string) bool {
	for c in s {
		if !((c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)) {
			return false
		}
	}
	return s.len > 0
}
