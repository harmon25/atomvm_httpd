#!/usr/bin/env python3
"""
WebSocket stress test for atomvm_httpd running on real hardware (ESP32).

Validates the WebSocket send path (httpd_ws_handler -> tcp_server:send/2, the
eagain/closed backpressure-retry path) by hammering the debug app's `/ws`
endpoint with concurrent workers and verifying *complete*, byte-accurate
payloads in both directions.

It speaks the WebSocket protocol directly using only the Python standard
library (no `websockets` dependency), so it runs anywhere python3 is present.

Server protocol (see lib/httpd_debug/ws_echo_handler.ex):
  * `gen:<N>`  -> server replies with N bytes where byte[i] == i % 256
                  (exercises large server->client frames / backpressure).
  * <anything> -> echoed back verbatim
                  (validates client->server->client round-trip integrity).

Each test validates the FULL payload; any truncation, corruption, timeout or
connection error is counted as a failure.

Note: `gen` (server->client) is the path exercised by the send-backpressure fix
and is fast even at 64-128 KB.  `echo` additionally uploads the payload and the
device reassembles the inbound WebSocket frame, which is comparatively slow for
large frames (seconds each); raise --timeout or lower --workers/--sizes when
echoing big payloads under concurrency.

Usage:
  ./ws_stress.py <host> [options]

Examples:
  ./ws_stress.py 192.168.25.118
  ./ws_stress.py 192.168.25.118 --mode gen -s 65536,131072 -w 4 -i 25
  ./ws_stress.py 192.168.25.118 --mode echo -s 8192 -w 2 -i 20 -t 30
"""

import argparse
import base64
import hashlib
import os
import socket
import struct
import sys
import threading
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# ---------------------------------------------------------------------------
# Low-level WebSocket framing (RFC 6455)
# ---------------------------------------------------------------------------

class WSError(Exception):
    pass


def ws_connect(host, port, path, timeout):
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    req = (
        "GET {path} HTTP/1.1\r\n"
        "Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    ).format(path=path, host=host, port=port, key=key)
    sock.sendall(req.encode("ascii"))

    # Read response headers up to the blank line.
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(1024)
        if not chunk:
            raise WSError("connection closed during handshake")
        buf += chunk
        if len(buf) > 65536:
            raise WSError("handshake response too large")

    header_blob = buf.split(b"\r\n\r\n", 1)[0]
    status_line = header_blob.split(b"\r\n", 1)[0].decode("latin1")
    if "101" not in status_line:
        raise WSError("handshake failed: %r" % status_line)

    expected = base64.b64encode(
        hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
    ).decode("ascii")
    if expected.lower().encode() not in header_blob.lower():
        raise WSError("missing/invalid Sec-WebSocket-Accept")

    # Any bytes after the header blank line would be unexpected (server waits
    # for a client frame first); ignore leftover if present.
    leftover = buf.split(b"\r\n\r\n", 1)[1]
    return sock, leftover


def ws_send(sock, payload, opcode=0x2):
    """Send a single masked frame (clients MUST mask, per RFC 6455)."""
    fin_op = 0x80 | opcode
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    n = len(payload)
    if n <= 125:
        header = bytes([fin_op, 0x80 | n])
    elif n <= 0xFFFF:
        header = bytes([fin_op, 0x80 | 126]) + struct.pack(">H", n)
    else:
        header = bytes([fin_op, 0x80 | 127]) + struct.pack(">Q", n)
    sock.sendall(header + mask + masked)


def _recv_exact(sock, n, leftover):
    """Read exactly n bytes, consuming `leftover` first. Returns (data, leftover)."""
    out = bytearray()
    if leftover:
        take = leftover[:n]
        out += take
        leftover = leftover[len(take):]
    while len(out) < n:
        chunk = sock.recv(min(65536, n - len(out)))
        if not chunk:
            raise WSError("connection closed after %d/%d bytes" % (len(out), n))
        out += chunk
    return bytes(out), leftover


def ws_recv_message(sock, leftover):
    """Read one (possibly fragmented) WebSocket message. Returns (payload, leftover)."""
    payload = bytearray()
    while True:
        hdr, leftover = _recv_exact(sock, 2, leftover)
        b1, b2 = hdr[0], hdr[1]
        fin = b1 & 0x80
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        ln = b2 & 0x7F
        if ln == 126:
            ext, leftover = _recv_exact(sock, 2, leftover)
            ln = struct.unpack(">H", ext)[0]
        elif ln == 127:
            ext, leftover = _recv_exact(sock, 8, leftover)
            ln = struct.unpack(">Q", ext)[0]
        mask = b""
        if masked:
            mask, leftover = _recv_exact(sock, 4, leftover)
        data, leftover = _recv_exact(sock, ln, leftover)
        if masked:
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))

        # Control frames (close/ping/pong) -> stop / ignore.
        if opcode == 0x8:
            raise WSError("server sent close frame")
        if opcode in (0x9, 0xA):
            # ping/pong: ignore and keep reading.
            if fin:
                continue
            continue

        payload += data
        if fin:
            break
    return bytes(payload), leftover


# ---------------------------------------------------------------------------
# Payload builders / validators
# ---------------------------------------------------------------------------

