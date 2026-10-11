#!/usr/bin/env python3
import argparse
import select
import socket
import socketserver
import sys
import threading

TARGET = b"codex-cloud-backend.chatgpt.com"
PROXY = None


def read_exact(connection, count):
    data = bytearray()
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        if not chunk:
            raise ConnectionError("SOCKS5 connection closed")
        data.extend(chunk)
    return bytes(data)


def connect_proxy():
    connection = socket.create_connection(PROXY, timeout=10)
    try:
        connection.sendall(b"\x05\x01\x00")
        if read_exact(connection, 2) != b"\x05\x00":
            raise ConnectionError("SOCKS5 authentication method rejected")
        connection.sendall(b"\x05\x01\x00\x03" + bytes([len(TARGET)])
                           + TARGET + (443).to_bytes(2, "big"))
        reply = read_exact(connection, 4)
        if reply[:3] != b"\x05\x00\x00":
            raise ConnectionError("SOCKS5 destination connection rejected")
        if reply[3] == 1:
            size = 4
        elif reply[3] == 4:
            size = 16
        elif reply[3] == 3:
            size = read_exact(connection, 1)[0]
        else:
            raise ConnectionError("SOCKS5 address type unsupported")
        read_exact(connection, size + 2)
        connection.settimeout(None)
        return connection
    except Exception:
        connection.close()
        raise


class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            with connect_proxy() as upstream:
                peers = {self.request: upstream, upstream: self.request}
                while True:
                    ready, _, _ = select.select(list(peers), [], [], 60)
                    for source in ready:
                        data = source.recv(65536)
                        if not data:
                            return
                        peers[source].sendall(data)
        except (OSError, ConnectionError) as error:
            print(f"Relay connection failed: {error}", file=sys.stderr, flush=True)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class IPv6Server(Server):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Forward the Codex cloud backend through local SOCKS5")
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument("--proxy-host", required=True, choices=["127.0.0.1", "::1", "localhost"])
    parser.add_argument("--proxy-port", required=True, type=int)
    args = parser.parse_args()
    if not 1 <= args.proxy_port <= 65535:
        parser.error("Invalid proxy port")
    PROXY = (args.proxy_host, args.proxy_port)
    with Server(("127.0.0.1", args.port), Relay) as server, IPv6Server(("::1", args.port), Relay) as ipv6_server:
        threading.Thread(target=ipv6_server.serve_forever, daemon=True).start()
        server.serve_forever()
