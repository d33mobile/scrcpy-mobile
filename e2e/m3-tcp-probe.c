/* m3-tcp-probe.c — tiny A->B adbd reachability probe pushed onto emulator A.
 *
 * Connects to HOST:PORT (B's adbd, as seen from inside A = 10.0.2.2:5555),
 * sends a valid adb CNXN handshake packet, and prints the reply as hex+ascii.
 * adbd answers any well-formed CNXN with its own CNXN advertising the device
 * banner ("device::..."), which is unambiguous proof we reached an adbd.
 *
 * Usage: m3-tcp-probe <host> <port>
 * Exit: 0 if a non-empty reply was received, 2 on connect failure, 3 on no reply.
 *
 * This is throwaway test tooling cross-compiled with the NDK inside the
 * scrcpy-e2e:dev container; never linked into the app.
 */
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

/* adb message header (system/core/adb/types: amessage), little-endian on wire. */
struct amessage {
    uint32_t command;
    uint32_t arg0;
    uint32_t arg1;
    uint32_t data_length;
    uint32_t data_crc32;
    uint32_t magic;
};

#define A_CNXN 0x4e584e43u  /* "CNXN" */
#define A_VERSION 0x01000001u
#define MAX_PAYLOAD 0x00100000u

static uint32_t crc32_sum(const char *p, size_t n) {
    uint32_t s = 0;
    for (size_t i = 0; i < n; i++) s += (uint8_t)p[i];
    return s;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s host port\n", argv[0]); return 1; }
    const char *host = argv[1];
    const char *port = argv[2];

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0 || !res) {
        printf("PROBE_RESULT=resolve_fail host=%s\n", host);
        return 2;
    }
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { printf("PROBE_RESULT=socket_fail\n"); return 2; }

    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        printf("PROBE_RESULT=connect_fail host=%s port=%s\n", host, port);
        return 2;
    }
    printf("PROBE_RESULT=connected host=%s port=%s\n", host, port);

    /* Build + send a CNXN handshake so adbd replies with its banner. */
    const char *payload = "host::features=cmd,shell_v2";
    size_t plen = strlen(payload) + 1; /* adb includes the NUL */
    struct amessage m;
    m.command = A_CNXN;
    m.arg0 = A_VERSION;
    m.arg1 = MAX_PAYLOAD;
    m.data_length = (uint32_t)plen;
    m.data_crc32 = crc32_sum(payload, plen);
    m.magic = m.command ^ 0xffffffffu;
    write(fd, &m, sizeof m);
    write(fd, payload, plen);

    /* Read the reply. */
    unsigned char buf[256];
    ssize_t n = recv(fd, buf, sizeof buf, 0);
    if (n <= 0) {
        printf("PROBE_RESULT=no_reply n=%zd\n", n);
        close(fd);
        return 3;
    }
    printf("PROBE_RESULT=reply_bytes=%zd\n", n);
    printf("HEX:");
    for (ssize_t i = 0; i < n; i++) printf(" %02x", buf[i]);
    printf("\nASCII: ");
    for (ssize_t i = 0; i < n; i++) putchar((buf[i] >= 32 && buf[i] < 127) ? buf[i] : '.');
    printf("\n");
    /* The reply header command field (first 4 bytes LE) should be CNXN. */
    uint32_t cmd = (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) |
                   ((uint32_t)buf[2] << 16) | ((uint32_t)buf[3] << 24);
    printf("REPLY_COMMAND_IS_CNXN=%s\n", cmd == A_CNXN ? "yes" : "no");
    close(fd);
    return 0;
}
