module core

fn test_rep_roundtrip_all_remote_codes() {
	remote := [
		SocksErrorCode.general_failure,
		.connection_not_allowed,
		.network_unreachable,
		.host_unreachable,
		.connection_refused,
		.ttl_expired,
		.command_not_supported,
		.address_type_not_supported,
	]
	for k in remote {
		assert code_from_rep(rep_code(k)) == k
	}
}

fn test_rep_specific_bytes() {
	assert rep_code(.host_unreachable) == 0x04
	assert rep_code(.ttl_expired) == 0x06
	assert rep_code(.address_type_not_supported) == 0x08
	assert code_from_rep(0x05) == .connection_refused
	// Unknown REP byte collapses to general_failure.
	assert code_from_rep(0x7f) == .general_failure
}

fn test_cd_collapse() {
	assert cd_code(.host_unreachable) == 91
	assert cd_code(.command_not_supported) == 91
	assert cd_granted == 90
	assert code_from_cd(91) == .general_failure
	assert code_from_cd(92) == .general_failure
}
