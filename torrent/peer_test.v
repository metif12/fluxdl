module torrent

fn test_big_endian_helpers() {
	mut buf := []u8{}
	put_be32(mut buf, 0x0102_0304)
	assert buf == [u8(1), 2, 3, 4], '${buf}'
	assert be32(buf) == 0x0102_0304, '${be32(buf)}'
}

fn test_bitfield_membership() {
	conn := &Conn{ conn: unsafe { nil }, bitfield: [u8(0x80), 0] }
	assert conn.has_piece(0), 'first bit set'
	assert !conn.has_piece(1), 'second bit clear'
	assert !conn.has_piece(8), 'outside the bitfield'
}
