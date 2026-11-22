// ftp.v - a transfer.Fetcher backed by V's net.ftp client.
//
// net.ftp exposes whole-file GET only, so an FTP URL is fetched once into a
// shared cache by head() and written from there by fetch(). Ranges are reported
// as unsupported: the manager collapses to one connection.
module ftp

import fluxdl.plan
import fluxdl.transfer
import net.ftp as netftp
import os

pub struct Target {
pub:
	addr string
	user string
	pass string
	path string
}

// parse_target reads ftp://[user:pass@]host[:port]/path into a target.
pub fn parse_target(raw string) !Target {
	if !raw.starts_with('ftp://') {
		return error('ftp: not an ftp:// URL: ${raw}')
	}
	mut rest := raw[6..]
	mut user := 'anonymous'
	mut pass := 'anonymous@'
	at := rest.index('@') or { -1 }
	if at >= 0 {
		creds := rest[..at]
		rest = rest[at + 1..]
		colon := creds.index(':') or { -1 }
		if colon >= 0 {
			user = creds[..colon]
			pass = creds[colon + 1..]
		} else {
			user = creds
		}
	}
	slash := rest.index('/') or { -1 }
	mut addr := if slash >= 0 { rest[..slash] } else { rest }
	path := if slash >= 0 { rest[slash..] } else { '/' }
	if !addr.contains(':') {
		addr += ':21'
	}
	return Target{
		addr: addr
		user: user
		pass: pass
		path: path
	}
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

// new_fetcher creates a Fetcher with an empty per-URL body cache.
pub fn new_fetcher() &Fetcher {
	return &Fetcher{ cache: &Cache{ data: map[string][]u8{} } }
}

// head downloads the file once and remembers its bytes for fetch().
pub fn (f Fetcher) head(url string) !transfer.Meta {
	target := parse_target(url) or {
		return error('ftp: ${err.msg()}')
	}
	mut client := netftp.new()
	defer {
		client.close() or {}
	}
	client.connect(target.addr) or {
		return error('ftp: connect failed: ${err.msg()}')
	}
	client.login(target.user, target.pass) or {
		return error('ftp: login failed: ${err.msg()}')
	}
	data := client.get(target.path) or {
		return error('ftp: get failed: ${err.msg()}')
	}
	f.cache.put(url, data)
	return transfer.Meta{
		length: data.len
		ranges: false
	}
}

// fetch writes the cached body at the segment offset.
pub fn (f Fetcher) fetch(url string, seg plan.Segment, path string) !i64 {
	data := f.cache.get(url) or {
		return error('ftp: no cached body for ${url}')
	}
	mut file := os.open_file(path, 'r+b')!
	defer {
		file.close()
	}
	file.seek(seg.first, .start)!
	file.write(data)!
	return data.len
}
