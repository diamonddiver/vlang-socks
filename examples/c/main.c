/* examples/c/main.c - drives a real end-to-end proxied connection through
 * libsocks: starts a SOCKS server, starts a plain TCP echo target, dials the
 * target through the proxy with socks_dial(), and round-trips a message.
 *
 * Build (see README-less quickstart, or examples/c/Makefile is intentionally
 * skipped for this single-file example — invoke gcc directly):
 *   gcc $(pkg-config --cflags socks) -o main main.c $(pkg-config --libs socks) -lpthread
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "socks.h"

/* run_echo_target accepts exactly one connection and echoes back whatever it
 * reads, once, then exits. Runs on its own thread so main() can dial it
 * through the proxy while it's waiting to accept. */
static void *run_echo_target(void *arg) {
    int listen_fd = *(int *)arg;
    int conn_fd = accept(listen_fd, NULL, NULL);
    if (conn_fd < 0) {
        return NULL;
    }
    char buf[256];
    ssize_t n = read(conn_fd, buf, sizeof(buf));
    if (n > 0) {
        write(conn_fd, buf, (size_t)n);
    }
    close(conn_fd);
    close(listen_fd);
    return NULL;
}

int main(void) {
    socks_init();

    /* 1. Start a plain TCP echo target on an ephemeral loopback port. */
    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(listen_fd, 1) != 0) {
        fprintf(stderr, "failed to set up echo target\n");
        return 1;
    }
    socklen_t addr_len = sizeof(addr);
    getsockname(listen_fd, (struct sockaddr *)&addr, &addr_len);
    char target_addr[64];
    snprintf(target_addr, sizeof(target_addr), "127.0.0.1:%d", ntohs(addr.sin_port));

    pthread_t echo_thread;
    pthread_create(&echo_thread, NULL, run_echo_target, &listen_fd);

    /* 2. Start the SOCKS proxy server itself, on another ephemeral port. */
    uint64_t server_id = socks_server_start("127.0.0.1:0", SOCKS_AUTH_NONE, "", "",
                                             true, SOCKS_V4 | SOCKS_V4A | SOCKS_V5,
                                             4, false, 0, 0, 0, 0);
    if (server_id == 0) {
        fprintf(stderr, "socks_server_start failed: %s\n", socks_last_error_message());
        return 1;
    }
    const char *proxy_addr = socks_server_addr(server_id);
    printf("proxy listening on %s, echo target on %s\n", proxy_addr, target_addr);

    /* 3. Dial the echo target THROUGH the proxy. */
    int fd = socks_dial(proxy_addr, SOCKS_V5, SOCKS_AUTH_NONE, "", "",
                         SOCKS_RESOLVE_SERVER_SIDE, target_addr);
    if (fd < 0) {
        fprintf(stderr, "socks_dial failed: %s\n", socks_last_error_message());
        return 1;
    }

    const char *msg = "hello from C";
    write(fd, msg, strlen(msg));
    char reply[256] = {0};
    ssize_t n = read(fd, reply, sizeof(reply) - 1);
    close(fd);

    pthread_join(echo_thread, NULL);

    int ok = n == (ssize_t)strlen(msg) && strncmp(msg, reply, (size_t)n) == 0;
    printf("sent: %s\n", msg);
    printf("received: %.*s\n", (int)n, reply);
    printf("round trip: %s\n", ok ? "OK" : "MISMATCH");

    socks_server_stop(server_id);
    socks_server_wait(server_id);

    return ok ? 0 : 1;
}
