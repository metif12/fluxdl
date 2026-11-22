// dht.v - a small KRPC client (BEP 5) used only as a peer-discovery fallback
// when a tracker is absent or returns no peers. No routing table is kept: a
// bounded iterative lookup is enough to seed the swarm for one download.
module torrent

import net
import time

const dht_bootstrap = ['router.bittorrent.com:6881', 'dht.transmissionbt.com:6881']

fn bstr(data []u8) string {
	return '${data.len}:${data.bytestr()}'
}

fn dht_query(addr string, payload string) !BValue {
	socket := net.dial_udp(addr) or {
		return error('dht: dial ${addr}: ${err.msg()}')
	}
	defer {
		socket.close() or {}
	}
	socket.set_read_timeout(2 * time.second)
	socket.write_string(payload) or {
		return error('dht: write ${addr}: ${err.msg()}')
	}
	mut buf := []u8{len: 8192}
	n, _ := socket.read(mut buf) or {
		return error('dht: read ${addr}: ${err.msg()}')
	}
	return decode(buf[..n]) or { return error('dht: bad reply from ${addr}: ${err.msg()}') }
}

pub struct Dht {
mut:
	id  []u8
	tid int
}

pub fn new_dht() &Dht {
	mut id := []u8{len: 20}
	seed_value := i64(time.sys_mono_now())
	for i := 0; i < 20; i++ {
		value := (seed_value + i64(i) * 7919) % 256
		id[i] = u8(value)
	}
	return &Dht{ id: id, tid: 1 }
}

// find_peers walks bootstrap nodes for peers advertising info_hash.
pub fn (mut d Dht) find_peers(info_hash []u8) ![]Peer {
	mut queue := dht_bootstrap.clone()
	mut seen := map[string]bool{}
	mut peers := []Peer{}
	for round := 0; round < 4 && queue.len > 0; round++ {
		addr := queue.pop()
		if seen[addr] {
			continue
		}
		seen[addr] = true
		d.tid++
		tid := '${d.tid % 256}'
		payload := 'd1:t2:${tid}1:y1:q1:q9:get_peers1:ad2:id' + bstr(d.id) +
			'9:info_hash' + bstr(info_hash) + 'ee'
		reply := dht_query(addr, payload) or { continue }
		root := match reply {
			map[string]BValue {
				reply
			}
			else {
				continue
			}
		}
		response := get(root, 'r') or { continue }
		if response is map[string]BValue {
			if values := get(response, 'values') {
				if values is []BValue {
					for value in values {
						if value is string {
							peers << parse_compact_peers(value.bytes()) or { [] }
						}
					}
				}
			}
			if nodes := get(response, 'nodes') {
				if nodes is string {
					raw := nodes
					for i := 0; i + 26 <= raw.len; i += 26 {
						ip := '${u8(raw[i + 20])}.${u8(raw[i + 21])}.${u8(raw[i + 22])}.${u8(raw[i + 23])}'
						port := (int(u8(raw[i + 24])) << 8) | int(u8(raw[i + 25]))
						next := '${ip}:${port}'
						if !seen[next] {
							queue << next
						}
					}
				}
			}
		}
	}
	return peers
}
