// client.v - orchestrate a torrent download: announce, connect, choose rarest
// pieces first, verify every piece and write it at its file offset.
module torrent

import fluxdl.link
import os

const peer_id = '-FLUX01-000000000000'

// download fetches a .torrent into dir and returns the completed file path.
pub fn download(t &Torrent, dir string) !string {
	if t.announce == '' {
		return error('torrent: no tracker; DHT discovery is not implemented')
	}
	if t.pieces.len == 0 {
		return error('torrent: no piece hashes; magnet metadata exchange is not implemented')
	}
	path := os.join_path(dir, link.safe_name(t.name))
	if !os.exists(path) {
		os.create(path)!
	}
	if os.file_size(path) != t.length {
		os.truncate(path, u64(t.length))!
	}

	peers := announce(t.announce, t.info_hash_raw, peer_id, 6881, t.length) or {
		return error('torrent: announce failed: ${err.msg()}')
	}
	mut conns := []&Conn{}
	for peer in peers {
		conn := handshake(peer, t.info_hash_raw, peer_id) or { continue }
		conn.wait_until_unchoke() or {
			conn.close()
			continue
		}
		conns << conn
	}
	if conns.len == 0 {
		return error('torrent: no usable peers')
	}

	// Rarest-first: a piece held by fewer peers is fetched earlier.
	mut availability := map[int]int{}
	for conn in conns {
		for i := 0; i < t.pieces.len; i++ {
			if conn.has_piece(i) {
				availability[i]++
			}
		}
	}
	mut order := []int{}
	for i := 0; i < t.pieces.len; i++ {
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
			data := conn.piece(t, index) or { continue }
			file.seek(i64(index) * i64(t.piece_length), .start)!
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
