// main.v - the fluxdl CLI.
//
// Two kinds of command live here. `plan`, `session` and `suggest` are pure and
// exist to make the engine's arithmetic inspectable without a network.
// `download` and `serve` are the real engine, and are thin calls into
// transfer and rpc - a CLI that also holds logic is a CLI
// that cannot be tested by vlib's test runner.
module main

import os
import fluxdl.ftp
import fluxdl.link
import fluxdl.metalink
import fluxdl.plan
import fluxdl.rpc
import fluxdl.sftp
import fluxdl.torrent
import fluxdl.session
import fluxdl.transfer
import fluxdl.util

fn usage() {
	print('fluxdl ${rpc.version} - a download engine in pure V

  fluxdl plan <url> <bytes> [connections] [min-segment]
      Print the byte ranges a download of <bytes> would fetch.

  fluxdl session <path>
      Read a session file and print what came back, and how many lines were
      lost to corruption.

  fluxdl suggest <url>
      Print the folder a URL implies.

  fluxdl download <url> [-d dir] [-o name] [-x connections] [--min-segment bytes]
      Fetch a URL with N ranges, writing one file. Resumes from the bytes
      already on disk.

  fluxdl torrent <path> [-d dir]
      Download a .torrent over HTTP trackers and the peer wire protocol.

  fluxdl seed <path> [-d dir] [-p port]
      Serve a completed torrent to inbound peers.

  fluxdl metalink <path>
      Print the files, URLs and hashes a Metalink document declares.

  fluxdl serve [--addr 127.0.0.1:9009] [--secret token] [--session path]
      Run the loopback JSON-RPC server that Fluxget talks to.

  fluxdl --version
')
}

fn main() {
	args := os.args
	if args.len < 2 {
		usage()
		exit(1)
	}
	if args[1] == '--version' || args[1] == '-V' {
		println(rpc.version)
		return
	}
	match args[1] {
		'plan' { cmd_plan(args[2..]) }
		'session' { cmd_session(args[2..]) }
		'suggest' { cmd_suggest(args[2..]) }
		'download' { cmd_download(args[2..]) }
		'metalink' { cmd_metalink(args[2..]) }
		'torrent' { cmd_torrent(args[2..]) }
		'seed' { cmd_seed(args[2..]) }
		'serve' { cmd_serve(args[2..]) }
		else {
			usage()
			exit(1)
		}
	}
}

fn cmd_plan(args []string) {
	if args.len < 2 {
		eprintln('plan needs a url and a byte count')
		exit(1)
	}
	url := args[0]
	length := util.i64_or(args[1], 0)
	connections := if args.len > 2 { util.int_or(args[2], 4) } else { 4 }
	min_segment := if args.len > 3 { util.i64_or(args[3], 0) } else { 0 }

	l := link.parse(url) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	println('url:      ${l.raw}')
	println('name:     ${link.safe_name(l.name)}')
	if l.folder != '' {
		println('folder:   ${l.folder} (suggested)')
	}

	for done in [i64(0), length / 2] {
		segs := plan.resume_plan(length, connections, min_segment, done)
		if segs.len == 0 {
			continue
		}
		println('\n${if done == 0 { 'fresh' } else { 'resuming from ' + done.str() + ' bytes' }}: ' +
			'${plan.total_len(segs)} bytes in ${segs.len} segment(s)')
		for s in segs {
			println('  [${s.index}] rows ${s.first}-${s.last}  ${s.len()} bytes  ${s.range_header()}')
		}
	}
}

fn cmd_session(args []string) {
	if args.len < 1 {
		eprintln('session needs a path')
		exit(1)
	}
	entries, skipped := session.load(args[0])
	println('${entries.len} download(s) came back')
	if skipped > 0 {
		// The number that makes a corrupt file trustworthy instead of scary: a
		// report of what was lost, rather than silence that hides it.
		println('${skipped} line(s) were lost to corruption')
	}
	for e in entries {
		println('  ${e.uri}')
	}
}

fn cmd_suggest(args []string) {
	if args.len < 1 {
		eprintln('suggest needs a url')
		exit(1)
	}
	s := link.suggest(args[0])
	println(if s == '' { 'nothing to suggest from that address' } else { s })
}

// cmd_download is the engine without the daemon: one URL, one file, N ranges.
// It is the same path `fluxdl serve` takes, minus the JSON-RPC envelope.
fn cmd_download(args []string) {
	mut url := ''
	mut dir := os.getenv('FLUXDL_DIR')
	if dir == '' {
		dir = os.getwd()
	}
	mut out := ''
	mut connections := 4
	mut min_segment := i64(0)
	mut i := 0
	for i < args.len {
		a := args[i]
		match a {
			'-d' {
				i++
				if i < args.len {
					dir = args[i]
				}
			}
			'-o' {
				i++
				if i < args.len {
					out = args[i]
				}
			}
			'-x' {
				i++
				if i < args.len {
					connections = util.int_or(args[i], 4)
				}
			}
			'--min-segment' {
				i++
				if i < args.len {
					min_segment = util.i64_or(args[i], 0)
				}
			}
			else {
				if url == '' {
					url = a
				}
			}
		}
		i++
	}
	if url == '' {
		eprintln('download needs a url')
		exit(1)
	}

	l := link.parse(url) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	if out == '' {
		out = link.safe_name(l.name)
	}
	path := os.join_path(dir, out)

	fetcher := if url.starts_with('ftp://') {
		&transfer.Fetcher(ftp.new_fetcher())
	} else if url.starts_with('sftp://') {
		&transfer.Fetcher(sftp.new_fetcher())
	} else {
		&transfer.Fetcher(transfer.new_http_fetcher())
	}
	meta := fetcher.head(url) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	done := if os.exists(path) { os.file_size(path) } else { i64(0) }
	if done >= meta.length {
		println('${path}: already complete (${done} bytes)')
		return
	}
	mut progress := &transfer.Progress{}
	n := transfer.download_with_meta(url, meta, meta.length, done, path, transfer.Options{
		connections: connections
		min_segment: min_segment
	}, fetcher, mut progress) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	println('${path}: ${progress.value} of ${meta.length} bytes (${n} fetched this run)')
}

fn cmd_seed(args []string) {
	if args.len < 1 {
		eprintln('seed needs a .torrent path')
		exit(1)
	}
	mut dir := os.getenv('FLUXDL_DIR')
	if dir == '' {
		dir = os.getwd()
	}
	mut port := 6881
	mut i := 1
	for i < args.len {
		if args[i] == '-d' && i + 1 < args.len {
			i++
			dir = args[i]
		} else if args[i] == '-p' && i + 1 < args.len {
			i++
			port = args[i].int()
		}
		i++
	}
	raw := os.read_file(args[0]) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	meta := torrent.parse(raw.bytes()) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	println('seeding ${meta.name} on ${port}')
	torrent.seed(meta, dir, port) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
}

fn cmd_torrent(args []string) {
	if args.len < 1 {
		eprintln('torrent needs a .torrent path')
		exit(1)
	}
	mut dir := os.getenv('FLUXDL_DIR')
	if dir == '' {
		dir = os.getwd()
	}
	if args.len > 2 && args[1] == '-d' {
		dir = args[2]
	}
	raw := os.read_file(args[0]) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	meta := torrent.parse(raw.bytes()) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	path := torrent.download(meta, dir) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	println(path)
}

fn cmd_metalink(args []string) {
	if args.len < 1 {
		eprintln('metalink needs a path')
		exit(1)
	}
	raw := os.read_file(args[0]) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	files := metalink.parse(raw) or {
		eprintln('fluxdl: ${err.msg()}')
		exit(1)
	}
	for file in files {
		println('${file.name}: ${file.urls.len} source(s)')
		for url in file.urls {
			println('  ${url}')
		}
		for algo, digest in file.hashes {
			println('  ${algo}: ${digest}')
		}
	}
}

fn cmd_serve(args []string) {
	mut addr := '127.0.0.1:9009'
	mut secret := os.getenv('FLUXDL_SECRET')
	mut session_path := os.getenv('FLUXDL_SESSION')
	if session_path == '' {
		// A user-owned directory, not the shared temp folder: another account
		// must not be able to plant the session file this daemon trusts.
		session_path = os.join_path(os.home_dir(), '.fluxdl', 'session')
	}
	mut i := 0
	for i < args.len {
		a := args[i]
		match a {
			'--addr' {
				i++
				if i < args.len {
					addr = args[i]
				}
			}
			'--secret' {
				i++
				if i < args.len {
					secret = args[i]
				}
			}
			'--session' {
				i++
				if i < args.len {
					session_path = args[i]
				}
			}
			else {
				eprintln('fluxdl: unknown serve option ${a}')
				exit(1)
			}
		}
		i++
	}
	println('fluxdl ${rpc.version} listening on ${addr} (JSON-RPC POST /jsonrpc)')
	rpc.serve(addr, secret, session_path)
}
