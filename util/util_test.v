module util

fn test_all_digits_rejects_trailing_garbage() {
	assert all_digits('1048576'), 'plain decimal is valid'
	assert !all_digits('1048576junk'), 'a parseable prefix is not validation'
	assert !all_digits(''), 'empty string is not a number'
	assert !all_digits('-1'), 'a sign is not digits'
}

fn test_int_and_i64_or_fall_back_on_garbage() {
	assert int_or('8', 4) == 8, 'valid decimal parses'
	assert int_or('8x', 4) == 4, 'trailing garbage uses the default'
	assert i64_or('1048576', 0) == 1048576, 'valid decimal parses'
	assert i64_or('', 7) == 7, 'empty uses the default'
}

fn test_decode_hex_pair_handles_letters() {
	assert decode_hex_pair('C3') or { 0 } == u8(0xc3), 'uppercase hex'
	assert decode_hex_pair('ab') or { 0 } == u8(0xab), 'lowercase hex'
	assert decode_hex_pair('7f') or { 0 } == u8(0x7f), 'digits'
	assert decode_hex_pair('zz') or { 255 } == u8(255), 'invalid pair'
}

fn test_secure_equal_loops_over_both_strings() {
	assert secure_equal('secret', 'secret'), 'equal secrets match'
	assert !secure_equal('secret', 'secrex'), 'different secrets do not match'
	assert !secure_equal('secret', 'sec'), 'a prefix is not equal'
	assert secure_equal('', ''), 'two empty secrets match'
}
