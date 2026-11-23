// rpc.v - the aria2 JSON-RPC subset Fluxget already calls.
//
// The point of this module is the cut-over: same loopback HTTP shape, same
// method names, same string-valued numbers. Fluxget's contract test is the
// real definition of done; the tests here are the cheap checks that catch the
// four wire quirks recorded in docs/compat/fluxget.md before that test runs.
module rpc

import fluxdl.transfer
import fluxdl.transports
import os
import sync

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
	registry     &transports.Registry
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
		registry:     transports.new()
		status_cache: map[string]StatusCache{}
		row_lists:    map[string]RowsCache{}
		responses:    map[string]ResponseCache{}
		cancels:      map[string]&transfer.Cancel{}
		started_at:   map[string]i64{}
		auto_start:   true
	}
}
