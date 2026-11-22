module checksum

import os

fn test_known_digests() {
	data := 'abc'.bytes()
	assert hash_bytes(data, 'md5') or { '' } == '900150983cd24fb0d6963f7d28e17f72', 'md5'
	assert hash_bytes(data, 'sha1') or { '' } == 'a9993e364706816aba3e25717850c26c9cd0d89d', 'sha1'
	assert hash_bytes(data, 'sha256') or { '' } == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256'
}

fn test_verify_file_accepts_a_match_and_rejects_a_mismatch() {
	path := os.join_path(os.temp_dir(), 'fluxdl-checksum-test.txt')
	os.write_file(path, 'abc') or { panic(err.msg()) }
	assert verify_file(path, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') or {
		false
	} == true, 'matching sha256'
	assert verify_file(path, '0000000000000000000000000000000000000000000000000000000000000000') or {
		true
	} == false, 'mismatching sha256'
}

fn test_unsupported_algorithm_is_rejected() {
	hash_bytes('x'.bytes(), 'sha512') or {
		assert err.msg().contains('unsupported'), err.msg()
		return
	}
	assert false, 'sha512 must be rejected'
}
