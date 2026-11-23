// sftp.v - an SFTP transfer.Fetcher.
//
// V has no SSH/SFTP library, so this fetcher shells out to the system `sftp`
// client with an argv vector and a batch file. No shell is involved, and every
// path is passed as a separate argument, so whitespace and metacharacters in
// filenames cannot change the command.
module sftp

import fluxdl.plan
import fluxdl.transfer
import fluxdl.util
import os
import time

// A batch file is line-oriented: a newline in a remote path becomes a new
// sftp command. Refuse anything that could change the command structure.
fn valid_batch_path(path string) bool {
	if path == '' || !path.starts_with('/') {
		return false
	}
	for c in path {
		if c < 0x20 || c == `"` || c == `\\` {
			return false
		}
	}
	return true
}

pub struct Target {
pub:
	host string
	user string
	port int
	path string
}

pub fn parse_target(raw string) !Target {
	if !raw.starts_with('sftp://') {
		return error('sftp: not an sftp:// URL: ${raw}')
	}
	mut rest := raw[7..]
	mut user := ''
	at := rest.index('@') or { -1 }
	if at >= 0 {
		user = rest[..at]
		rest = rest[at + 1..]
	}
	colon := rest.index(':') or { -1 }
	mut port := 22
	host := if colon >= 0 { rest[..colon] } else { rest }
	if colon >= 0 {
		tail := rest[colon + 1..]
		slash := tail.index('/') or { -1 }
		port_text := if slash >= 0 { tail[..slash] } else { tail }
		port = util.int_or(port_text, 0)
		if port <= 0 {
			return error('sftp: bad port ${port_text}')
		}
	}
	slash := rest.index('/') or { -1 }
	path := if slash >= 0 { rest[slash..] } else { '/' }
	if host == '' {
		return error('sftp: no host')
	}
	return Target{ host: host, user: user, port: port, path: path }
}

struct Cache {
mut:
	data map[string][]u8
}

fn (mut c Cache) put(key string, value []u8) {
	c.data[key] = value
}

fn (c &Cache) get(key string) ?[]u8 {
	if key in c.data {
		return c.data[key]
	}
	return none
}

pub struct Fetcher {
	cache &Cache
}

pub fn new_fetcher() &Fetcher {
	return &Fetcher{ cache: &Cache{ data: map[string][]u8{} } }
}

pub fn (f Fetcher) head(url string) !transfer.Meta {
	target := parse_target(url) or {
		return error('sftp: ${err.msg()}')
	}
	if !valid_batch_path(target.path) {
		return error('sftp: unsafe remote path ${target.path}')
	}
	suffix := '${os.getpid()}-${i64(time.sys_mono_now())}'
	tmp := os.join_path(os.temp_dir(), 'fluxdl-sftp-${suffix}.bin')
	batch := os.join_path(os.temp_dir(), 'fluxdl-sftp-${suffix}.batch')
	defer {
		os.rm(tmp) or {}
		os.rm(batch) or {}
	}
	os.write_file(batch, 'get "${target.path}" ${tmp}\nquit\n') or {
		return error('sftp: cannot write batch file')
	}

	mut args := ['-b', batch, '-P', '${target.port}']
	remote := if target.user == '' { target.host } else { '${target.user}@${target.host}' }
	args << remote
	mut process := os.new_process('sftp')
	process.set_args(args)
	process.set_redirect_stdio()
	process.run()
	process.wait()
	code := process.code
	process.close()
	if code != 0 {
		return error('sftp: client exited ${code}')
	}
	if !os.exists(tmp) {
		return error('sftp: no file was downloaded')
	}
	data := os.read_file(tmp) or {
		return error('sftp: cannot read downloaded file')
	}
	f.cache.put(url, data.bytes())
	return transfer.Meta{ length: data.len, ranges: false }
}

pub fn (f Fetcher) fetch(url string, seg plan.Segment, path string) !i64 {
	data := f.cache.get(url) or {
		return error('sftp: no cached body for ${url}')
	}
	mut file := os.open_file(path, 'r+b')!
	defer {
		file.close()
	}
	file.seek(seg.first, .start)!
	file.write(data)!
	return data.len
}
