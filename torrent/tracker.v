// tracker.v - HTTP tracker announce and peer list decoding.
module torrent

import net.http
import net.urllib

pub struct Peer {
pub:
	ip   string
	port int
}

// announce asks an HTTP tracker for peers. Only compact and dictionary-style
// peer lists are understood; a malformed response is an error.
pub fn announce(announce_url string, info_hash []u8, peer_id string, port int, left i64) ![]Peer {
	if announce_url == '' {
		return error('torrent: magnet has no tracker')
	}
	sep := if announce_url.contains('?') { '&' } else { '?' }
	url := announce_url + sep +
		'info_hash=${urllib.query_escape(info_hash.bytestr())}' +
		'&peer_id=${urllib.query_escape(peer_id)}' +
		'&port=${port}&uploaded=0&downloaded=0&left=${left}' +
		'&compact=1&event=started'
	response := http.fetch(method: .get, url: url, validate: true)!
	if response.status_code != 200 {
		return error('torrent: tracker returned HTTP ${response.status_code}')
	}
	value := decode(response.body.bytes()) or {
		return error('torrent: bad tracker response: ${err.msg()}')
	}
	root := match value {
		map[string]BValue {
			value
		}
		else {
			return error('torrent: tracker response is not a dictionary')
		}
	}
	peers_value := get(root, 'peers') or { return error('torrent: tracker sent no peers') }
	mut out := []Peer{}
	match peers_value {
		string {
			raw := peers_value
			if raw.len % 6 != 0 {
				return error('torrent: malformed compact peer list')
			}
			for i := 0; i < raw.len; i += 6 {
				out << Peer{
					ip:   '${u8(raw[i])}.${u8(raw[i + 1])}.${u8(raw[i + 2])}.${u8(raw[i + 3])}'
					port: (int(u8(raw[i + 4])) << 8) | int(u8(raw[i + 5]))
				}
			}
		}
		[]BValue {
			for item in peers_value {
				if item is map[string]BValue {
					out << Peer{
						ip:   string_field(item, 'ip')
						port: int(int_field(item, 'port'))
					}
				}
			}
		}
		else {
			return error('torrent: unsupported peer list format')
		}
	}
	return out
}