def gen_pattern(n):
    """byte[i] == i % 256 -- mirrors the server's gen:N reply."""
    block = bytes(range(256))
    full = block * (n // 256 + 1)
    return full[:n]


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.ok = 0
        self.truncated = 0
        self.mismatch = 0
        self.conn_err = 0
        self.bytes = 0
        self.failures = []  # (worker, detail)

    def record(self, kind, nbytes=0, detail=None, worker=None):
        with self.lock:
            if kind == "ok":
                self.ok += 1
                self.bytes += nbytes
            elif kind == "truncated":
                self.truncated += 1
                self.failures.append((worker, detail))
            elif kind == "mismatch":
                self.mismatch += 1
                self.failures.append((worker, detail))
            else:
                self.conn_err += 1
                self.failures.append((worker, detail))


def _cycle(wid, sock, leftover, kind, size, stats, args):
    """Run one request/response cycle. Returns updated leftover."""
    try:
        if kind == "gen":
            ws_send(sock, ("gen:%d" % size).encode("ascii"), opcode=0x1)
            expected = gen_pattern(size)
        else:  # echo
            expected = os.urandom(size)
            ws_send(sock, expected, opcode=0x2)

        payload, leftover = ws_recv_message(sock, leftover)
    except (WSError, socket.timeout, OSError) as e:
        stats.record("conn_err",
                     detail="%s size=%d: %s" % (kind, size, e), worker=wid)
        raise  # propagate so worker abandons this socket

    if len(payload) != len(expected):
        stats.record("truncated",
                     detail="%s size=%d: got %d bytes" % (kind, size, len(payload)),
                     worker=wid)
    elif payload != expected:
        # find first differing offset for a useful message
        off = next((i for i in range(len(payload)) if payload[i] != expected[i]), -1)
        stats.record("mismatch",
                     detail="%s size=%d: byte mismatch at %d" % (kind, size, off),
                     worker=wid)
    else:
        stats.record("ok", nbytes=len(payload), worker=wid)
    return leftover


def worker_run(wid, args, stats):
    try:
        sock, leftover = ws_connect(args.host, args.port, args.path, args.timeout)
    except Exception as e:
        stats.record("conn_err", detail="connect: %s" % e, worker=wid)
        return

    kinds = {"both": ("gen", "echo"), "gen": ("gen",), "echo": ("echo",)}[args.mode]
    try:
        for _it in range(args.iterations):
            for size in args.sizes:
                for kind in kinds:
                    try:
                        leftover = _cycle(wid, sock, leftover, kind, size, stats, args)
                    except Exception:
                        # Socket is suspect after an error; reconnect for the
                        # remaining work so one transient error doesn't void the
                        # whole worker.
                        try:
                            sock.close()
                        except Exception:
                            pass
                        try:
                            sock, leftover = ws_connect(
                                args.host, args.port, args.path, args.timeout)
                        except Exception as e:
                            stats.record("conn_err",
                                         detail="reconnect: %s" % e, worker=wid)
                            return
    finally:
        try:
            sock.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_sizes(s):
    out = []
    for part in s.split(","):
        part = part.strip()
        if part:
            out.append(int(part))
    return out


def main():
    ap = argparse.ArgumentParser(
        description="WebSocket stress test for atomvm_httpd on real hardware.")
    ap.add_argument("host", help="device IP/hostname")
    ap.add_argument("-p", "--port", type=int, default=80)
    ap.add_argument("--path", default="/ws")
    ap.add_argument("-w", "--workers", type=int, default=4,
                    help="concurrent connections (default 4)")
    ap.add_argument("-i", "--iterations", type=int, default=5,
                    help="iterations per worker per size (default 5)")
    ap.add_argument("-s", "--sizes", type=parse_sizes,
                    default=[256, 4096, 32768],
                    help="comma-separated payload sizes (default 256,4096,32768)")
    ap.add_argument("-m", "--mode", choices=["both", "gen", "echo"], default="both",
                    help="gen = server->client (fast), echo = round-trip "
                         "(validates both ways; large frames are slow on device), "
                         "both (default)")
    ap.add_argument("-t", "--timeout", type=float, default=30.0,
                    help="per-operation socket timeout seconds (default 30)")
    args = ap.parse_args()

    total = (args.workers * args.iterations * len(args.sizes)
             * (2 if args.mode == "both" else 1))

    print("=== atomvm_httpd WebSocket Stress Test ===")
    print("Target     : ws://%s:%d%s" % (args.host, args.port, args.path))
    print("Workers    : %d" % args.workers)
    print("Iterations : %d per worker per size" % args.iterations)
    print("Sizes      : %s" % ", ".join(str(s) for s in args.sizes))
    print("Mode       : %s" % args.mode)
    print("Total ops  : %d" % total)
    print("")

    stats = Stats()
    threads = []
    start = time.time()
    for wid in range(args.workers):
        t = threading.Thread(target=worker_run, args=(wid, args, stats))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    elapsed = time.time() - start

    print("=== Results ===")
    print("Completed   : %d" % stats.ok)
    print("Truncated   : %d" % stats.truncated)
    print("Mismatched  : %d" % stats.mismatch)
    print("Conn errors : %d" % stats.conn_err)
    print("Data OK     : %.2f MB" % (stats.bytes / 1048576.0))
    print("Elapsed     : %.1f s" % elapsed)
    if elapsed > 0:
        print("Throughput  : %.2f MB/s, %.1f ops/s"
              % (stats.bytes / 1048576.0 / elapsed, stats.ok / elapsed))
    print("")

    fails = stats.truncated + stats.mismatch + stats.conn_err
    if stats.failures:
        print("=== First failures (up to 15) ===")
        for wid, detail in stats.failures[:15]:
            print("  [w%s] %s" % (wid, detail))
        print("")

    if fails == 0:
        print("\u2713 All %d operations passed (0 truncation / corruption)." % stats.ok)
        return 0
    else:
        print("\u2717 %d failures (%d truncated, %d mismatched, %d conn errors)."
              % (fails, stats.truncated, stats.mismatch, stats.conn_err))
        return 1


if __name__ == "__main__":
    sys.exit(main())
