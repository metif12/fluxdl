// metadata.v - BEP 9 ut_metadata (magnet metadata) and BEP 11 PEX.
module torrent

import crypto.sha1

const extended_handshake = 'd1:md11:ut_metadatai1eee'
const metadata_request = 'd8:msg_typei0e5:piecei0ee'
const metadata_piece_size = 16 * 1024

fn extended_object(payload []u8) !BValue {
	if payload.len == 0 {
		return error('torrent: empty extended message')
	}
	mut decoder := Decoder{ data: payload }
	return decoder.value()
}

fn extended_int(obj map[string]BValue, key string) int {
	return int(int_field(obj, key))
}

fn supports_metadata(obj map[string]BValue) bool {
	value := get(obj, 'm') or { return false }
	if value is map[string]BValue {
		return get(value, 'ut_metadata') != none
	}
	return false
}

// fetch_metadata downloads the info dictionary over ut_metadata and verifies
// its SHA1 against the magnet's info hash before returning it.
pub fn fetch_metadata(mut c Conn, info_hash []u8) ![]u8 {
	c.send_message(20, extended_handshake.bytes())!
	mut pieces := map[int][]u8{}
	mut total := 0
	mut requested := false
	for i := 0; i < 300; i++ {
		msg := c.next_message() or { return err }
		if msg.id != 20 {
			continue
		}
		mut decoder := Decoder{ data: msg.payload }
		value := decoder.value() or { continue }
		obj := match value {
			map[string]BValue {
				value
			}
			else {
				continue
			}
		}
		kind := extended_int(obj, 'msg_type')
		if size := get(obj, 'metadata_size') {
			if total == 0 {
				total = int(as_int(size))
			}
		}
		if kind == 0 {
			if !requested && supports_metadata(obj) {
				c.send_message(20, metadata_request.bytes())!
				requested = true
			}
			continue
		}
		if kind != 1 {
			continue
		}
		index := extended_int(obj, 'piece')
		piece_data := msg.payload[decoder.pos..]
		if piece_data.len == 0 {
			continue
		}
		pieces[index] = piece_data.clone()
		if total <= 0 {
			if size := get(obj, 'total_size') {
				total = int(as_int(size))
			}
		}
		if total <= 0 {
			continue
		}
		expected := (total + metadata_piece_size - 1) / metadata_piece_size
		if pieces.len < expected {
			// Ask for any piece that has not arrived yet.
			for p := 0; p < expected; p++ {
				if p !in pieces {
					mut request := []u8{}
					request << 'd8:msg_typei0e5:piecei'.bytes()
					request << '${p}e'.bytes()
					c.send_message(20, request)!
				}
			}
			continue
		}
		mut metadata := []u8{len: total}
		for p, data in pieces {
			start := p * metadata_piece_size
			if start >= total {
				continue
			}
			end := if start + data.len < total { start + data.len } else { total }
			for j := start; j < end; j++ {
				metadata[j] = data[j - start]
			}
		}
		if sha1.sum(metadata).bytestr() != info_hash.bytestr() {
			return error('torrent: metadata SHA1 mismatch')
		}
		return metadata
	}
	return error('torrent: peer did not provide metadata')
}

// parse_pex decodes the compact peer list from a ut_pex message.
pub fn parse_pex(payload []u8) ![]Peer {
	value := extended_object(payload) or { return err }
	obj := match value {
		map[string]BValue {
			value
		}
		else {
			return error('torrent: PEX message is not a dictionary')
		}
	}
	added := string_field(obj, 'added')
	if added == '' {
		return []
	}
	return parse_compact_peers(added.bytes())
}
