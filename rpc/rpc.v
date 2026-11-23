// rpc.v - the aria2 JSON-RPC subset Fluxget already calls.
//
// The point of this module is the cut-over: same loopback HTTP shape, same
// method names, same string-valued numbers. Fluxget's contract test is the
// real definition of done; the tests here are the cheap checks that catch the
// four wire quirks recorded in docs/compat/fluxget.md before that test runs.
module rpc

import fluxdl.checksum
import fluxdl.ftp
import fluxdl.link
import fluxdl.metalink
import fluxdl.session
import fluxdl.sftp
import fluxdl.torrent
import fluxdl.transfer
import fluxdl.util
import json2
import os
import strings
import sync
import time

pub const version = '0.4.0'

// max_downloads bounds the live queue, the same ceiling the session reader uses.
const max_downloads = 10000

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
	active_uri    string
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

// ResponseCache is a complete envelope for one repeated read-only request.
struct ResponseCache {
	queue_version   int
	options_version int
	body            string
}

// RowsCache is a whole tellActive/TellWaiting/tellStopped array for one queue
// version. Fluxget polls these every tick; rebuilding 100 row strings per tick
// is the remaining cost after per-row caching.
struct RowsCache {
	version int
	json    string
}

// Manager owns the queue and the settings document. It is shared by the HTTP
// server's worker threads: map reads and writes take mu. Workers snapshot the
// values they need under mu and never read a map after releasing it.
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
	row_lists    map[string]RowsCache
	responses    map[string]ResponseCache
	cancels      map[string]&transfer.Cancel
	notices      []string
	started_at   map[string]i64
	ready        bool
	// Global results are cached the same way as rows: a version bump on any
	// queue or settings mutation is the only thing that invalidates them.
	queue_version   int
	stat_version    int
	stat_json       string
	options_version int
	option_version  int
	option_json     string
	auto_start      bool
	shutdown        bool
	counter         int
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
	opts['max-retries'] = '0'
	opts['retry-delay'] = '1000'
	opts['supervisor-interval'] = '30'
	opts['stall-timeout'] = '300'
	return &Manager{
		downloads:    map[string]Download{}
		order:        []
		options:      opts
		session_path: session_path
		secret:       secret
		fetcher:      transfer.new_http_fetcher()
		status_cache: map[string]StatusCache{}
		row_lists:    map[string]RowsCache{}
		responses:    map[string]ResponseCache{}
		cancels:      map[string]&transfer.Cancel{}
		started_at:   map[string]i64{}
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

fn hex_digit(n u8) string {
	if n < 10 {
		return [u8(n + `0`)].bytestr()
	}
	return [u8(n - 10 + `a`)].bytestr()
}

// write_json_string escapes directly into the row builder. json2.encode is
// correct but allocates a new string for every one of the ~12 string fields
// in a tellStatus row.
fn write_json_string(mut sb strings.Builder, value string) {
	sb.write_byte(`"`)
	for i := 0; i < value.len; i++ {
		c := value[i]
		match c {
			`"` {
				sb.write_string('\\"')
			}
			`\\` {
				sb.write_string('\\\\')
			}
			`\n` {
				sb.write_string('\\n')
			}
			`\r` {
				sb.write_string('\\r')
			}
			`\t` {
				sb.write_string('\\t')
			}
			else {
				if c < 0x20 {
					sb.write_string('\\u00')
					sb.write_string(hex_digit(c >> 4))
					sb.write_string(hex_digit(c & 0x0f))
				} else {
					sb.write_u8(c)
				}
			}
		}
	}
	sb.write_byte(`"`)
}

fn (mut b RowBuilder) add_str(key string, value string) {
	b.sep()
	b.sb.write_byte(`"`)
	b.sb.write_string(key)
	b.sb.write_string('":')
	write_json_string(mut b.sb, value)
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
		state := if d.active_uri == '' || d.active_uri == u { 'used' } else { 'waiting' }
		ub.add_str('status', state)
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
pub fn (mut m Manager) supervise() {
	interval := util.int_or(m.options['supervisor-interval'], 30)
	timeout := util.int_or(m.options['stall-timeout'], 300)
	if interval <= 0 || timeout <= 0 {
		return
	}
	for {
		time.sleep(time.Duration(interval) * time.second)
		m.mu.lock()
		if m.shutdown {
			m.mu.unlock()
			return
		}
		now := i64(time.sys_mono_now())
		mut stalled := []string{}
		for gid in m.order {
			d := m.downloads[gid]
			if d.status != 'active' || d.completed > 0 {
				continue
			}
			start := m.started_at[gid] or { now }
			if now - start > i64(timeout) * i64(time.second) {
				stalled << gid
			}
		}
		m.mu.unlock()
		for gid in stalled {
			m.restart_download(gid)
		}
	}
}

fn (mut m Manager) restart_download(gid string) {
	m.mu.lock()
	if gid !in m.downloads {
		m.mu.unlock()
		return
	}
	(cancels_or_new(m, gid)).stop()
	mut d := m.downloads[gid]
	if d.status != 'active' {
		m.mu.unlock()
		return
	}
	d.status = 'waiting'
	d.error_code = ''
	d.error_message = ''
	d.version++
	m.started_at[gid] = i64(time.sys_mono_now())
	m.cancels[gid] = &transfer.Cancel{}
	m.queue_version++
	m.mu.unlock()
	m.notice('supervisor restarted ${gid}')
	go m.run(gid)
}

fn cancels_or_new(m &Manager, gid string) &transfer.Cancel {
	return m.cancels[gid] or { &transfer.Cancel{} }
}

pub fn (mut m Manager) is_ready() bool {
	m.mu.lock()
	defer {
		m.mu.unlock()
	}
	return m.ready
}

// fetcher_for picks the transport for a URI. The injectable manager fetcher is
// kept for tests and for HTTP; FTP gets its own whole-file implementation.
fn (m &Manager) fetcher_for(url string) &transfer.Fetcher {
	if url.starts_with('ftp://') {
		return ftp.new_fetcher()
	}
	if url.starts_with('sftp://') {
		return sftp.new_fetcher()
	}
	return m.fetcher
}

// ---- queue mechanics -----------------------------------------------------

// notice records a human-readable event for the caller to drain.
fn (mut m Manager) notice(text string) {
	m.mu.lock()
	// Bounded: an untrusted client can generate failures indefinitely.
	if m.notices.len >= 1024 {
		m.notices = m.notices[1..]
	}
	m.notices << text
	m.mu.unlock()
}

// drain_notices returns and clears the pending notices.
pub fn (mut m Manager) drain_notices() []string {
	m.mu.lock()
	defer {
		m.mu.unlock()
	}
	out := m.notices.clone()
	m.notices.clear()
	return out
}

// restore_session re-queues the downloads from the aria2-format session file.
// Fluxget owns supervision; this only rebuilds the queue after a restart.
pub fn (mut m Manager) restore_session() int {
	entries, _ := session.load(m.session_path)
	for e in entries {
		mut opts := map[string]string{}
		for k, v in e.options {
			opts[k] = v
		}
		m.add([e.uri], opts) or {
			m.notice('restore skipped ${e.uri}: ${err.msg()}')
			continue
		}
	}
	m.notice('restored ${entries.len} download(s)')
	return entries.len
}

fn (mut m Manager) add_torrent(meta &torrent.Torrent, opts map[string]string) !string {
	m.mu.lock()
	if m.order.len >= max_downloads {
		m.mu.unlock()
		return error('queue full')
	}
	m.counter++
	mut gid := m.counter.str()
	for gid.len < 16 {
		gid = '0' + gid
	}
	mut dir := opts['dir']
	if dir == '' {
		dir = m.options['dir']
	}
	d := Download{
		gid:           gid
		uri:           'magnet:?xt=urn:btih:${meta.name}'
		uris:          []
		status:        'waiting'
		total:         meta.length
		options:       opts
		error_code:    ''
		error_message: ''
		version:       1
	}
	m.downloads[gid] = d
	m.order << gid
	m.cancels[gid] = &transfer.Cancel{}
	m.started_at[gid] = i64(time.sys_mono_now())
	m.queue_version++
	m.mu.unlock()
	go m.run_torrent(gid, meta, dir)
	return gid
}

fn (mut m Manager) run_torrent(gid string, meta &torrent.Torrent, dir string) {
	name := link.safe_name(meta.name)
	m.set_started(gid, meta.length, os.join_path(dir, name), dir, name)
	path := torrent.download(meta, dir) or {
		m.notice('torrent ${gid} failed: ${err.msg()}')
		m.set_error(gid, 1, err.msg())
		return
	}
	m.mu.lock()
	defer {
		m.mu.unlock()
	}
	if gid !in m.downloads {
		return
	}
	mut cur := m.downloads[gid]
	if cur.status != 'active' {
		return
	}
	cur.status = 'complete'
	cur.completed = cur.total
	cur.path = path
	cur.version++
	m.queue_version++
	m.downloads[gid] = cur
	m.notice('download complete: ${gid}')
}

fn (mut m Manager) add(uris []string, opts map[string]string) !string {
	m.mu.lock()
	if m.order.len >= max_downloads {
		m.mu.unlock()
		return error('queue full')
	}
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
	m.cancels[gid] = &transfer.Cancel{}
	m.started_at[gid] = i64(time.sys_mono_now())
	m.queue_version++
	m.mu.unlock()
	if m.auto_start {
		go m.run(gid)
	}
	return gid
}

fn (mut m Manager) run(gid string) {
	// Snapshot everything under one lock. Nothing below reads a Manager map
	// again, so concurrent option changes cannot race with this worker.
	mut uris := []string{}
	mut dir := ''
	mut out := ''
	mut conn_opt := ''
	mut min_opt := ''
	mut retry_opt := ''
	mut delay_opt := ''
	mut checksum_opt := ''
	mut cancel := &transfer.Cancel{}
	m.mu.lock()
	if gid in m.downloads {
		d := m.downloads[gid]
		uris = d.uris.clone()
		dir = d.options['dir']
		if dir == '' {
			dir = m.options['dir']
		}
		out = d.options['out']
		conn_opt = d.options['max-connection-per-server']
		min_opt = d.options['min-split-size']
		retry_opt = d.options['max-retries']
		if retry_opt == '' {
			retry_opt = m.options['max-retries']
		}
		delay_opt = d.options['retry-delay']
		if delay_opt == '' {
			delay_opt = m.options['retry-delay']
		}
		checksum_opt = d.options['checksum']
	}
	if gid in m.cancels {
		cancel = m.cancels[gid] or { &transfer.Cancel{} }
	}
	m.mu.unlock()
	if cancel.is_stopped() || uris.len == 0 {
		return
	}

	if out == '' {
		l := link.parse(uris[0]) or {
			m.set_error(gid, 1, err.msg())
			return
		}
		out = link.safe_name(l.name)
	}
	path := os.join_path(dir, out)

	// Mirror liveness: use the first source that answers a bounded probe.
	mut chosen := ''
	mut meta := transfer.Meta{}
	mut chosen_fetcher := m.fetcher
	for u in uris {
		if cancel.is_stopped() {
			return
		}
		candidate_fetcher := m.fetcher_for(u)
		probe := candidate_fetcher.head(u) or {
			m.notice('mirror down for ${gid}: ${err.msg()}')
			continue
		}
		chosen = u
		meta = probe
		chosen_fetcher = candidate_fetcher
		break
	}
	if chosen == '' {
		m.notice('no live mirror for ${gid}')
		if !cancel.is_stopped() {
			m.set_error(gid, 1, 'no live mirror')
		}
		return
	}
	m.set_started(gid, meta.length, path, dir, out)
	m.set_active_uri(gid, chosen)

	conn := util.int_or(conn_opt, 4)
	min_seg := util.i64_or(min_opt, 0)
	retries := util.int_or(retry_opt, 0)
	delay_ms := util.i64_or(delay_opt, 1000)
	opts := transfer.Options{
		connections: conn
		min_segment: min_seg
		cancel:      cancel
	}
	mut succeeded := false
	for attempt := 0; attempt <= retries; attempt++ {
		if cancel.is_stopped() {
			return
		}
		mut progress := &transfer.Progress{}
		transfer.download_with_meta(chosen, meta, meta.length, 0, path, opts, chosen_fetcher, mut progress) or {
			m.notice('attempt ${attempt + 1} for ${gid} failed: ${err.msg()}')
			if attempt == retries {
				if !cancel.is_stopped() {
					m.set_error(gid, 1, err.msg())
				}
				return
			}
			time.sleep(time.Duration(delay_ms * i64(attempt + 1)) * time.millisecond)
			continue
		}
		succeeded = true
		break
	}
	if !succeeded || cancel.is_stopped() {
		return
	}
	if checksum_opt != '' {
		valid := checksum.verify_file(path, checksum_opt) or {
			m.notice('checksum check failed for ${gid}: ${err.msg()}')
			false
		}
		if !valid {
			if !cancel.is_stopped() {
				m.set_error(gid, 4, 'checksum mismatch')
			}
			return
		}
	}

	m.mu.lock()
	defer {
		m.mu.unlock()
	}
	// A removed or paused row must never be resurrected or completed.
	if gid !in m.downloads {
		return
	}
	mut cur := m.downloads[gid]
	if cur.status != 'active' {
		return
	}
	cur.status = 'complete'
	cur.completed = cur.total
	cur.version++
	m.queue_version++
	m.downloads[gid] = cur
	m.notice('download complete: ${gid}')
}

fn (mut m Manager) set_active_uri(gid string, uri string) {
	m.mu.lock()
	defer {
		m.mu.unlock()
	}
	if gid !in m.downloads {
		return
	}
	mut d := m.downloads[gid]
	d.active_uri = uri
	d.version++
	m.queue_version++
	m.downloads[gid] = d
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
	m.started_at[gid] = i64(time.sys_mono_now())
	m.queue_version++
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
	m.queue_version++
	m.downloads[gid] = d
}
