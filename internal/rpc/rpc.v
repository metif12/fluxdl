// rpc.v - the aria2 JSON-RPC subset Fluxget already calls.
//
// The point of this module is the cut-over: same loopback HTTP shape, same
// method names, same string-valued numbers. Fluxget's contract test is the
// real definition of done; the tests here are the cheap checks that catch the
// four wire quirks recorded in docs/compat/fluxget.md before that test runs.
module rpc

import aria2v.internal.link
import aria2v.internal.session
import aria2v.internal.transfer
import json2
import os
import sync

pub const version = '0.2.0'

// Download is one row of the queue, in the fields aria2's tellStatus uses.
pub struct Download {
pub mut:
	gid           string
	uri           string
	uris          []string
	status        string
	total         i64
	completed     i64
	path          string
	dir           string
	out           string
	options       map[string]string
	error_code    string
	error_message string
}

// Manager owns the queue and the settings document. It is shared by the HTTP
// server's worker threads, so every read and write of its maps takes mu.
pub struct Manager {
pub mut:
	mu           sync.Mutex
	downloads    map[string]Download
	order        []string
	options      map[string]string
	session_path string
	secret       string
	fetcher      &transfer.Fetcher
	auto_start   bool
	shutdown     bool
	counter      int
}

// new_manager creates an empty queue with aria2-like defaults.
pub fn new_manager(secret string, session_path string) &Manager {
	mut dir := os.getenv('ARIA2V_DIR')
	if dir == '' {
		dir = os.join_path(os.home_dir(), 'Downloads')
	}
	mut opts := map[string]string{}
	opts['dir'] = dir
	opts['max-connection-per-server'] = '4'
	opts['min-split-size'] = '1048576'
	opts['continue'] = 'true'
	return &Manager{
		downloads:    map[string]Download{}
		order:        []
		options:      opts
		session_path: session_path
		secret:       secret
		fetcher:      &transfer.HttpFetcher{}
		auto_start:   true
	}
}

// ---- JSON shapes ---------------------------------------------------------

fn field(obj map[string]json2.Any, key string) json2.Any {
	if key in obj {
		return obj[key] or { json2.Any(json2.Null{}) }
	}
	return json2.Any(json2.Null{})
}

fn any_str(v json2.Any) string {
	match v {
		string {
			return v
		}
		else {
			return ''
		}
	}
}

pub fn any_num_str(v json2.Any) string {
	match v {
		string {
			return v
		}
		int {
			return v.str()
		}
		i64 {
			return v.str()
		}
		u64 {
			return v.str()
		}
		f64 {
			// json2 decodes every JSON number as f64 first, so an integer
			// JSON-RPC code comes back as -32601.0. Print it as an integer.
			return int(v).str()
		}
		else {
			return ''
		}
	}
}

fn any_map(v json2.Any) map[string]json2.Any {
	match v {
		map[string]json2.Any {
			return v
		}
		else {
			return map[string]json2.Any{}
		}
	}
}

fn any_arr(v json2.Any) []json2.Any {
	match v {
		[]json2.Any {
			return v
		}
		else {
			return []json2.Any{}
		}
	}
}

fn any_strings(v json2.Any) []string {
	match v {
		string {
			return [v]
		}
		[]json2.Any {
			mut out := []string{}
			for item in v {
				out << any_str(item)
			}
			return out
		}
		else {
			return []string{}
		}
	}
}

fn string_map(v json2.Any) map[string]string {
	mut out := map[string]string{}
	for k, val in any_map(v) {
		out[k] = any_str(val)
	}
	return out
}

fn any_map_of_strings(m map[string]string) json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in m {
		out[k] = v
	}
	return json2.Any(out)
}

fn ok(id json2.Any, result json2.Any) string {
	res := map[string]json2.Any{
		'jsonrpc': '2.0'
		'id':      id
		'result':  result
	}
	return json2.encode(res)
}

fn fail(id json2.Any, code int, msg string) string {
	err_obj := map[string]json2.Any{
		'code':    code
		'message': msg
	}
	res := map[string]json2.Any{
		'jsonrpc': '2.0'
		'id':      id
		'error':   err_obj
	}
	return json2.encode(res)
}

fn null_id() json2.Any {
	return json2.Any(json2.Null{})
}

// ---- the wire ------------------------------------------------------------

