module rpc

import fluxdl.metalink
import fluxdl.session
import fluxdl.torrent
import fluxdl.transfer
import fluxdl.util
import json2
import os
import strings

// ---- the wire ------------------------------------------------------------

// rpc_request is the JSON-RPC envelope. Decoding straight into a struct avoids
// building a map of Any values for every request, which is the cheapest win
// available on the poll path. Params stay dynamic; they differ per method.
struct RpcRequest {
	method string
	params []json2.Any = []
	id     ?json2.Any
}

// readonly_method lists calls whose answer depends only on queue/option state,
// so an identical request can reuse its last envelope.
fn readonly_method(method string) bool {
	return match method {
		'aria2.tellStatus', 'aria2.tellActive', 'aria2.tellWaiting', 'aria2.tellStopped',
		'aria2.getFiles', 'aria2.getServers', 'aria2.getUris', 'aria2.getOption',
		'aria2.getGlobalOption', 'aria2.getGlobalStat', 'aria2.getVersion',
		'system.listMethods' {
			true
		}
		else {
			false
		}
	}
}

// handle_payload answers one JSON-RPC request body.
//
// A leading `token:<secret>` is stripped after checking it, because aria2
// does NOT repeat it inside system.multicall's inner calls. Every numeric
// field in a result is a string, including in nested objects.
pub fn (mut m Manager) handle_payload(raw string) string {
	req := json2.decode[RpcRequest](raw) or {
		return fail(null_id(), -32700, 'Parse error')
	}
	method := req.method
	if method == '' {
		return fail(null_id(), -32600, 'Invalid Request')
	}
	// A request without an id is a JSON-RPC notification: do not answer it.
	// An empty response is the signal the HTTP handler turns into 204.
	id := req.id or { return '' }
	params := req.params

	if m.secret != '' {
		provided := if params.len > 0 { any_str(params[0]) } else { '' }
		if !provided.starts_with('token:') || !util.secure_equal(provided[6..], m.secret) {
			return fail(id, -32000, 'Unauthorized')
		}
	}
	// Slicing shares storage; it does not need the clone a mutating local
	// would. The token is checked on the original params, then removed for
	// dispatch exactly as aria2 does.
	args := if params.len > 0 && any_str(params[0]).starts_with('token:') {
		params[1..]
	} else {
		params
	}

	cacheable := readonly_method(method)
	if cacheable {
		m.mu.lock()
		if raw in m.responses {
			cached := m.responses[raw]
			if cached.queue_version == m.queue_version && cached.options_version == m.options_version {
				m.mu.unlock()
				return cached.body
			}
		}
		m.mu.unlock()
	}

	if method == 'system.multicall' {
		mut out := strings.new_builder(256)
		out.write_byte(`[`)
		mut first_entry := true
		for call in any_arr(field_from(args, 0)) {
			c := any_map(call)
			name := any_str(field(c, 'methodName'))
			result_json, code, msg := m.dispatch(name, any_arr(field(c, 'params')))
			if !first_entry {
				out.write_byte(`,`)
			}
			first_entry = false
			if code != 0 {
				mut err_obj := map[string]json2.Any{
					'code':    json2.Any(code)
					'message': json2.Any(msg)
				}
				out.write_string(json2.encode(err_obj))
			} else {
				// A successful multicall entry is a one-element array.
				out.write_byte(`[`)
				out.write_string(result_json)
				out.write_byte(`]`)
			}
		}
		out.write_byte(`]`)
		multicall_json := out.str()
		unsafe {
			out.free()
		}
		return ok(id, multicall_json)
	}

	result_json, code, msg := m.dispatch(method, args)
	if code != 0 {
		return fail(id, code, msg)
	}
	body := ok(id, result_json)
	if cacheable {
		m.mu.lock()
		m.responses[raw] = ResponseCache{
			queue_version:   m.queue_version
			options_version: m.options_version
			body:            body
		}
		m.mu.unlock()
	}
	return body
}

fn method_names() []string {
	return [
		'aria2.addUri',
		'aria2.addTorrent',
		'aria2.addMagnet',
		'aria2.tellStatus',
		'aria2.tellActive',
		'aria2.tellWaiting',
		'aria2.tellStopped',
		'aria2.pause',
		'aria2.unpause',
		'aria2.pauseAll',
		'aria2.unpauseAll',
		'aria2.remove',
		'aria2.removeDownloadResult',
		'aria2.getFiles',
		'aria2.getServers',
		'aria2.getUris',
		'aria2.getOption',
		'aria2.changeOption',
		'aria2.getPeers',
		'aria2.getGlobalStat',
		'aria2.getVersion',
		'aria2.getGlobalOption',
		'aria2.changeGlobalOption',
		'aria2.saveSession',
		'aria2.shutdown',
		'aria2.addMetalink',
		'aria2.getNotices',
		'system.multicall',
		'system.listMethods',
	]
}

