// metalink.v - the useful subset of a Metalink 4 document: files, their URLs
// and their hashes. A Metalink is untrusted input, so unknown elements are
// ignored and empty fields are skipped rather than trusted as filenames.
module metalink

import encoding.xml

pub struct MetalinkFile {
pub mut:
	name   string
	urls   []string
	hashes map[string]string
}

// parse returns the files declared in a Metalink document.
pub fn parse(raw string) ![]MetalinkFile {
	doc := xml.XMLDocument.from_string(raw)!
	mut out := []MetalinkFile{}
	for top in doc.root.children {
		if top is xml.XMLNode && top.name == 'files' {
			for item in top.children {
				if item is xml.XMLNode && item.name == 'file' {
					entry := parse_file(item)
					if entry.name != '' && entry.urls.len > 0 {
						out << entry
					}
				}
			}
		}
	}
	return out
}

fn parse_file(node xml.XMLNode) MetalinkFile {
	mut file := MetalinkFile{
		name:   node.attributes['name'] or { '' }
		urls:   []
		hashes: map[string]string{}
	}
	for item in node.children {
		if item is xml.XMLNode {
			match item.name {
				'url' {
					u := text_of(item)
					if u != '' {
						file.urls << u
					}
				}
				'hash' {
					algo := item.attributes['type'] or { 'sha256' }
					file.hashes[algo] = text_of(item)
				}
				else {}
			}
		}
	}
	return file
}

fn text_of(node xml.XMLNode) string {
	mut text := ''
	for part in node.children {
		match part {
			string {
				text += part
			}
			else {}
		}
	}
	return text.trim_space()
}
