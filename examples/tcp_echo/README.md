# AtomVM TCP Echo Example

A minimal ESP32 application demonstrating `tcp_server` — the per-connection-process
TCP server. Each accepted connection runs in its own worker process, so a large or
slow transfer on one connection never blocks another.

The app connects to WiFi, starts a `tcp_server` running an echo protocol on port
`8080`, and prints its IP address on serial output.

## Architecture

```
tcp_server (listener gen_server)
  ├── acceptor process              (pure socket:accept loop)
  └── connection worker processes   (one per socket: recv → echo → send)
       ├── Worker A (socket 1)
       ├── Worker B (socket 2)
       └── Worker C (socket 3)
```

Contrast with the former `gen_tcp_server` design (since removed), where parsing,
dispatch, and sending were all serialized through a single gen_server — there, one
large response stalled every other connection.

## Prerequisites

1. **ESP32 with AtomVM base firmware flashed**
2. **ESP-IDF environment** (available via `get_idf` alias)
3. **WiFi network** (2.4 GHz for ESP32 compatibility)
4. **Elixir/Erlang on the test host** (the load tester uses OTP's `:gen_tcp`)

## Quick Start

### 1. Set WiFi credentials

```bash
export ATOMVM_WIFI_SSID="your-ssid"
export ATOMVM_WIFI_PSK="your-password"
```

### 2. Build and flash

```bash
cd examples/tcp_echo
./scripts/flash.sh
```

### 3. Monitor serial output

```bash
./scripts/monitor.sh
# Watch for: "TCP Echo ready at <ip>:8080"
```

### 4. Run the concurrent load test

```bash
./scripts/test.sh <esp32-ip>
```

## Load test

`scripts/test.sh` is a thin wrapper around `scripts/load_test.exs`, a pure
Elixir/`:gen_tcp` client (no netcat or curl dependency). It runs:

- **Basic echo** — string and 1 KB random round-trips
- **Payload size sweep** — 100 B → 64 KB, verifying exact byte-for-byte echo
- **Concurrent connections** — 5 small, 5×4 KB, and 8 simultaneous echoes
- **Concurrent load under stress (key test)** — a 64 KB transfer in flight while
  three small requests must each complete in under one second. This is the
  primary validation of the per-connection design; it would fail under the old
  serialized `gen_tcp_server`.
- **Rapid connect/disconnect** — 20 fast cycles, then a health check

You can also run the tester directly:

```bash
elixir scripts/load_test.exs <esp32-ip> 8080
```

## Files

| Path | Purpose |
|------|---------|
| `lib/tcp_echo.ex` | Entry point: WiFi connect, start `tcp_server` |
| `lib/tcp_echo/echo_protocol.ex` | `tcp_server` protocol: echo bytes back |
| `lib/tcp_echo/wifi.ex` | WiFi STA helper (compile-time credentials) |
| `scripts/flash.sh` | Build + flash to ESP32 |
| `scripts/monitor.sh` | Serial monitor (logs to `/tmp/atomvm_serial.log`) |
| `scripts/test.sh` | Concurrent load test wrapper |
| `scripts/load_test.exs` | Pure-Elixir `:gen_tcp` load tester |