// handle_payload answers one JSON-RPC request body.
//
// A leading `token:<secret>` is stripped after checking it, because aria2
// does NOT repeat it inside system.multicall's inner calls. Every numeric
// field in a result is a string, including in nested objects.
pub fn (mut m Manager) handle_payload(raw string) string {
	decoded := json2.decode[json2.Any](raw) or {
		return fail(null_id(), -32700, 'Parse error')
	}
	obj := any_map(decoded)
	method := any_str(field(obj, 'method'))
	if method == '' {
		return fail(null_id(), -32600, 'Invalid Request')
	}
	id := field(obj, 'id')
	mut params := any_arr(field(obj, 'params'))

	if m.secret != '' {
		provided := if params.len > 0 { any_str(params[0]) } else { '' }
		if !provided.starts_with('token:') || provided[6..] != m.secret {
			return fail(id, -32000, 'Unauthorized')
		}
	}
	if params.len > 0 && any_str(params[0]).starts_with('token:') {
		params = params[1..]
	}

	if method == 'system.multicall' {
		mut out := []json2.Any{}
		for call in any_arr(field_from(params, 0)) {
			c := any_map(call)
			name := any_str(field(c, 'methodName'))
			result, code, msg := m.dispatch(name, any_arr(field(c, 'params')))
			if code != 0 {
				out << json2.Any(map[string]json2.Any{
					'code':    code
					'message': msg
				})
			} else {
				// A successful multicall entry is a one-element array.
				out << json2.Any([result])
			}
		}
		return ok(id, json2.Any(out))
	}

	result, code, msg := m.dispatch(method, params)
	if code != 0 {
		return fail(id, code, msg)
	}
	return ok(id, result)
}

fn field_from(arr []json2.Any, i int) json2.Any {
	if i < arr.len {
		return arr[i]
	}
	return json2.Any(json2.Null{})
}

fn status_obj(d Download) json2.Any {
	mut uri_rows := []json2.Any{}
	for u in d.uris {
		uri_rows << json2.Any(map[string]json2.Any{
			'uri':    u
			'status': 'used'
		})
	}
	mut files := []json2.Any{}
	files << json2.Any(map[string]json2.Any{
		'index':           '1'
		'path':            d.path
		'length':          d.total.str()
		'completedLength': d.completed.str()
		'selected':        'true'
		'uris':            json2.Any(uri_rows)
	})
	return json2.Any(map[string]json2.Any{
		'gid':             d.gid
		'status':          d.status
		'totalLength':     d.total.str()
		'completedLength': d.completed.str()
		'uploadLength':    '0'
		'bitfield':        '0'
		'downloadSpeed':   '0'
		'uploadSpeed':     '0'
		'infoHash':        ''
		'numSeeders':      '0'
		'seeder':          'false'
		'pieceLength':     '1048576'
		'numPieces':       '1'
		'connections':     '1'
		'errorCode':       d.error_code
		'errorMessage':    d.error_message
		'dir':             d.dir
		'files':           json2.Any(files)
	})
}

fn method_names() []string {
	return [
		'aria2.addUri',
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
		'system.multicall',
		'system.listMethods',
	]
}

// dispatch maps a method name to a result, an aria2 error code and a message.
fn (mut m Manager) dispatch(method string, p []json2.Any) (json2.Any, int, string) {
	match method {
		'aria2.addUri' {
			uris := any_strings(field_from(p, 0))
			if uris.len == 0 || uris[0] == '' {
				return json2.Any(''), -32602, 'addUri needs a URI'
			}
			mut opts := map[string]string{}
			if p.len > 1 {
				opts = string_map(p[1])
			}
			return json2.Any(m.add(uris, opts)), 0, ''
		}
		'aria2.tellStatus' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			gid := any_str(field_from(p, 0))
			if gid !in m.downloads {
				return null_id(), -32000, 'GID not found'
			}
			return status_obj(m.downloads[gid]), 0, ''
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
			mut rows := []json2.Any{}
			for gid in m.order {
				d := m.downloads[gid]
				if wanted != '' && d.status != wanted {
					continue
				}
				if wanted == '' && d.status in ['active', 'paused', 'waiting'] {
					continue
				}
				rows << status_obj(d)
			}
			return json2.Any(rows), 0, ''
		}
		'aria2.pause', 'aria2.unpause' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return null_id(), -32000, 'GID not found'
			}
			mut d := m.downloads[gid]
			d.status = if method.ends_with('pause') && !method.ends_with('unpause') {
				'paused'
			} else {
				'active'
			}
			m.downloads[gid] = d
			return json2.Any(gid), 0, ''
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
					m.downloads[gid] = d
				}
			}
			return json2.Any('OK'), 0, ''
		}
		'aria2.remove', 'aria2.removeDownloadResult' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return null_id(), -32000, 'GID not found'
			}
			mut d := m.downloads[gid]
			d.status = 'removed'
			m.downloads[gid] = d
			if method == 'aria2.removeDownloadResult' {
				m.order = m.order.filter(|it| it != gid)
				m.downloads.delete(gid)
			}
			return json2.Any(gid), 0, ''
		}
		'aria2.getFiles', 'aria2.getUris', 'aria2.getServers', 'aria2.getPeers' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return null_id(), -32000, 'GID not found'
			}
			d := m.downloads[gid]
			if method == 'aria2.getUris' {
				mut rows := []json2.Any{}
				for u in d.uris {
					rows << json2.Any(map[string]json2.Any{
						'uri':    u
						'status': 'used'
					})
				}
				return json2.Any(rows), 0, ''
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
				return json2.Any(rows), 0, ''
			}
			// BitTorrent and peers are not in this engine. An honest empty
			// list is better than a row that pretends to be a peer.
			return json2.Any([]json2.Any{}), 0, ''
		}
		'aria2.getOption' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return null_id(), -32000, 'GID not found'
			}
			return any_map_of_strings(m.downloads[gid].options), 0, ''
		}
		'aria2.changeOption' {
			gid := any_str(field_from(p, 0))
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			if gid !in m.downloads {
				return null_id(), -32000, 'GID not found'
			}
			mut d := m.downloads[gid]
			for k, v in string_map(field_from(p, 1)) {
				d.options[k] = v
			}
			m.downloads[gid] = d
			return json2.Any(gid), 0, ''
		}
		'aria2.getGlobalOption' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			return any_map_of_strings(m.options), 0, ''
		}
		'aria2.changeGlobalOption' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			for k, v in string_map(field_from(p, 0)) {
				m.options[k] = v
			}
			return json2.Any('OK'), 0, ''
		}
		'aria2.getGlobalStat' {
			m.mu.lock()
			defer {
				m.mu.unlock()
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
			return json2.Any(map[string]json2.Any{
				'downloadSpeed':   '0'
				'uploadSpeed':     '0'
				'numActive':       active.str()
				'numWaiting':      waiting.str()
				'numStopped':      stopped.str()
				'numStoppedTotal': stopped.str()
			}), 0, ''
		}
		'aria2.getVersion' {
			return json2.Any(map[string]json2.Any{
				'version':         '1.37.0-${version}'
				'enabledFeatures': json2.Any([]json2.Any{})
			}), 0, ''
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
				return null_id(), -32000, err.msg()
			}
			return json2.Any('OK'), 0, ''
		}
		'aria2.shutdown' {
			m.mu.lock()
			m.shutdown = true
			m.mu.unlock()
			return json2.Any('OK'), 0, ''
		}
		'system.listMethods' {
			mut names := []json2.Any{}
			for n in method_names() {
				names << json2.Any(n)
			}
			return json2.Any(names), 0, ''
		}
		else {
			return null_id(), -32601, 'Method not found'
		}
	}
}

