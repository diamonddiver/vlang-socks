#!/usr/bin/env python3
"""examples/python/client.py - ctypes bindings over libsocks's C ABI, plus a
real end-to-end round trip: starts a SOCKS server, starts a plain TCP echo
target, dials the target through the proxy, and verifies the reply.

Usage:
    LD_LIBRARY_PATH=/path/to/out/linux_amd64 python3 client.py \
        [/path/to/libsocks.so]
"""
import ctypes
import socket
import sys
import threading

SOCKS_AUTH_NONE = 0
SOCKS_AUTH_USERPASS = 1

SOCKS_V4 = 1
SOCKS_V4A = 2
SOCKS_V5 = 4

SOCKS_RESOLVE_SERVER_SIDE = 0
SOCKS_RESOLVE_CLIENT_SIDE = 1


def load_library(path):
    lib = ctypes.CDLL(path)

    lib.socks_init.argtypes = []
    lib.socks_init.restype = None

    lib.socks_last_error_code.argtypes = []
    lib.socks_last_error_code.restype = ctypes.c_int

    lib.socks_last_error_message.argtypes = []
    lib.socks_last_error_message.restype = ctypes.c_char_p

    lib.socks_strerror.argtypes = [ctypes.c_int]
    lib.socks_strerror.restype = ctypes.c_char_p

    # Handles are uint64_t, NOT the ctypes default (c_int) a bare Python int
    # argument would otherwise be marshalled as — get this wrong and 64-bit
    # handle values silently truncate to 32 bits on the C side.
    lib.socks_server_start.argtypes = [
        ctypes.c_char_p,  # addr
        ctypes.c_int,  # auth_mode
        ctypes.c_char_p,  # user
        ctypes.c_char_p,  # pass
        ctypes.c_bool,  # allow_udp
        ctypes.c_int,  # versions_mask
        ctypes.c_int,  # resolver_threads
        ctypes.c_bool,  # log_connections
        ctypes.c_int64,  # handshake_timeout_ms
        ctypes.c_int64,  # idle_timeout_ms
        ctypes.c_int64,  # connect_timeout_ms
        ctypes.c_int,  # max_connections
    ]
    lib.socks_server_start.restype = ctypes.c_uint64

    lib.socks_server_stop.argtypes = [ctypes.c_uint64]
    lib.socks_server_stop.restype = None

    lib.socks_server_wait.argtypes = [ctypes.c_uint64]
    lib.socks_server_wait.restype = None

    lib.socks_server_addr.argtypes = [ctypes.c_uint64]
    lib.socks_server_addr.restype = ctypes.c_char_p

    lib.socks_dial.argtypes = [
        ctypes.c_char_p,  # proxy_addr
        ctypes.c_int,  # version
        ctypes.c_int,  # auth_mode
        ctypes.c_char_p,  # user
        ctypes.c_char_p,  # pass
        ctypes.c_int,  # resolve_mode
        ctypes.c_char_p,  # target_addr
    ]
    lib.socks_dial.restype = ctypes.c_int

    lib.socks_udp_associate.argtypes = [
        ctypes.c_char_p,  # proxy_addr
        ctypes.c_int,  # auth_mode
        ctypes.c_char_p,  # user
        ctypes.c_char_p,  # pass
        ctypes.c_int,  # resolve_mode
    ]
    lib.socks_udp_associate.restype = ctypes.c_uint64

    lib.socks_udp_write_to.argtypes = [
        ctypes.c_uint64,  # id
        ctypes.c_char_p,  # addr
        ctypes.POINTER(ctypes.c_uint8),  # data
        ctypes.c_int,  # len
    ]
    lib.socks_udp_write_to.restype = ctypes.c_int

    lib.socks_udp_read_from.argtypes = [
        ctypes.c_uint64,  # id
        ctypes.c_char_p,  # addr_buf
        ctypes.c_int,  # addr_cap
        ctypes.POINTER(ctypes.c_uint8),  # data_buf
        ctypes.c_int,  # data_cap
    ]
    lib.socks_udp_read_from.restype = ctypes.c_int

    lib.socks_udp_close.argtypes = [ctypes.c_uint64]
    lib.socks_udp_close.restype = None

    return lib


def start_echo_target():
    """A plain TCP listener that echoes back one message, then closes."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    host, port = listener.getsockname()

    def serve():
        conn, _ = listener.accept()
        data = conn.recv(256)
        if data:
            conn.sendall(data)
        conn.close()
        listener.close()

    threading.Thread(target=serve, daemon=True).start()
    return f"{host}:{port}"


def main():
    lib_path = sys.argv[1] if len(sys.argv) > 1 else "libsocks.so"
    lib = load_library(lib_path)

    lib.socks_init()

    target_addr = start_echo_target()

    server_id = lib.socks_server_start(
        b"127.0.0.1:0", SOCKS_AUTH_NONE, b"", b"", True,
        SOCKS_V4 | SOCKS_V4A | SOCKS_V5, 4, False, 0, 0, 0, 0,
    )
    if server_id == 0:
        print("socks_server_start failed:", lib.socks_last_error_message().decode())
        return 1
    proxy_addr = lib.socks_server_addr(server_id).decode()
    print(f"proxy listening on {proxy_addr}, echo target on {target_addr}")

    fd = lib.socks_dial(
        proxy_addr.encode(), SOCKS_V5, SOCKS_AUTH_NONE, b"", b"",
        SOCKS_RESOLVE_SERVER_SIDE, target_addr.encode(),
    )
    if fd < 0:
        print("socks_dial failed:", lib.socks_last_error_message().decode())
        return 1

    conn = socket.socket(fileno=fd)
    message = b"hello from python"
    conn.sendall(message)
    reply = conn.recv(256)
    conn.close()

    ok = reply == message
    print("sent:", message.decode())
    print("received:", reply.decode())
    print("round trip:", "OK" if ok else "MISMATCH")

    lib.socks_server_stop(server_id)
    lib.socks_server_wait(server_id)

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
