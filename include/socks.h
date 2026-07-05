/* socks.h - C ABI for libsocks: a SOCKS4/4a/5 client and server library.
 *
 * socks_init() MUST be called exactly once, before any other socks_*
 * function, by every process that links this library (it starts the
 * garbage collector; see its own comment below for why this can't happen
 * automatically on dlopen).
 *
 * Handles (uint64_t) are opaque registry ids: 0 always means "no handle" /
 * failure. On any failure, call socks_last_error_code()/
 * socks_last_error_message() before making another socks_* call (they
 * report the single most recent error, like errno/strerror).
 */
#ifndef SOCKS_H
#define SOCKS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* auth_mode values (socks_server_start, socks_dial, socks_udp_associate). */
#define SOCKS_AUTH_NONE 0
#define SOCKS_AUTH_USERPASS 1

/* SOCKS version constants. Used as a bitmask in socks_server_start's
 * versions_mask (bit0=v4, bit1=v4a, bit2=v5, OR the ones you want together),
 * and as a single scalar value in socks_dial's version argument (exactly
 * one of these, not OR'd). */
#define SOCKS_V4 1
#define SOCKS_V4A 2
#define SOCKS_V5 4

/* resolve_mode values (socks_dial, socks_udp_associate). */
#define SOCKS_RESOLVE_SERVER_SIDE 0
#define SOCKS_RESOLVE_CLIENT_SIDE 1

/* socks_init starts the Boehm GC this library is built with. The shared
 * library's own constructor runs automatically on dlopen/load and sets up
 * V's runtime, but never starts the GC (that only happens in V's generated
 * main(), which a shared library build never has) — so callers must invoke
 * this once, first, themselves. */
void socks_init(void);

/* Error reporting. Reflects the single most recent socks_* call on this
 * process; check immediately after a call that may have failed. */
int socks_last_error_code(void);          /* -1 if the last call succeeded (or none has run yet) */
const char *socks_last_error_message(void); /* human-readable detail of the last error */
const char *socks_strerror(int code);     /* static description for an error code (or -1) */

/* --- Server --- */

/* socks_server_start builds a server config from flat scalar arguments,
 * starts it, and returns a handle (0 on failure).
 *   addr:              listen address, e.g. ":1080" or "127.0.0.1:0"
 *   auth_mode:          SOCKS_AUTH_NONE or SOCKS_AUTH_USERPASS
 *   user, pass:         credentials; only read when auth_mode == SOCKS_AUTH_USERPASS
 *   allow_udp:          enable SOCKS5 UDP ASSOCIATE
 *   versions_mask:      OR of SOCKS_V4 / SOCKS_V4A / SOCKS_V5
 *   resolver_threads:   size of the background DNS/connect worker pool
 *   log_connections:    print one line per accepted connection
 *   handshake_timeout_ms, idle_timeout_ms, connect_timeout_ms:
 *                       <= 0 disables each bound
 *   max_connections:    <= 0 means unlimited
 */
uint64_t socks_server_start(const char *addr, int auth_mode, const char *user,
                             const char *pass, bool allow_udp, int versions_mask,
                             int resolver_threads, bool log_connections,
                             int64_t handshake_timeout_ms, int64_t idle_timeout_ms,
                             int64_t connect_timeout_ms, int max_connections);
void socks_server_stop(uint64_t id);       /* closes the listener; no-op on an unknown id */
void socks_server_wait(uint64_t id);       /* blocks until owned resources are released */
const char *socks_server_addr(uint64_t id); /* bound "host:port", or NULL on an unknown id */

/* --- Client --- */

/* socks_dial connects through the proxy to target_addr ("host:port") and
 * returns the raw connected socket fd. Ownership transfers to the caller:
 * the library's own wrapper is dropped without closing it. -1 on failure. */
int socks_dial(const char *proxy_addr, int version, int auth_mode, const char *user,
                const char *pass, int resolve_mode, const char *target_addr);

/* --- UDP ASSOCIATE --- */

/* socks_udp_associate opens a SOCKS5 UDP association (always SOCKS5;
 * `version` is not a parameter here since UDP ASSOCIATE requires it) and
 * returns a handle (0 on failure). */
uint64_t socks_udp_associate(const char *proxy_addr, int auth_mode, const char *user,
                              const char *pass, int resolve_mode);
/* socks_udp_write_to sends data to addr ("host:port"). Returns bytes sent, or -1. */
int socks_udp_write_to(uint64_t id, const char *addr, const uint8_t *data, int len);
/* socks_udp_read_from blocks for the next datagram: writes the sender's
 * NUL-terminated "host:port" into addr_buf (addr_cap must include room for
 * the NUL) and its payload into data_buf. Returns the payload length, or -1
 * on failure / unknown handle / either buffer too small. */
int socks_udp_read_from(uint64_t id, char *addr_buf, int addr_cap, uint8_t *data_buf,
                         int data_cap);
void socks_udp_close(uint64_t id); /* no-op on an unknown id */

#ifdef __cplusplus
}
#endif

#endif /* SOCKS_H */
