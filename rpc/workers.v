module rpc

import fluxdl.checksum
import fluxdl.link
import fluxdl.torrent
import fluxdl.transfer
import fluxdl.util
import os
import time

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
