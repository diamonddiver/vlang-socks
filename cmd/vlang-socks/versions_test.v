module main

import socks

fn test_parse_versions_all() {
	v := parse_versions('4,4a,5') or { panic(err) }
	assert v == [socks.SocksVersion.v4, .v4a, .v5]
}

fn test_parse_versions_subset() {
	v := parse_versions('5') or { panic(err) }
	assert v == [socks.SocksVersion.v5]
}

fn test_parse_versions_whitespace() {
	v := parse_versions(' 4 , 5 ') or { panic(err) }
	assert v == [socks.SocksVersion.v4, .v5]
}

fn test_parse_versions_unknown() {
	parse_versions('4,6') or { return }
	assert false
}

fn test_parse_versions_empty() {
	parse_versions('') or { return }
	assert false
}
