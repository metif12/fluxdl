module rpc

import aria2v.internal.plan
import aria2v.internal.session
import aria2v.internal.transfer
import json2
import os

// A fetcher that never opens a socket. It lets the RPC tests assert the wire
// shape instead of waiting for a download, which is the whole division of
// labour between this module and internal/transfer.
struct TestFetcher {}

pub fn (f TestFetcher) head(url string) !transfer.Meta {
	return transfer.Meta{ length: 1024, ranges: true }
}

pub fn (f TestFetcher) fetch(url string, seg plan.Segment, path string) !i64 {
	return seg.len()
}

fn new_test_manager(secret string) &Manager {
	dir := os.join_path(os.temp_dir(), 'aria2v-rpc-test')
	os.mkdir_all(dir) or {}
	p := os.join_path(dir, 'test.session')
	os.rm(p) or {}
	mut m := new_manager(secret, p)
	m.auto_start = false
	m.fetcher = &TestFetcher{}
	m.options['dir'] = dir
	return m
}

fn payload(raw string) json2.Any {
	return json2.decode[json2.Any](raw) or { json2.Any('') }
}

fn result_of(raw string) json2.Any {
	obj := any_map(payload(raw))
	return field(obj, 'result')
}

fn error_of(raw string) json2.Any {
	obj := any_map(payload(raw))
	return field(obj, 'error')
}

fn test_add_uri_returns_a_sixteen_character_gid() {
	mut m := new_test_manager('')
	raw := m.handle_payload('{"jsonrpc":"2.0","id":1,"method":"aria2.addUri","params":[["https://a/f.bin"]]}')
	gid := any_str(result_of(raw))
	assert gid.len == 16, 'gid is ${gid}'
	assert m.downloads[gid].status == 'waiting', m.downloads[gid].status
}

fn test_numeric_fields_are_strings_on_the_wire() {
	mut m := new_test_manager('')
	raw := m.handle_payload('{"jsonrpc":"2.0","id":1,"method":"aria2.addUri","params":[["https://a/f.bin"]]}')
	gid := any_str(result_of(raw))
	m.set_started(gid, 1024, 'f.bin', 'D:/x', 'f.bin')
	status_raw := m.handle_payload('{"jsonrpc":"2.0","id":2,"method":"aria2.tellStatus","params":["${gid}"]}')
	status := any_map(result_of(status_raw))
	match field(status, 'totalLength') {
		string {
			assert any_str(field(status, 'totalLength')) == '1024', 'totalLength must be a string'
		}
		else {
			assert false, 'totalLength was not a string'
		}
	}
	assert any_str(field(status, 'gid')) == gid, 'gid round trip'
}

fn test_a_wrong_token_is_rejected() {
	mut m := new_test_manager('s3cret')
	raw := m.handle_payload('{"jsonrpc":"2.0","id":1,"method":"aria2.addUri","params":[["https://a/f.bin"]]}')
	err := any_map(error_of(raw))
	assert any_str(field(err, 'message')) == 'Unauthorized', 'wrong token must be rejected'
}

fn test_a_right_token_is_stripped_before_dispatch() {
	mut m := new_test_manager('s3cret')
	raw := m.handle_payload('{"jsonrpc":"2.0","id":1,"method":"aria2.addUri","params":["token:s3cret",["https://a/f.bin"]]}')
	gid := any_str(result_of(raw))
	assert gid.len == 16, 'the token must not become a URI: ${raw}'
	assert m.downloads[gid].uri == 'https://a/f.bin', m.downloads[gid].uri
}

fn test_multicall_wraps_each_result_in_an_array() {
	mut m := new_test_manager('s3cret')
	raw := m.handle_payload('{"jsonrpc":"2.0","id":1,"method":"system.multicall","params":["token:s3cret",[{"methodName":"aria2.getVersion","params":[]},{"methodName":"aria2.tellActive","params":[]}]]}')
	rows := any_arr(result_of(raw))
	assert rows.len == 2, 'two calls in, two results out: ${raw}'
	first := any_arr(rows[0])
	assert first.len == 1, 'a successful multicall result is a one-element array'
	version_obj := any_map(first[0])
	assert any_str(field(version_obj, 'version')).starts_with('1.37.0-'), any_str(field(version_obj, 'version'))
}

fn test_a_failed_download_reports_error_code_and_message_not_error() {
	mut m := new_test_manager('')
	raw := m.handle_payload('{"jsonrpc":"2.0","id":1,"method":"aria2.addUri","params":[["https://a/f.bin"]]}')
	gid := any_str(result_of(raw))
	m.set_error(gid, 7, 'disk full')
	status_raw := m.handle_payload('{"jsonrpc":"2.0","id":2,"method":"aria2.tellStatus","params":["${gid}"]}')
	status := any_map(result_of(status_raw))
	assert any_str(field(status, 'errorCode')) == '7', any_str(field(status, 'errorCode'))
	assert any_str(field(status, 'errorMessage')) == 'disk full', any_str(field(status, 'errorMessage'))
	assert 'error' in status == false, 'aria2 never sends an `error` field in tellStatus'
}

fn test_save_session_writes_aria2_format() {
	mut m := new_test_manager('')
	raw := m.handle_payload('{"jsonrpc":"2.0","id":1,"method":"aria2.addUri","params":[["https://a/f.bin"]]}')
	assert any_str(result_of(raw)).len == 16, raw
	saved := m.handle_payload('{"jsonrpc":"2.0","id":2,"method":"aria2.saveSession","params":[]}')
	assert any_str(result_of(saved)) == 'OK', saved
	entries, skipped := session.load(m.session_path)
	assert skipped == 0, '${skipped}'
	assert entries.len == 1, '${entries.len}'
	assert entries[0].uri == 'https://a/f.bin', entries[0].uri
}

fn test_unknown_method_is_a_json_rpc_error() {
	mut m := new_test_manager('')
	raw := m.handle_payload('{"jsonrpc":"2.0","id":9,"method":"aria2.notAMethod","params":[]}')
	err := any_map(error_of(raw))
	assert any_num_str(field(err, 'code')) == '-32601', '${raw}'
}

// The status cache is the hot path. These assertions would all fail if a
// mutation forgot to bump the version: the poll would keep answering the
// previously cached bytes.
fn test_the_status_cache_invalidates_on_every_state_change() {
	mut m := new_test_manager('')
	added := m.handle_payload('{"jsonrpc":"2.0","id":1,"method":"aria2.addUri","params":[["https://a/f.bin"]]}')
	gid := any_str(result_of(added))

	mut active := m.handle_payload('{"jsonrpc":"2.0","id":2,"method":"aria2.tellActive","params":[]}')
	assert any_arr(result_of(active)).len == 0, 'a waiting download is not active'

	m.set_started(gid, 1024, 'f.bin', 'D:/x', 'f.bin')
	active = m.handle_payload('{"jsonrpc":"2.0","id":3,"method":"aria2.tellActive","params":[]}')
	assert any_arr(result_of(active)).len == 1, 'set_started must invalidate the cache'

	paused := m.handle_payload('{"jsonrpc":"2.0","id":4,"method":"aria2.pause","params":["${gid}"]}')
	assert any_str(result_of(paused)) == gid, paused
	active = m.handle_payload('{"jsonrpc":"2.0","id":5,"method":"aria2.tellActive","params":[]}')
	assert any_arr(result_of(active)).len == 0, 'pause must invalidate the cache'
}
