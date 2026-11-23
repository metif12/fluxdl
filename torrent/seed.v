// seed.v - serve completed pieces to inbound peers (BEP 3). Seeding is opt-in:
// a download does not automatically become an upload.
module torrent

import fluxdl.link
import net
import os

fn read_exact(socket &net.TcpConn, mut buf []u8) ! {
	mut got := 0
	for got < buf.len {
		mut slice := unsafe { buf[got..] }
		n := socket.read(mut slice) or { return error('seed: peer closed') }
		if n <= 0 {
			return error('seed: peer closed')
		}
		got += n
	}
}

fn send(socket &net.TcpConn, id u8, payload []u8) ! {
	mut msg := []u8{}
	put_be32(mut msg, payload.len + 1)
	msg << id
	msg << payload
	socket.write(msg) or { return error('seed: write failed') }
}

fn seed_peer(socket &net.TcpConn, meta &Torrent, path string) {
	defer {
		socket.close() or {}
	}
	mut handshake_bytes := []u8{len: 68}
	read_exact(socket, mut handshake_bytes) or { return }
	if handshake_bytes[0] != u8(19) || handshake_bytes[1..20].bytestr() != 'BitTorrent protocol' {
		return
	}
	if handshake_bytes[28..48].bytestr() != meta.info_hash_raw.bytestr() {
		return
	}
	mut reply := []u8{}
	reply << u8(19)
	reply << 'BitTorrent protocol'.bytes()
	mut reserved := []u8{len: 8}
	reply << reserved
	reply << meta.info_hash_raw
	reply << peer_id.bytes()
	socket.write(reply) or { return }

	bitfield_size := (meta.pieces.len + 7) / 8
	mut bits := []u8{len: bitfield_size}
	for i := 0; i < bitfield_size; i++ {
		bits[i] = u8(0xff)
	}
	if meta.pieces.len % 8 != 0 {
		bits[bitfield_size - 1] = u8(0xff) << u8(8 - meta.pieces.len % 8)
	}
	send(socket, 5, bits) or { return }
	send(socket, 1, []) or { return }

	mut file := os.open_file(path, 'r') or { return }
	defer {
		file.close()
	}
	for {
		mut head := []u8{len: 4}
		read_exact(socket, mut head) or { return }
		length := be32(head)
		if length == 0 {
			continue
		}
		if length < 0 || length > max_message_size {
			return
		}
		mut body := []u8{len: length}
		read_exact(socket, mut body) or { return }
		if body[0] == u8(2) {
			send(socket, 1, []) or { return }
		}
		if body[0] != u8(6) || body.len < 13 {
			continue
		}
		index := be32(body[1..5])
		begin := be32(body[5..9])
		size := be32(body[9..13])
		if index < 0 || index >= meta.pieces.len || size <= 0 || size > 1024 * 1024 {
			continue
		}
		offset := i64(index) * i64(meta.piece_length) + i64(begin)
		mut block := []u8{len: size}
		n := file.read_from(u64(offset), mut block) or { continue }
		if n <= 0 {
			continue
		}
		mut payload := []u8{}
		put_be32(mut payload, index)
		put_be32(mut payload, begin)
		payload << block[..n]
		send(socket, 7, payload) or { return }
	}
}

// seed listens for inbound peers and serves pieces until it is stopped.
pub fn seed(meta &Torrent, dir string, port int) ! {
	listener := net.listen_tcp(.ip, '0.0.0.0:${port}', net.ListenOptions{}) or {
		return error('seed: cannot listen: ${err.msg()}')
	}
	defer {
		listener.close() or {}
	}
	path := os.join_path(dir, link.safe_name(meta.name))
	if !os.exists(path) {
		return error('seed: completed file not found')
	}
	for {
		conn := listener.accept() or { continue }
		go seed_peer(conn, meta, path)
	}
}