// dispatch maps a method name to an already-encoded JSON result, an aria2
// error code and a message. Encoding once here, rather than building an Any
// tree for every poll, is the difference between a cheap tick and a costly
// one when the queue has hundreds of rows.
fn (mut m Manager) dispatch(method string, p []json2.Any) (string, int, string) {
	match method {
		'aria2.addUri' {
			uris := any_strings(field_from(p, 0))
			if uris.len == 0 || uris[0] == '' {
				return '""', -32602, 'addUri needs a URI'
			}
			mut opts := map[string]string{}
			if p.len > 1 {
				opts = string_map(p[1])
			}
			gid := m.add(uris, opts) or {
				return '""', -32000, err.msg()
			}
			return json2.encode(gid), 0, ''
		}
		'aria2.tellStatus' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			gid := any_str(field_from(p, 0))
			if gid !in m.downloads {
				return 'null', -32000, 'GID not found'
			}
			return m.status_json(gid), 0, ''
		}
		'aria2.tellActive', 'aria2.tellWaiting', 'aria2.tellStopped' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			wanted := if method.ends_with('Active') {
				'active'
			} else if method.ends_with('Waiting') {
				'waiting'
			} else {
				''
			}
			cache_key := if wanted == '' { 'stopped' } else { wanted }
			if cache_key in m.row_lists {
				cached := m.row_lists[cache_key]
				if cached.version == m.queue_version && cached.json != '' {
					return cached.json, 0, ''
				}
			}
			// Build the array directly: no slice of row strings and no join copy.
			mut rows := strings.new_builder(512)
			rows.write_byte(`[`)
			mut first_row := true
			for gid in m.order {
				d := m.downloads[gid]
				if wanted != '' && d.status != wanted {
					continue
				}
				if wanted == '' && d.status in ['active', 'paused', 'waiting'] {
					continue
				}
				if !first_row {
					rows.write_byte(`,`)
				}
				first_row = false
				rows.write_string(m.status_json(gid))
			}
			rows.write_byte(`]`)
			result_json := rows.str()
			unsafe {
				rows.free()
			}
			m.row_lists[cache_key] = RowsCache{ version: m.queue_version, json: result_json }
			return result_json, 0, ''
		}
		'aria2.pause', 'aria2.unpause' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return 'null', -32000, 'GID not found'
			}
			mut d := m.downloads[gid]
			d.status = if method.ends_with('pause') && !method.ends_with('unpause') {
				'paused'
			} else {
				'active'
			}
			d.version++
			m.queue_version++
			m.downloads[gid] = d
			if d.status == 'paused' && gid in m.cancels {
				(m.cancels[gid] or { &transfer.Cancel{} }).stop()
			}
			return json2.encode(gid), 0, ''
		}
		'aria2.pauseAll', 'aria2.unpauseAll' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			new_status := if method == 'aria2.pauseAll' { 'paused' } else { 'active' }
			for gid in m.order {
				mut d := m.downloads[gid]
				if d.status in ['active', 'paused'] {
					d.status = new_status
					d.version++
					m.downloads[gid] = d
					if new_status == 'paused' && gid in m.cancels {
						(m.cancels[gid] or { &transfer.Cancel{} }).stop()
					}
				}
			}
			m.queue_version++
			return '"OK"', 0, ''
		}
		'aria2.remove', 'aria2.removeDownloadResult' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return 'null', -32000, 'GID not found'
			}
			mut d := m.downloads[gid]
			d.status = 'removed'
			d.version++
			m.queue_version++
			m.downloads[gid] = d
			if gid in m.cancels {
				(m.cancels[gid] or { &transfer.Cancel{} }).stop()
			}
			if method == 'aria2.removeDownloadResult' {
				m.order = m.order.filter(|it| it != gid)
				m.downloads.delete(gid)
				m.status_cache.delete(gid)
				m.cancels.delete(gid)
			}
			return json2.encode(gid), 0, ''
		}
		'aria2.getFiles', 'aria2.getUris', 'aria2.getServers', 'aria2.getPeers' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return 'null', -32000, 'GID not found'
			}
			d := m.downloads[gid]
			if method == 'aria2.getUris' {
				mut rows := []json2.Any{}
				for u in d.uris {
					state := if d.active_uri == '' || d.active_uri == u {
						'used'
					} else {
						'waiting'
					}
					rows << json2.Any(map[string]json2.Any{
						'uri':    u
						'status': state
					})
				}
				return json2.encode(rows), 0, ''
			}
			if method == 'aria2.getFiles' {
				mut rows := []json2.Any{}
				rows << json2.Any(map[string]json2.Any{
					'index':           '1'
					'path':            d.path
					'length':          d.total.str()
					'completedLength': d.completed.str()
					'selected':        'true'
					'uris':            json2.Any([]json2.Any{})
				})
				return json2.encode(rows), 0, ''
			}
			// BitTorrent and peers are not in this engine. An honest empty
			// list is better than a row that pretends to be a peer.
			return '[]', 0, ''
		}
		'aria2.getOption' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return 'null', -32000, 'GID not found'
			}
			return json2.encode(any_map_of_strings(m.downloads[gid].options)), 0, ''
		}
		'aria2.changeOption' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return 'null', -32000, 'GID not found'
			}
			mut d := m.downloads[gid]
			for k, v in string_map(field_from(p, 1)) {
				d.options[k] = v
			}
			d.version++
			m.queue_version++
			m.downloads[gid] = d
			return json2.encode(gid), 0, ''
		}
		'aria2.getGlobalOption' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if m.option_version == m.options_version && m.option_json != '' {
				return m.option_json, 0, ''
			}
			m.option_json = json2.encode(any_map_of_strings(m.options))
			m.option_version = m.options_version
			return m.option_json, 0, ''
		}
		'aria2.changeGlobalOption' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			for k, v in string_map(field_from(p, 0)) {
				m.options[k] = v
			}
			m.options_version++
			return '"OK"', 0, ''
		}
		'aria2.getGlobalStat' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if m.stat_version == m.queue_version && m.stat_json != '' {
				return m.stat_json, 0, ''
			}
			mut active := 0
			mut waiting := 0
			mut stopped := 0
			for gid in m.order {
				match m.downloads[gid].status {
					'active' {
						active++
					}
					'waiting' {
						waiting++
					}
					else {
						stopped++
					}
				}
			}
			mut stat := map[string]json2.Any{
				'downloadSpeed':   '0'
				'uploadSpeed':     '0'
				'numActive':       active.str()
				'numWaiting':      waiting.str()
				'numStopped':      stopped.str()
				'numStoppedTotal': stopped.str()
			}
			m.stat_json = json2.encode(stat)
			m.stat_version = m.queue_version
			return m.stat_json, 0, ''
		}
		'aria2.getVersion' {
			return '{"version":"1.37.0-${version}","enabledFeatures":[]}', 0, ''
		}
		'aria2.saveSession' {
			m.mu.lock()
			mut entries := []session.Entry{}
			for gid in m.order {
				d := m.downloads[gid]
				mut opts := map[string]string{}
				for k, v in d.options {
					opts[k] = v
				}
				entries << session.Entry{
					uri:     d.uri
					options: opts
				}
			}
			m.mu.unlock()
			session.save(m.session_path, entries) or {
				return 'null', -32000, err.msg()
			}
			return '"OK"', 0, ''
		}
		'aria2.addTorrent' {
			path := any_str(field_from(p, 0))
			raw := os.read_file(path) or {
				return 'null', -32000, 'cannot read torrent: ${err.msg()}'
			}
			meta := torrent.parse(raw.bytes()) or {
				return 'null', -32000, err.msg()
			}
			mut opts := map[string]string{}
			if p.len > 1 {
				opts = string_map(p[1])
			}
			gid := m.add_torrent(meta, opts) or {
				return 'null', -32000, err.msg()
			}
			return json2.encode(gid), 0, ''
		}
		'aria2.addMagnet' {
			uri := any_str(field_from(p, 0))
			meta := torrent.parse_magnet(uri) or {
				return 'null', -32000, err.msg()
			}
			mut opts := map[string]string{}
			if p.len > 1 {
				opts = string_map(p[1])
			}
			gid := m.add_torrent(meta, opts) or {
				return 'null', -32000, err.msg()
			}
			return json2.encode(gid), 0, ''
		}
		'aria2.addMetalink' {
			path := any_str(field_from(p, 0))
			raw := os.read_file(path) or {
				return 'null', -32000, 'cannot read metalink: ${err.msg()}'
			}
			files := metalink.parse(raw) or {
				return 'null', -32000, err.msg()
			}
			mut gids := []json2.Any{}
			for file in files {
				mut opts := map[string]string{
					'out': file.name
				}
				for algo in ['sha256', 'sha1', 'md5'] {
					if algo in file.hashes {
						opts['checksum'] = file.hashes[algo]
						break
					}
				}
				gid := m.add(file.urls, opts) or { continue }
				gids << json2.Any(gid)
			}
			return json2.encode(gids), 0, ''
		}
		'aria2.getNotices' {
			return json2.encode(m.drain_notices()), 0, ''
		}
		'aria2.shutdown' {
			m.mu.lock()
			m.shutdown = true
			m.mu.unlock()
			return '"OK"', 0, ''
		}
		'system.listMethods' {
			mut names := []json2.Any{}
			for n in method_names() {
				names << json2.Any(n)
			}
			return json2.encode(names), 0, ''
		}
		else {
			return 'null', -32601, 'Method not found'
		}
	}
}

// supervise restarts downloads that have been active without progress longer
// than the configured stall timeout. Fluxget still owns process supervision.
