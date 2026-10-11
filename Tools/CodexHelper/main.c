#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static struct sockaddr_storage proxy_address;
static socklen_t proxy_length;
static const unsigned char target[] = "codex-cloud-backend.chatgpt.com";

static int transfer(int fd, unsigned char *bytes, size_t count, int writing) {
    while (count) {
        ssize_t length = writing ? send(fd, bytes, count, 0) : recv(fd, bytes, count, 0);
        if (length < 0 && errno == EINTR) continue;
        if (length <= 0) return -1;
        bytes += length;
        count -= (size_t)length;
    }
    return 0;
}

static int connect_proxy(void) {
    int fd = socket(proxy_address.ss_family, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) goto failed;
    if (connect(fd, (struct sockaddr *)&proxy_address, proxy_length) < 0) {
        if (errno != EINPROGRESS) goto failed;
        struct pollfd event = { fd, POLLOUT, 0 };
        int error = 0;
        socklen_t size = sizeof(error);
        if (poll(&event, 1, 10000) <= 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) < 0 || error)
            goto failed;
    }
    if (fcntl(fd, F_SETFL, flags) < 0) goto failed;
    struct timeval timeout = { 10, 0 };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) < 0) goto failed;
    unsigned char greeting[] = { 5, 1, 0 }, reply[260];
    if (transfer(fd, greeting, sizeof(greeting), 1) || transfer(fd, reply, 2, 0) || reply[0] != 5 || reply[1] != 0)
        goto failed;
    unsigned char request[5 + sizeof(target) - 1 + 2] = { 5, 1, 0, 3, sizeof(target) - 1 };
    memcpy(request + 5, target, sizeof(target) - 1);
    request[sizeof(request) - 2] = 1;
    request[sizeof(request) - 1] = 187;
    if (transfer(fd, request, sizeof(request), 1) || transfer(fd, reply, 4, 0) ||
        reply[0] != 5 || reply[1] != 0 || reply[2] != 0) goto failed;
    size_t count;
    if (reply[3] == 1) count = 4;
    else if (reply[3] == 4) count = 16;
    else if (reply[3] == 3) {
        if (transfer(fd, reply, 1, 0)) goto failed;
        count = reply[0];
    } else goto failed;
    if (transfer(fd, reply, count + 2, 0)) goto failed;
    timeout.tv_sec = 0;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) goto failed;
    return fd;
failed:
    close(fd);
    return -1;
}

static void *relay(void *argument) {
    int client = *(int *)argument;
    free(argument);
    int upstream = connect_proxy();
    if (upstream < 0) goto finished;
    struct pollfd peers[2] = { { client, POLLIN, 0 }, { upstream, POLLIN, 0 } };
    unsigned char bytes[65536];
    for (;;) {
        int ready = poll(peers, 2, 60000);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) break;
        for (int index = 0; index < 2; index++) {
            if (!(peers[index].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))) continue;
            ssize_t count = recv(peers[index].fd, bytes, sizeof(bytes), 0);
            if (count <= 0 || transfer(peers[1 - index].fd, bytes, (size_t)count, 1)) goto finished;
        }
    }
finished:
    if (upstream >= 0) close(upstream);
    close(client);
    return NULL;
}

static int listener(int family, int port) {
    int fd = socket(family, SOCK_STREAM, 0), enabled = 1;
    if (fd < 0) return -1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) < 0) goto failed;
    if (family == AF_INET) {
        struct sockaddr_in address = { .sin_len = sizeof(address), .sin_family = AF_INET,
                                       .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) goto failed;
    } else {
        struct sockaddr_in6 address = { .sin6_len = sizeof(address), .sin6_family = AF_INET6,
                                        .sin6_port = htons((uint16_t)port), .sin6_addr = IN6ADDR_LOOPBACK_INIT };
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, sizeof(enabled)) < 0 ||
            bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) goto failed;
    }
    if (listen(fd, 128) < 0) goto failed;
    return fd;
failed:
    close(fd);
    return -1;
}

static int port_number(const char *value) {
    char *end;
    long port = strtol(value, &end, 10);
    return value[0] && !*end && port > 0 && port <= 65535 ? (int)port : 0;
}

int main(int argc, char **argv) {
    const char *host = NULL;
    int proxy_port = 0, port = 443;
    for (int index = 1; index < argc; index += 2) {
        if (index + 1 >= argc) return 2;
        if (!strcmp(argv[index], "--proxy-host")) host = argv[index + 1];
        else if (!strcmp(argv[index], "--proxy-port")) proxy_port = port_number(argv[index + 1]);
        else if (!strcmp(argv[index], "--port")) port = port_number(argv[index + 1]);
        else return 2;
    }
    if (!host || !proxy_port || !port) return 2;
    if (!strcmp(host, "127.0.0.1") || !strcmp(host, "localhost")) {
        struct sockaddr_in *address = (struct sockaddr_in *)&proxy_address;
        address->sin_len = sizeof(*address);
        address->sin_family = AF_INET;
        address->sin_port = htons((uint16_t)proxy_port);
        address->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        proxy_length = sizeof(*address);
    } else if (!strcmp(host, "::1")) {
        struct sockaddr_in6 *address = (struct sockaddr_in6 *)&proxy_address;
        address->sin6_len = sizeof(*address);
        address->sin6_family = AF_INET6;
        address->sin6_port = htons((uint16_t)proxy_port);
        address->sin6_addr = in6addr_loopback;
        proxy_length = sizeof(*address);
    } else return 2;
    signal(SIGPIPE, SIG_IGN);
    struct pollfd sockets[2] = { { listener(AF_INET, port), POLLIN, 0 }, { listener(AF_INET6, port), POLLIN, 0 } };
    if (sockets[0].fd < 0 || sockets[1].fd < 0) {
        fprintf(stderr, "CodexHelper: loopback port unavailable\n");
        return 1;
    }
    for (;;) {
        int ready = poll(sockets, 2, -1);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) return 1;
        for (int index = 0; index < 2; index++) {
            if (!(sockets[index].revents & POLLIN)) continue;
            int client = accept(sockets[index].fd, NULL, NULL);
            if (client < 0) continue;
            int *argument = malloc(sizeof(*argument));
            if (!argument) { close(client); continue; }
            *argument = client;
            pthread_t thread;
            if (pthread_create(&thread, NULL, relay, argument)) { close(client); free(argument); }
            else pthread_detach(thread);
        }
    }
}
