// A small consumer of the fluxdl package.
//
// Run from the repo root with the package on the module path:
//   v run examples/library.v
//
// A project that installed the package with vpm would import
// `metif12.fluxdl.plan` and `metif12.fluxdl.link` instead.
module main

import fluxdl.link
import fluxdl.plan

fn main() {
	url := 'https://example.com/archive.bin?token=abc'

	// Pure text: the name a download would get, and the folder it implies.
	parsed := link.parse(url) or {
		eprintln('bad address: ${err.msg()}')
		return
	}
	println('name:   ${link.safe_name(parsed.name)}')
	println('folder: ${link.suggest(url)}')

	// Pure arithmetic: the ranges a four-connection download would fetch.
	segments := plan.plan(1048576, 4, 0)
	println('${segments.len} segment(s):')
	for segment in segments {
		println('  ${segment.range_header()} (${segment.len()} bytes)')
	}
}
