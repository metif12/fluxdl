module rpc

// MethodSpec is the metadata for one JSON-RPC method. The list below is the
// single source for listMethods and the read-only response cache, so adding a
// method only needs a dispatch arm in wire.v and one row here.
struct MethodSpec {
	name      string
	read_only bool
}

fn method_specs() []MethodSpec {
	return [
		MethodSpec{ name: 'aria2.addUri' },
		MethodSpec{ name: 'aria2.addTorrent' },
		MethodSpec{ name: 'aria2.addMagnet' },
		MethodSpec{ name: 'aria2.tellStatus', read_only: true },
		MethodSpec{ name: 'aria2.tellActive', read_only: true },
		MethodSpec{ name: 'aria2.tellWaiting', read_only: true },
		MethodSpec{ name: 'aria2.tellStopped', read_only: true },
		MethodSpec{ name: 'aria2.pause' },
		MethodSpec{ name: 'aria2.unpause' },
		MethodSpec{ name: 'aria2.pauseAll' },
		MethodSpec{ name: 'aria2.unpauseAll' },
		MethodSpec{ name: 'aria2.remove' },
		MethodSpec{ name: 'aria2.removeDownloadResult' },
		MethodSpec{ name: 'aria2.getFiles', read_only: true },
		MethodSpec{ name: 'aria2.getServers', read_only: true },
		MethodSpec{ name: 'aria2.getUris', read_only: true },
		MethodSpec{ name: 'aria2.getOption', read_only: true },
		MethodSpec{ name: 'aria2.changeOption' },
		MethodSpec{ name: 'aria2.getPeers', read_only: true },
		MethodSpec{ name: 'aria2.getGlobalStat', read_only: true },
		MethodSpec{ name: 'aria2.getVersion', read_only: true },
		MethodSpec{ name: 'aria2.getGlobalOption', read_only: true },
		MethodSpec{ name: 'aria2.changeGlobalOption' },
		MethodSpec{ name: 'aria2.saveSession' },
		MethodSpec{ name: 'aria2.shutdown' },
		MethodSpec{ name: 'aria2.addMetalink' },
		MethodSpec{ name: 'aria2.getNotices' },
		MethodSpec{ name: 'system.multicall' },
		MethodSpec{ name: 'system.listMethods', read_only: true },
	]
}

fn method_names() []string {
	mut out := []string{}
	for spec in method_specs() {
		out << spec.name
	}
	return out
}

fn readonly_method(method string) bool {
	for spec in method_specs() {
		if spec.name == method {
			return spec.read_only
		}
	}
	return false
}
