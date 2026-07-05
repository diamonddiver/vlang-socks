module main

import os
import flag
import socks

// parse_versions maps a comma-separated list like "4,4a,5" to []SocksVersion.
fn parse_versions(s string) ![]socks.SocksVersion {
	mut out := []socks.SocksVersion{}
	for part in s.split(',') {
		p := part.trim_space()
		match p {
			'4' { out << .v4 }
			'4a' { out << .v4a }
			'5' { out << .v5 }
			'' {}
			else { return error('unknown SOCKS version "${p}"') }
		}
	}
	if out.len == 0 {
		return error('no SOCKS versions specified')
	}
	return out
}

fn main() {
	// Docker's default `docker run -d` (detached, non-TTY) gives the process
	// a pipe for stdout, which glibc fully-buffers rather than line-buffers.
	// Without this, neither the startup line nor any log_connections output
	// reaches `docker logs` promptly — only once the buffer fills or the
	// process exits. Force unbuffered stdout so logs are visible in real time.
	C.setvbuf(C.stdout, unsafe { nil }, C._IONBF, 0)

	mut fp := flag.new_flag_parser(os.args)
	fp.application('vlang-socks')
	fp.description('A minimal SOCKS4/4a/5 proxy server.')
	fp.skip_executable()
	addr := fp.string('addr', 0, ':1080', 'listen address (default :1080)')
	user := fp.string('user', 0, '', 'username for user/pass auth')
	pass := fp.string('pass', 0, '', 'password for user/pass auth')
	no_udp := fp.bool('no-udp', 0, false, 'disable UDP ASSOCIATE')
	versions_s := fp.string('versions', 0, '4,4a,5', 'comma-separated subset of 4,4a,5')
	rest := fp.finalize() or {
		eprintln(err.msg())
		println(fp.usage())
		exit(1)
	}
	if rest.len == 0 || rest[0] != 'serve' {
		println(fp.usage())
		exit(1)
	}
	versions := parse_versions(versions_s) or {
		eprintln('error: ${err.msg()}')
		exit(1)
	}
	mut auth := socks.no_auth()
	if user != '' || pass != '' {
		if user == '' || pass == '' {
			eprintln('error: --user and --pass must both be set to enable user/pass auth')
			exit(1)
		}
		auth = socks.user_pass_auth(user, pass)
	}
	cfg := socks.ServerConfig{
		addr:            addr
		auth:            auth
		allow_udp:       !no_udp
		versions:        versions
		log_connections: true
	}
	mut h := socks.spawn_serve(cfg) or {
		eprintln('error: ${err.msg()}')
		exit(1)
	}
	println('vlang-socks listening on ${h.addr()}')
	h.wait()
}
