module rpc

import fluxdl.session
import fluxdl.transfer
import fluxdl.util
import time

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

// fetcher_for asks the transport registry. The injected fetcher remains the
// fallback (tests inject a fake; HTTP uses the manager's shared instance).
fn (m &Manager) fetcher_for(url string) &transfer.Fetcher {
	return m.registry.fetcher_for(url) or { m.fetcher }
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
