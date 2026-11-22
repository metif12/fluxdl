// util.v - small shared validators used by the CLI, RPC and HTTP layers.
//
// Keeping one implementation of "is this string really a number" matters:
// V's String.int()/i64() stop at the first non-digit, so a successful parse is
// not validation. Every untrusted numeric input goes through these helpers.
module util

// all_digits reports whether s is a non-empty string of ASCII digits.
pub fn all_digits(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

// int_or parses a decimal int, returning default_value when s is not digits.
pub fn int_or(s string, default_value int) int {
	if !all_digits(s) {
		return default_value
	}
	return s.int()
}

// i64_or parses a decimal i64, returning default_value when s is not digits.
pub fn i64_or(s string, default_value i64) i64 {
	if !all_digits(s) {
		return default_value
	}
	return s.i64()
}

// secure_equal compares two secrets without stopping at the first difference.
// The loop length depends only on the public lengths, not on the contents.
pub fn secure_equal(a string, b string) bool {
	mut diff := a.len ^ b.len
	n := if a.len > b.len { a.len } else { b.len }
	for i := 0; i < n; i++ {
		x := if i < a.len { a[i] } else { u8(0) }
		y := if i < b.len { b[i] } else { u8(0) }
		diff |= int(x ^ y)
	}
	return diff == 0
}
