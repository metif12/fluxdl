// rpc.v - the aria2 JSON-RPC subset Fluxget already calls.
//
// The point of this module is the cut-over: same loopback HTTP shape, same
// method names, same string-valued numbers. Fluxget's contract test is the
// real definition of done; the tests here are the cheap checks that catch the
// four wire quirks recorded in docs/compat/fluxget.md before that test runs.
module rpc

import fluxdl.link
import fluxdl.session
import fluxdl.transfer
import json2
import os
import strings
import sync

pub const version = '0.4.0'

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
	// version changes on every mutation. A status object is encoded once per
	// version and reused by every poll in between, which is the hot path:
	// Fluxget asks for the whole queue on every tick.
	version int
}

// StatusCache is one already-encoded tellStatus row.
struct StatusCache {
	version int
	json    string
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
	status_cache map[string]StatusCache
	auto_start   bool
	shutdown     bool
	counter      int
}

// new_manager creates an empty queue with aria2-like defaults.
pub fn new_manager(secret string, session_path string) &Manager {
	mut dir := os.getenv('FLUXDL_DIR')
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
		status_cache: map[string]StatusCache{}
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

// ok wraps an already-encoded result. The hot methods build their result
// directly instead of allocating an Any tree for json2 to walk again.
fn ok(id json2.Any, result_json string) string {
	mut sb := strings.new_builder(result_json.len + 64)
	sb.write_string('{"jsonrpc":"2.0","id":')
	sb.write_string(json2.encode(id))
	sb.write_string(',"result":')
	sb.write_string(result_json)
	sb.write_string('}')
	res := sb.str()
	unsafe {
		sb.free()
	}
	return res
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

// rpc_request is the JSON-RPC envelope. Decoding straight into a struct avoids
// building a map of Any values for every request, which is the cheapest win
// available on the poll path. Params stay dynamic; they differ per method.
struct RpcRequest {
	method string
	params []json2.Any = []
	id     json2.Any   = json2.Any(json2.Null{})
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
	id := req.id
	params := req.params

	if m.secret != '' {
		provided := if params.len > 0 { any_str(params[0]) } else { '' }
		if !provided.starts_with('token:') || provided[6..] != m.secret {
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

	if method == 'system.multicall' {
		mut out := []string{}
		for call in any_arr(field_from(args, 0)) {
			c := any_map(call)
			name := any_str(field(c, 'methodName'))
			result_json, code, msg := m.dispatch(name, any_arr(field(c, 'params')))
			if code != 0 {
				mut err_obj := map[string]json2.Any{
					'code':    json2.Any(code)
					'message': json2.Any(msg)
				}
				out << json2.encode(err_obj)
			} else {
				// A successful multicall entry is a one-element array.
				out << '[' + result_json + ']'
			}
		}
		return ok(id, '[' + out.join(',') + ']')
	}

	result_json, code, msg := m.dispatch(method, args)
	if code != 0 {
		return fail(id, code, msg)
	}
	return ok(id, result_json)
}

fn field_from(arr []json2.Any, i int) json2.Any {
	if i < arr.len {
		return arr[i]
	}
	return json2.Any(json2.Null{})
}

// RowBuilder writes one JSON object without building an Any tree first.
// Every field in a tellStatus row is a string on the wire, except `files`.
struct RowBuilder {
mut:
	sb    strings.Builder
	first bool = true
}

fn (mut b RowBuilder) sep() {
	if !b.first {
		b.sb.write_byte(`,`)
	}
	b.first = false
}

fn (mut b RowBuilder) add_str(key string, value string) {
	b.sep()
	b.sb.write_byte(`"`)
	b.sb.write_string(key)
	b.sb.write_string('":')
	b.sb.write_string(json2.encode(value))
}

fn (mut b RowBuilder) add_num(key string, value string) {
	b.sep()
	b.sb.write_byte(`"`)
	b.sb.write_string(key)
	b.sb.write_string('":"')
	b.sb.write_string(value)
	b.sb.write_byte(`"`)
}

fn (mut b RowBuilder) add_raw(key string, value string) {
	b.sep()
	b.sb.write_byte(`"`)
	b.sb.write_string(key)
	b.sb.write_string('":')
	b.sb.write_string(value)
}

fn (mut b RowBuilder) done() string {
	b.sb.write_byte(`}`)
	res := b.sb.str()
	unsafe {
		b.sb.free()
	}
	return res
}

// encode_status is the cache miss path: build the exact tellStatus shape as
// bytes, so a row with a large path or error message does not allocate a map
// and a sum-type wrapper for every one of its fields.
fn encode_status(d Download) string {
	mut uris := []string{}
	for u in d.uris {
		mut ub := RowBuilder{ sb: strings.new_builder(96) }
		ub.sb.write_byte(`{`)
		ub.add_str('uri', u)
		ub.add_str('status', 'used')
		uris << ub.done()
	}

	mut fb := RowBuilder{ sb: strings.new_builder(256) }
	fb.sb.write_byte(`{`)
	fb.add_str('index', '1')
	fb.add_str('path', d.path)
	fb.add_num('length', d.total.str())
	fb.add_num('completedLength', d.completed.str())
	fb.add_str('selected', 'true')
	fb.add_raw('uris', '[' + uris.join(',') + ']')
	files_json := fb.done()

	mut b := RowBuilder{ sb: strings.new_builder(512) }
	b.sb.write_byte(`{`)
	b.add_str('gid', d.gid)
	b.add_str('status', d.status)
	b.add_num('totalLength', d.total.str())
	b.add_num('completedLength', d.completed.str())
	b.add_num('uploadLength', '0')
	b.add_num('bitfield', '0')
	b.add_num('downloadSpeed', '0')
	b.add_num('uploadSpeed', '0')
	b.add_str('infoHash', '')
	b.add_num('numSeeders', '0')
	b.add_str('seeder', 'false')
	b.add_num('pieceLength', '1048576')
	b.add_num('numPieces', '1')
	b.add_num('connections', '1')
	b.add_str('errorCode', d.error_code)
	b.add_str('errorMessage', d.error_message)
	b.add_str('dir', d.dir)
	b.add_raw('files', '[' + files_json + ']')
	return b.done()
}

// status_json encodes one row once per version. Callers hold m.mu, so the
// cache is safe to read and write here.
fn (mut m Manager) status_json(gid string) string {
	d := m.downloads[gid]
	if gid in m.status_cache {
		cached := m.status_cache[gid]
		if cached.version == d.version {
			return cached.json
		}
	}
	encoded := encode_status(d)
	m.status_cache[gid] = StatusCache{
		version: d.version
		json:    encoded
	}
	return encoded
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
			return json2.encode(m.add(uris, opts)), 0, ''
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
			mut rows := []string{}
			for gid in m.order {
				d := m.downloads[gid]
				if wanted != '' && d.status != wanted {
					continue
				}
				if wanted == '' && d.status in ['active', 'paused', 'waiting'] {
					continue
				}
				rows << m.status_json(gid)
			}
			return '[' + rows.join(',') + ']', 0, ''
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
			m.downloads[gid] = d
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
				}
			}
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
			m.downloads[gid] = d
			if method == 'aria2.removeDownloadResult' {
				m.order = m.order.filter(|it| it != gid)
				m.downloads.delete(gid)
				m.status_cache.delete(gid)
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
					rows << json2.Any(map[string]json2.Any{
						'uri':    u
						'status': 'used'
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
			m.downloads[gid] = d
			return json2.encode(gid), 0, ''
		}
		'aria2.getGlobalOption' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			return json2.encode(any_map_of_strings(m.options)), 0, ''
		}
		'aria2.changeGlobalOption' {
			m.mu.lock()
			defer {
				m.mu.unlock()
			}
			for k, v in string_map(field_from(p, 0)) {
				m.options[k] = v
			}
			return '"OK"', 0, ''
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
			mut stat := map[string]json2.Any{
				'downloadSpeed':   '0'
				'uploadSpeed':     '0'
				'numActive':       active.str()
				'numWaiting':      waiting.str()
				'numStopped':      stopped.str()
				'numStoppedTotal': stopped.str()
			}
			return json2.encode(stat), 0, ''
		}
		'aria2.getVersion' {
			mut ver := map[string]json2.Any{
				'version':         '1.37.0-${version}'
				'enabledFeatures': json2.Any([]json2.Any{})
			}
			return json2.encode(ver), 0, ''
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
		version:       1
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
	transfer.download_with_meta(d.uri, meta, meta.length, 0, path, transfer.Options{
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
	cur.version++
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
	d.version++
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
	d.version++
	m.downloads[gid] = d
}
