"""Local DNS forwarder for Roblox only.

The shim sends Roblox's lookups to 127.0.0.1:<port> (MACNCHEESE_DNS), and this
forwards them over DNS-over-TLS (or plain UDP for a custom server). Some
Roblox image hosts do not resolve through ISP or system resolvers in some
regions, and plain UDP DNS to public resolvers is often tampered with there;
the rest of the system keeps its own DNS."""

import socket
import ssl
import struct
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from .i18n import _

PROVIDERS = {
    "quad9": ("9.9.9.9", "dns.quad9.net"),
    "cloudflare": ("1.1.1.1", "cloudflare-dns.com"),
    "google": ("8.8.8.8", "dns.google"),
}


# Idle DNS-over-TLS connections are closed by the servers after a while;
# older pooled ones are dropped instead of being tried first.
POOL_IDLE_SECONDS = 20
CACHE_ENTRIES = 2048
# A lookup gets this long upstream, less than the 2.5 s the shim waits for
# an answer (dns_override.c): a server that cannot be reached is answered
# with SERVFAIL, and the shim falls back to Darling's resolver at once.
UPSTREAM_SECONDS = 2.0
# After a failed lookup, SERVFAIL right away for this long instead of
# making every lookup wait for the dead server again.
DOWN_SECONDS = 30


def parse_server(text):
    """(host, port) of a custom DNS server written as 9.9.9.9, 9.9.9.9:53,
    2620:fe::fe, [2620:fe::fe]:53 or a host name. Raises ValueError with a
    message for the user."""
    text = text.strip()
    host, port = text, "53"
    if text.startswith("["):
        host, _bracket, rest = text[1:].partition("]")
        if rest:
            port = rest[1:] if rest.startswith(":") else ""
    elif text.count(":") == 1:
        host, port = text.split(":")
    if not host or not port.isdigit() or not 0 < int(port) < 65536 or any(c.isspace() for c in host):
        raise ValueError(_("Custom DNS server must look like 9.9.9.9, 9.9.9.9:53 or [2620:fe::fe]:53"))
    return host, int(port)


def _question_end(message):
    """Offset just past the (single) question of a DNS message, or None."""
    try:
        position = 12
        while message[position]:
            if message[position] & 0xC0:
                return None
            position += message[position] + 1
        return position + 5
    except IndexError:
        return None


def _servfail(query):
    """A SERVFAIL answer to `query`: its ID, opcode, RD bit and question."""
    flags = struct.unpack(">H", query[2:4])[0]
    end = _question_end(query)
    question = query[12:end] if end and end <= len(query) else b""
    return (query[:2] + struct.pack(">HHHHH", 0x8000 | (flags & 0x7900) | 0x0080 | 2,
                                    1 if question else 0, 0, 0, 0) + question)


def _min_ttl(response):
    """Smallest TTL in the answer section, or None."""
    try:
        answers = struct.unpack(">H", response[6:8])[0]
        offset = 12

        def skip_name(position):
            while True:
                length = response[position]
                if length == 0:
                    return position + 1
                if length & 0xC0 == 0xC0:
                    return position + 2
                position += length + 1

        offset = skip_name(offset) + 4
        ttls = []
        for _answer in range(answers):
            offset = skip_name(offset)
            _type, _class, ttl, length = struct.unpack(">HHIH", response[offset:offset + 10])
            ttls.append(ttl)
            offset += 10 + length
        return min(ttls) if ttls else None
    except (IndexError, struct.error):
        return None


