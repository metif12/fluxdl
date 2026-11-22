// server.v - loopback HTTP JSON-RPC, the shape Fluxget talks to today.
module rpc

import fluxdl.util
import net.http

// Handler serves POST /jsonrpc and answers with a JSON-RPC envelope.
pub struct Handler {
pub:
	manager &Manager
}

// handle answers one HTTP request.
//
// Fluxget uses a leading `token:<secret>` argument on every call and sometimes
// also sends X-Rpc-Secret or ?token=. All three are accepted; a wrong header
// or query token is rejected before the payload is parsed.
pub fn (mut h Handler) handle(req http.Request) http.Response {
	mut res := http.Response{}
	res.status_code = 200
	res.header.set_custom('Content-Type', 'application/json') or {}
	if req.method != .post {
		res.status_code = 405
		res.body = '{"jsonrpc":"2.0","error":{"code":-32600,"message":"POST only"}}'
		return res
	}
	if h.manager.secret != '' {
		header_token := req.header.get_custom('X-Rpc-Secret') or { '' }
		query_token := url_token(req.url)
		if (header_token != '' && !util.secure_equal(header_token, h.manager.secret))
			|| (query_token != '' && !util.secure_equal(query_token, h.manager.secret)) {
			res.body = '{"jsonrpc":"2.0","error":{"code":-32000,"message":"Unauthorized"}}'
			return res
		}
	}
	res.body = h.manager.handle_payload(req.data)
	// A JSON-RPC notification has no id and receives no response at all.
	if res.body == '' {
		res.status_code = 204
	}
	return res
}

fn url_token(url string) string {
	q := url.index('?') or { return '' }
	for pair in url[q + 1..].split('&') {
		if pair.starts_with('token=') {
			return pair[6..]
		}
	}
	return ''
}

// serve blocks on addr with the given queue. Pass an addr bound to loopback,
// because the secret is a bearer token and this is not a public API.
pub fn serve(addr string, secret string, session_path string) {
	mut server := http.Server{
		addr:                 addr
		handler:              &Handler{ manager: new_manager(secret, session_path) }
		show_startup_message: false
	}
	server.listen_and_serve()
}
