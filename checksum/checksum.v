// checksum.v - md5/sha1/sha256 over bytes or a completed file.
//
// A checksum is only useful when a mismatch changes the outcome, so verify_file
// returns a boolean the caller must act on rather than logging a warning.
module checksum

import crypto.md5
import crypto.sha1
import crypto.sha256
import encoding.hex
import os

// hash_bytes returns the lowercase hex digest of data with the named algorithm.
pub fn hash_bytes(data []u8, algo string) !string {
	match algo.to_lower() {
		'md5' {
			return hex.encode(md5.sum(data), hex.EncodeParams{})
		}
		'sha1' {
			return hex.encode(sha1.sum(data), hex.EncodeParams{})
		}
		'sha256' {
			return hex.encode(sha256.sum(data), hex.EncodeParams{})
		}
		else {
			return error('checksum: unsupported algorithm ${algo}')
		}
	}
}

// hash_file streams a completed download through the digest in 64 KiB chunks.
// A 4 GiB file must not become a 4 GiB string just to be verified.
pub fn hash_file(path string, algo string) !string {
	mut file := os.open_file(path, 'r')!
	defer {
		file.close()
	}
	mut buf := []u8{len: 64 * 1024}
	match algo.to_lower() {
		'md5' {
			mut digest := md5.new()
			for {
				n := file.read(mut buf) or {
					if err is os.Eof {
						break
					}
					return err
				}
				if n == 0 {
					break
				}
				digest.write(buf[..n])!
			}
			return hex.encode(digest.sum([]), hex.EncodeParams{})
		}
		'sha1' {
			mut digest := sha1.new()
			for {
				n := file.read(mut buf) or {
					if err is os.Eof {
						break
					}
					return err
				}
				if n == 0 {
					break
				}
				digest.write(buf[..n])!
			}
			return hex.encode(digest.sum([]), hex.EncodeParams{})
		}
		'sha256' {
			mut digest := sha256.new()
			for {
				n := file.read(mut buf) or {
					if err is os.Eof {
						break
					}
					return err
				}
				if n == 0 {
					break
				}
				digest.write(buf[..n])!
			}
			return hex.encode(digest.sum([]), hex.EncodeParams{})
		}
		else {
			return error('checksum: unsupported algorithm ${algo}')
		}
	}
}

// verify_file picks the algorithm from the expected digest length and compares.
pub fn verify_file(path string, expected string) !bool {
	want := expected.trim_space().to_lower()
	algo := match want.len {
		32 {
			'md5'
		}
		40 {
			'sha1'
		}
		64 {
			'sha256'
		}
		else {
			return error('checksum: expected digest must be 32, 40 or 64 hex chars')
		}
	}
	got := hash_file(path, algo)!
	return got == want
}
