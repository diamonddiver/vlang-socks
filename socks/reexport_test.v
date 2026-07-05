module socks

import time
import socks.core

fn test_default_server_config() {
	cfg := ServerConfig{}
	assert cfg.addr == ':1080'
	assert cfg.allow_udp
	assert cfg.versions == [SocksVersion.v4, .v4a, .v5]
	assert cfg.resolver_threads == 8
	assert cfg.resolve_mode == .server_side
	assert cfg.idle_timeout == 0
	assert cfg.connect_timeout == 30 * time.second
	match cfg.auth {
		NoAuth {}
		else { assert false }
	}
}

fn test_user_pass_auth_helper() {
	a := user_pass_auth('bob', 'pw')
	match a {
		UserPassAuth {
			assert a.user == 'bob'
			assert a.pass == 'pw'
		}
		else {
			assert false
		}
	}
}

fn test_default_client_config() {
	cfg := ClientConfig{
		proxy_addr: '127.0.0.1:1080'
	}
	assert cfg.version == .v5
	assert cfg.resolve_mode == .server_side
}

fn test_validate_rejects_4a_without_4() {
	cfg := ServerConfig{
		versions: [SocksVersion.v4a, .v5]
	}
	validate_server_config(cfg) or {
		assert err.msg().contains('.v4a requires .v4')
		return
	}
	assert false
}

fn test_validate_rejects_empty_versions() {
	cfg := ServerConfig{
		versions: []
	}
	validate_server_config(cfg) or { return }
	assert false
}

fn test_validate_accepts_defaults() {
	validate_server_config(ServerConfig{})!
}

fn returns_socks_err() ! {
	return core.err(.host_unreachable, 'boom')
}

fn test_socks_error_castable_from_ierror() {
	returns_socks_err() or {
		se := err as core.SocksError
		assert se.kind == .host_unreachable
		assert se.msg() == 'boom'
		return
	}
	assert false
}