// ---- queue mechanics -----------------------------------------------------

fn (mut m Manager) add(uris []string, opts map[string]string) string {
	m.mu.lock()
	m.counter++
	mut gid := m.counter.str()
	for gid.len < 16 {
		gid = '0' + gid
	}
	d := Download{
		gid:           gid
		uri:           uris[0]
		uris:          uris
		status:        'waiting'
		options:       opts
		error_code:    ''
		error_message: ''
	}
	m.downloads[gid] = d
	m.order << gid
	m.mu.unlock()
	if m.auto_start {
		go m.run(gid)
	}
	return gid
}

fn (mut m Manager) run(gid string) {
	m.mu.lock()
	d := m.downloads[gid]
	m.mu.unlock()

	mut dir := d.options['dir']
	if dir == '' {
		dir = m.options['dir']
	}
	mut out := d.options['out']
	if out == '' {
		l := link.parse(d.uri) or {
			m.set_error(gid, 1, err.msg())
			return
		}
		out = link.safe_name(l.name)
	}
	path := os.join_path(dir, out)
	meta := m.fetcher.head(d.uri) or {
		m.set_error(gid, 1, err.msg())
		return
	}
	m.set_started(gid, meta.length, path, dir, out)

	mut conn := 4
	if d.options['max-connection-per-server'] != '' {
		conn = d.options['max-connection-per-server'].int()
	}
	mut min_seg := i64(0)
	if d.options['min-split-size'] != '' {
		min_seg = d.options['min-split-size'].i64()
	}
	mut progress := &transfer.Progress{}
	transfer.download(d.uri, meta.length, 0, path, transfer.Options{
		connections: conn
		min_segment: min_seg
	}, m.fetcher, mut progress) or {
		m.set_error(gid, 1, err.msg())
		return
	}
	m.mu.lock()
	mut cur := m.downloads[gid]
	cur.status = 'complete'
	cur.completed = cur.total
	m.downloads[gid] = cur
	m.mu.unlock()
}

fn (mut m Manager) set_started(gid string, total i64, path string, dir string, out string) {
	m.mu.lock()
	defer {
		m.mu.unlock()
	}
	if gid !in m.downloads {
		return
	}
	mut d := m.downloads[gid]
	d.status = 'active'
	d.total = total
	d.path = path
	d.dir = dir
	d.out = out
	m.downloads[gid] = d
}

fn (mut m Manager) set_error(gid string, code int, msg string) {
	m.mu.lock()
	defer {
		m.mu.unlock()
	}
	if gid !in m.downloads {
		return
	}
	mut d := m.downloads[gid]
	d.status = 'error'
	d.error_code = code.str()
	d.error_message = msg
	m.downloads[gid] = d
}
