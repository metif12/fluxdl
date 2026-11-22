// client.v - orchestrate a torrent download: announce, connect, choose rarest
// pieces first, verify every piece and write it at its file offset.
module torrent

import fluxdl.link
import os

const peer_id = '-FLUX01-000000000000'

// download fetches a .torrent into dir and returns the completed file path.
// resolve_magnet asks tracker peers for the info dictionary over ut_metadata.
pub fn resolve_magnet(magnet &Torrent) !&Torrent {
	mut peers := []Peer{}
	if magnet.announce != '' {
		peers = announce(magnet.announce, magnet.info_hash_raw, peer_id, 6881, 0) or { [] }
	}
	if peers.len == 0 {
		mut dht := new_dht()
		peers = dht.find_peers(magnet.info_hash_raw) or { [] }
	}
	if peers.len == 0 {
		return error('torrent: no peers from tracker or DHT for magnet')
	}
	for peer in peers {
		mut conn := handshake(peer, magnet.info_hash_raw, peer_id) or { continue }
		metadata := fetch_metadata(mut conn, magnet.info_hash_raw) or {
			conn.close()
			continue
		}
		conn.close()
		parsed := parse(metadata) or { continue }
		if parsed.info_hash_raw.bytestr() == magnet.info_hash_raw.bytestr() {
			return &parsed
		}
	}
	return error('torrent: no peer supplied valid metadata')
}

pub fn download(t &Torrent, dir string) !string {
	meta := if t.pieces.len == 0 { resolve_magnet(t) or { return err } } else { t }
	path := os.join_path(dir, link.safe_name(meta.name))
	if !os.exists(path) {
		os.create(path)!
	}
	if os.file_size(path) != meta.length {
		os.truncate(path, u64(meta.length))!
	}

	mut peers := []Peer{}
	if meta.announce != '' {
		peers = announce(meta.announce, meta.info_hash_raw, peer_id, 6881, meta.length) or { [] }
	}
	if peers.len == 0 {
		mut dht := new_dht()
		peers = dht.find_peers(meta.info_hash_raw) or { [] }
	}
	if peers.len == 0 {
		return error('torrent: no peers from tracker or DHT')
	}
	mut conns := []&Conn{}
	for peer in peers {
		conn := handshake(peer, meta.info_hash_raw, peer_id) or { continue }
		conn.wait_until_unchoke() or {
			conn.close()
			continue
		}
		conns << conn
	}
	if conns.len == 0 {
		return error('torrent: no usable peers')
	}

	// PEX: peers met through the extension protocol join the same pool.
	mut discovered := []Peer{}
	for conn in conns {
		discovered << conn.pex_peers
	}
	for peer in discovered {
		if conns.len >= 30 {
			break
		}
		conn := handshake(peer, meta.info_hash_raw, peer_id) or { continue }
		conn.wait_until_unchoke() or {
			conn.close()
			continue
		}
		conns << conn
	}

	// Rarest-first: a piece held by fewer peers is fetched earlier.
	mut availability := map[int]int{}
	for conn in conns {
		for i := 0; i < meta.pieces.len; i++ {
			if conn.has_piece(i) {
				availability[i]++
			}
		}
	}
	mut order := []int{}
	for i := 0; i < meta.pieces.len; i++ {
		order << i
	}
	for i := 0; i < order.len; i++ {
		mut best := i
		for j := i + 1; j < order.len; j++ {
			if availability[order[j]] < availability[order[best]] {
				best = j
			}
		}
		tmp := order[i]
		order[i] = order[best]
		order[best] = tmp
	}

	mut file := os.open_file(path, 'r+b')!
	defer {
		file.close()
		for conn in conns {
			conn.close()
		}
	}
	for index in order {
		mut saved := false
		for conn in conns {
			if !conn.has_piece(index) {
				continue
			}
			data := conn.piece(meta, index) or { continue }
			file.seek(i64(index) * i64(meta.piece_length), .start)!
			file.write(data)!
			saved = true
			break
		}
		if !saved {
			return error('torrent: no peer supplied piece ${index}')
		}
	}
	return path
}
