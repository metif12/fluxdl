// peer.v - the BitTorrent peer wire protocol: handshake, bitfield, requests
// and SHA1-verified pieces. DHT and PEX are deliberately not implemented here.
module torrent

import crypto.sha1
import net

const block_size = 16 * 1024

pub struct Message {
pub:
	id      u8
	payload []u8
}

pub struct Conn {
mut:
	conn      &net.TcpConn
	bitfield  []u8
	choked    bool = true
	pex_peers []Peer
}

fn be32(data []u8) int {
	return (int(data[0]) << 24) | (int(data[1]) << 16) | (int(data[2]) << 8) | int(data[3])
}

fn put_be32(mut out []u8, value int) {
	out << u8(value >> 24)
	out << u8(value >> 16)
	out << u8(value >> 8)
	out << u8(value)
}

// handshake opens a peer connection and validates the 68-byte reply.
pub fn handshake(peer Peer, info_hash []u8, peer_id string) !&Conn {
	if info_hash.len != 20 || peer_id.len != 20 {
		return error('torrent: info_hash and peer_id must be 20 bytes')
	}
	socket := net.dial_tcp('${peer.ip}:${peer.port}')!
	mut msg := []u8{}
	msg << u8(19)
	msg << 'BitTorrent protocol'.bytes()
	// Bit 4 of the fifth reserved byte advertises the extension protocol
	// (BEP 10), which magnet metadata and PEX both travel over.
	mut reserved := []u8{len: 8}
	reserved[5] = 0x10
	msg << reserved
	msg << info_hash
	msg << peer_id.bytes()
	socket.write(msg)!

	mut reply := []u8{len: 68}
	mut got := 0
	for got < 68 {
		mut slice := unsafe { reply[got..] }
		n := socket.read(mut slice)!
		if n <= 0 {
			return error('torrent: peer closed during handshake')
		}
		got += n
	}
	if reply[0] != u8(19) || reply[1..20].bytestr() != 'BitTorrent protocol' {
		return error('torrent: bad handshake')
	}
	if reply[28..48].bytestr() != info_hash.bytestr() {
		return error('torrent: peer info_hash mismatch')
	}
	return &Conn{ conn: socket }
}

fn (mut c Conn) read_exact(mut buf []u8) ! {
	mut got := 0
	for got < buf.len {
		mut slice := unsafe { buf[got..] }
		n := c.conn.read(mut slice)!
		if n <= 0 {
			return error('torrent: peer closed mid-message')
		}
		got += n
	}
}

// next_message reads one length-prefixed peer message (keepalive id 255).
pub fn (mut c Conn) next_message() !Message {
	mut header := []u8{len: 4}
	c.read_exact(mut header)!
	length := be32(header)
	if length == 0 {
		return Message{ id: 255, payload: [] }
	}
	mut body := []u8{len: length}
	c.read_exact(mut body)!
	if body[0] == u8(20) {
		discovered := parse_pex(body[1..]) or { [] }
		c.pex_peers << discovered
	}
	return Message{ id: body[0], payload: body[1..].clone() }
}

fn (mut c Conn) send_message(id u8, payload []u8) ! {
	mut msg := []u8{}
	put_be32(mut msg, payload.len + 1)
	msg << id
	msg << payload
	c.conn.write(msg)!
}

pub fn (mut c Conn) interested() ! {
	c.send_message(2, [])!
}

fn (mut c Conn) request(index int, begin int, length int) ! {
	mut payload := []u8{}
	put_be32(mut payload, index)
	put_be32(mut payload, begin)
	put_be32(mut payload, length)
	c.send_message(6, payload)!
}

// has_piece reports whether the peer's bitfield includes index.
pub fn (c &Conn) has_piece(index int) bool {
	byte_index := index / 8
	if byte_index >= c.bitfield.len {
		return false
	}
	bit := u8(0x80) >> u8(index % 8)
	return (c.bitfield[byte_index] & bit) != 0
}

// wait_until_unchoke processes messages until the peer allows requests.
pub fn (mut c Conn) wait_until_unchoke() ! {
	for i := 0; i < 100; i++ {
		msg := c.next_message() or { return err }
		match msg.id {
			0 {
				return error('torrent: peer choked')
			}
			1 {
				c.choked = false
				return
			}
			5 {
				c.bitfield = msg.payload.clone()
			}
			else {}
		}
	}
	return error('torrent: no unchoke from peer')
}

// piece downloads one piece and verifies its SHA1 against the metainfo.
pub fn (mut c Conn) piece(t &Torrent, index int) ![]u8 {
	if c.choked {
		return error('torrent: peer is choked')
	}
	if index < 0 || index >= t.pieces.len {
		return error('torrent: piece index out of range')
	}
	start := i64(index) * i64(t.piece_length)
	remaining := t.length - start
	piece_len := if remaining < i64(t.piece_length) { int(remaining) } else { t.piece_length }
	mut data := []u8{len: piece_len}
	mut received := 0
	for begin := 0; begin < piece_len; begin += block_size {
		size := if piece_len - begin < block_size { piece_len - begin } else { block_size }
		c.request(index, begin, size)!
	}
	for received < piece_len {
		msg := c.next_message() or { return err }
		if msg.id == 0 {
			return error('torrent: choked while downloading a piece')
		}
		if msg.id != 7 || msg.payload.len < 8 {
			continue
		}
		piece_index := be32(msg.payload[0..4])
		begin := be32(msg.payload[4..8])
		block_data := msg.payload[8..]
		if piece_index != index || begin < 0 || begin + block_data.len > data.len {
			continue
		}
		for i, b in block_data {
			data[begin + i] = b
		}
		received += block_data.len
	}
	hash := sha1.sum(data)
	if hash.bytestr() != t.pieces[index] {
		return error('torrent: piece ${index} failed SHA1 verification')
	}
	return data
}

pub fn (c &Conn) close() {
	c.conn.close() or {}
}
