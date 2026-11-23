// transports - the one place where URL schemes map to transfer.Fetcher
// implementations. Adding a transport means registering a factory here; CLI
// and RPC both ask the registry, so there is no second registration site.
module transports

import fluxdl.ftp
import fluxdl.sftp
import fluxdl.transfer

pub type Factory = fn () &transfer.Fetcher

pub struct Registry {
mut:
	factories map[string]Factory
}

// new returns a registry with the built-in HTTP, FTP and SFTP transports.
pub fn new() &Registry {
	mut registry := &Registry{ factories: map[string]Factory{} }
	registry.register('http', fn () &transfer.Fetcher {
		return transfer.new_http_fetcher()
	})
	registry.register('https', fn () &transfer.Fetcher {
		return transfer.new_http_fetcher()
	})
	registry.register('ftp', fn () &transfer.Fetcher {
		return ftp.new_fetcher()
	})
	registry.register('sftp', fn () &transfer.Fetcher {
		return sftp.new_fetcher()
	})
	return registry
}

// register adds or replaces the factory for a URL scheme.
pub fn (mut r Registry) register(scheme string, factory Factory) {
	r.factories[scheme] = factory
}

// fetcher_for returns a fresh fetcher for the URL's scheme, or none when no
// transport claims it. A fresh fetcher matters: FTP/SFTP keep a per-URL body
// cache, so sharing one across downloads would be wrong.
pub fn (r &Registry) fetcher_for(url string) ?&transfer.Fetcher {
	colon := url.index('://') or { return none }
	scheme := url[..colon]
	if scheme in r.factories {
		return r.factories[scheme]()
	}
	return none
}
