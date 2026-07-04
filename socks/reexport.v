module socks

import socks.core

// Re-export the error types so users only ever import `socks`.
pub type SocksError = core.SocksError
pub type SocksErrorCode = core.SocksErrorCode

pub enum SocksVersion {
	v4
	v4a
	v5
}

pub enum ResolveMode {
	server_side // default: proxy resolves domain names
	client_side // dialer resolves locally before sending an IP
}

pub struct NoAuth {}

pub struct UserPassAuth {
pub:
	user string
	pass string
}

pub type Auth = NoAuth | UserPassAuth

pub fn no_auth() Auth {
	return NoAuth{}
}

pub fn user_pass_auth(user string, pass string) Auth {
	return UserPassAuth{
		user: user
		pass: pass
	}
}

pub struct ServerConfig {
pub mut:
	addr             string         = ':1080'
	auth             Auth           = no_auth()
	allow_udp        bool           = true
	resolve_mode     ResolveMode    = .server_side
	versions         []SocksVersion = [.v4, .v4a, .v5]
	resolver_threads int            = 8
	log_connections  bool // default false; the CLI enables it
}

pub struct ClientConfig {
pub mut:
	proxy_addr   string
	version      SocksVersion = .v5
	auth         Auth         = no_auth()
	resolve_mode ResolveMode  = .server_side
}

// validate_server_config returns a plain error (not a SocksError) for
// misconfiguration caught at startup.
fn validate_server_config(cfg ServerConfig) ! {
	if cfg.versions.len == 0 {
		return error('socks: at least one SOCKS version must be enabled')
	}
	if SocksVersion.v4a in cfg.versions && SocksVersion.v4 !in cfg.versions {
		return error('socks: .v4a requires .v4 to be enabled')
	}
}