class DnsForwarder:
    def __init__(self, provider, custom=""):
        if provider in PROVIDERS:
            self.server, self.tls_name = PROVIDERS[provider]
            self.port = 853
        else:
            self.server, self.port = parse_server(custom)
            self.tls_name = None
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.settimeout(0.5)
        self.address = "127.0.0.1:%d" % self.socket.getsockname()[1]
        self.cache = {}
        self.cache_lock = threading.Lock()
        self.pool = []
        self.pool_lock = threading.Lock()
        self.context = ssl.create_default_context()
        self.executor = ThreadPoolExecutor(max_workers=8)
        self.down_until = 0.0  # time.monotonic() until which the server counts as down
        self.upstream_address = None  # resolved custom server, (family, address)
        self.running = True
        threading.Thread(target=self._serve, daemon=True).start()

    def stop(self):
        self.running = False
        self.executor.shutdown(wait=False)
        with self.pool_lock:
            for connection, _used in self.pool:
                connection.close()
            self.pool.clear()

    def _serve(self):
        try:
            while self.running:
                try:
                    query, client = self.socket.recvfrom(4096)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if len(query) > 12:
                    try:
                        self.executor.submit(self._answer, query, client)
                    except RuntimeError:  # stop() shut the executor down meanwhile
                        break
        finally:
            self.socket.close()

    def _answer(self, query, client):
        key = query[2:]
        now = time.time()
        with self.cache_lock:
            cached = self.cache.get(key)
        if cached and cached[0] > now:
            response = query[:2] + cached[1]
        else:
            response = self._resolve(query)
            if not response:
                # Not cached: the next lookup tries the server again.
                response = _servfail(query)
            else:
                self._cache(key, response, now)
        try:
            self.socket.sendto(response, client)
        except OSError:
            pass

    def _cache(self, key, response, now):
        if response[3] & 15 not in (0, 3):  # only answers and NXDOMAIN
            return
        ttl = _min_ttl(response)
        ttl = 30 if ttl is None else max(30, min(ttl, 600))
        with self.cache_lock:
            if len(self.cache) >= CACHE_ENTRIES:
                self.cache = {k: v for k, v in self.cache.items() if v[0] > now}
                if len(self.cache) >= CACHE_ENTRIES:
                    self.cache.clear()
            self.cache[key] = (now + ttl, response[2:])

    def _resolve(self, query):
        """The server's answer, or None when it cannot be had in time."""
        if time.monotonic() < self.down_until:
            return None
        deadline = time.monotonic() + UPSTREAM_SECONDS
        response = self._resolve_tls(query, deadline) if self.tls_name else self._resolve_udp(query, deadline)
        if response is None:
            self.down_until = time.monotonic() + DOWN_SECONDS
        return response

    def _resolve_udp(self, query, deadline):
        end = _question_end(query) or 12
        if self.upstream_address is None:
            try:
                family, _kind, _proto, _name, address = socket.getaddrinfo(
                    self.server, self.port, type=socket.SOCK_DGRAM)[0]
            except OSError:
                return None
            self.upstream_address = family, address
        family, address = self.upstream_address
        with socket.socket(family, socket.SOCK_DGRAM) as upstream:
            try:
                upstream.connect(address)  # the kernel drops replies from anyone else
            except OSError:
                return None
            # Two tries of up to a second each, within the deadline.
            for _attempt in range(2):
                left = deadline - time.monotonic()
                if left <= 0.05:
                    break
                upstream.settimeout(min(1.0, left))
                try:
                    upstream.send(query)
                    while True:  # skip stray datagrams that are not the answer
                        response = upstream.recv(4096)
                        # Same ID and the same question: an answer to this query.
                        if response[:2] == query[:2] and response[12:end] == query[12:end]:
                            return response
                except OSError:  # timeout, or the port is closed
                    continue
        return None

    def _connect(self, timeout):
        raw = socket.create_connection((self.server, self.port), timeout=timeout)
        try:
            return self.context.wrap_socket(raw, server_hostname=self.tls_name)
        except BaseException:
            raw.close()
            raise

    @staticmethod
    def _read_exact(connection, length):
        data = b""
        while len(data) < length:
            chunk = connection.recv(length - len(data))
            if not chunk:
                raise OSError("connection closed")
            data += chunk
        return data

    def _pooled(self):
        """A pooled connection that has not sat idle for too long, or None."""
        now = time.monotonic()
        with self.pool_lock:
            while self.pool:
                connection, used = self.pool.pop()
                if now - used < POOL_IDLE_SECONDS:
                    return connection
                connection.close()
        return None

    def _release(self, connection):
        with self.pool_lock:
            if self.running and len(self.pool) < 4:
                self.pool.append((connection, time.monotonic()))
                return
        connection.close()

    def _resolve_tls(self, query, deadline):
        # A pooled connection the server has closed fails at once and does
        # not count: only two new connections are tried.
        fresh = 0
        while fresh < 2:
            left = deadline - time.monotonic()
            if left <= 0.05:
                break
            connection = self._pooled()
            if connection is None:
                fresh += 1
                try:
                    connection = self._connect(left)
                except (OSError, ssl.SSLError):
                    continue
            try:
                connection.settimeout(max(0.05, deadline - time.monotonic()))
                connection.sendall(struct.pack(">H", len(query)) + query)
                length = struct.unpack(">H", self._read_exact(connection, 2))[0]
                response = self._read_exact(connection, length)
            except (OSError, ssl.SSLError, struct.error):
                connection.close()
                continue
            self._release(connection)
            return response
        return None


def resolve_a(host, provider="quad9", timeout=5):
    """IPv4 addresses of `host` from one DNS-over-TLS query, for the
    launcher's own downloads when the system resolver fails."""
    server, tls_name = PROVIDERS.get(provider, PROVIDERS["quad9"])
    query = struct.pack(">HHHHHH", 0x4d42, 0x0100, 1, 0, 0, 0)
    for label in host.rstrip(".").split("."):
        query += bytes([len(label)]) + label.encode()
    query += b"\0" + struct.pack(">HH", 1, 1)
    raw = socket.create_connection((server, 853), timeout=timeout)
    with ssl.create_default_context().wrap_socket(raw, server_hostname=tls_name) as connection:
        connection.sendall(struct.pack(">H", len(query)) + query)
        length = struct.unpack(">H", DnsForwarder._read_exact(connection, 2))[0]
        response = DnsForwarder._read_exact(connection, length)

    def skip_name(position):
        while True:
            length = response[position]
            if length == 0:
                return position + 1
            if length & 0xC0 == 0xC0:
                return position + 2
            position += length + 1

    answers = struct.unpack(">H", response[6:8])[0]
    offset = skip_name(12) + 4
    addresses = []
    for _answer in range(answers):
        offset = skip_name(offset)
        kind, _class, _ttl, length = struct.unpack(">HHIH", response[offset:offset + 10])
        offset += 10
        if kind == 1 and length == 4:
            addresses.append(socket.inet_ntoa(response[offset:offset + 4]))
        offset += length
    return addresses
