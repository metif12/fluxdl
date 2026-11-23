module rpc

import json2
import strings

fn field(obj map[string]json2.Any, key string) json2.Any {
	if key in obj {
		return obj[key] or { json2.Any(json2.Null{}) }
	}
	return json2.Any(json2.Null{})
}

fn any_str(v json2.Any) string {
	match v {
		string {
			return v
		}
		else {
			return ''
		}
	}
}

pub fn any_num_str(v json2.Any) string {
	match v {
		string {
			return v
		}
		int {
			return v.str()
		}
		i64 {
			return v.str()
		}
		u64 {
			return v.str()
		}
		f64 {
			// json2 decodes every JSON number as f64 first, so an integer
			// JSON-RPC code comes back as -32601.0. Print it as an integer.
			return int(v).str()
		}
		else {
			return ''
		}
	}
}

fn any_map(v json2.Any) map[string]json2.Any {
	match v {
		map[string]json2.Any {
			return v
		}
		else {
			return map[string]json2.Any{}
		}
	}
}

fn any_arr(v json2.Any) []json2.Any {
	match v {
		[]json2.Any {
			return v
		}
		else {
			return []json2.Any{}
		}
	}
}

fn any_strings(v json2.Any) []string {
	match v {
		string {
			return [v]
		}
		[]json2.Any {
			mut out := []string{}
			for item in v {
				out << any_str(item)
			}
			return out
		}
		else {
			return []string{}
		}
	}
}

fn string_map(v json2.Any) map[string]string {
	mut out := map[string]string{}
	for k, val in any_map(v) {
		out[k] = any_str(val)
	}
	return out
}

fn any_map_of_strings(m map[string]string) json2.Any {
	mut out := map[string]json2.Any{}
	for k, v in m {
		out[k] = v
	}
	return json2.Any(out)
}

// ok wraps an already-encoded result. The hot methods build their result
// directly instead of allocating an Any tree for json2 to walk again.
fn ok(id json2.Any, result_json string) string {
	mut sb := strings.new_builder(result_json.len + 64)
	sb.write_string('{"jsonrpc":"2.0","id":')
	sb.write_string(json2.encode(id))
	sb.write_string(',"result":')
	sb.write_string(result_json)
	sb.write_string('}')
	res := sb.str()
	unsafe {
		sb.free()
	}
	return res
}

fn fail(id json2.Any, code int, msg string) string {
	err_obj := map[string]json2.Any{
		'code':    code
		'message': msg
	}
	res := map[string]json2.Any{
		'jsonrpc': '2.0'
		'id':      id
		'error':   err_obj
	}
	return json2.encode(res)
}

fn null_id() json2.Any {
	return json2.Any(json2.Null{})
}

fn field_from(arr []json2.Any, i int) json2.Any {
	if i < arr.len {
		return arr[i]
	}
	return json2.Any(json2.Null{})
}
