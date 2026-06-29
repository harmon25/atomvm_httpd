# Plan: `tcp_server.erl` — Per-Connection Process TCP Server

## Problem

All HTTP request processing and response sending is serialized through a single
`gen_server` process (`gen_tcp_server.erl`). Per-connection processes exist but
only forward raw bytes — parsing, handler dispatch, and chunked `socket:send`
all run in one process. A 16 KB response at 4096-byte chunks can block the
gen_server for 40–110 ms, during which no other connection can be served.

## Investigation Summary

A deep investigation of the AtomVM socket stack confirmed that the bottleneck is
**entirely at the Erlang layer**, not in the underlying platform:

- **ESP32 uses `OTP_SOCKET_BSD`** (POSIX BSD socket API via lwIP), not the raw
  lwIP API. Set in `AtomVM/src/platforms/esp32/CMakeLists.txt:34`.
- **All NIF calls are non-blocking.** `nif_send`, `nif_recv`, `nif_accept` return
  immediately. Blocking is done at the Erlang level via `nif_select_read` +
  `receive` (see `AtomVM/libs/estdlib/src/socket.erl:377–399`).
- **`LWIP_TCPIP_CORE_LOCKING` is false** on ESP32. lwIP uses message-passing to
  its TCP task, not a global mutex. BSD socket calls from different threads/
  processes on *different* sockets are fully thread-safe.
- **A dedicated `select_thread`** (`AtomVM/src/platforms/esp32/.../sys.c:692–773`)
  runs `poll()` on all registered fds simultaneously — it already monitors
  multiple sockets concurrently.
- **Concurrent send+recv on different sockets from different processes works.**
  Per Espressif docs: "read, write, and close operations from different threads
  on the same socket simultaneously" are supported.
- **`socket:recv/1,2,3` all supported** by AtomVM. `recv/3` accepts a timeout
  in milliseconds, `infinity`, or `nowait`. Internally uses `nif_select_read` +
  `receive` — the process genuinely suspends, allowing the scheduler to run
  other processes.

### Key AtomVM socket facts

| Fact | Detail |
|------|--------|
| Socket API on ESP32 | BSD sockets (`OTP_SOCKET_BSD`), not raw lwIP |
| `socket:send/2` | Single NIF call, sends at most `TCP_MSS` (1440 bytes), returns `{ok, Rest}` on partial send |
| `socket:recv/1,2,3` | Non-blocking NIF + select. `recv/3` supports timeout. Returns `{error, timeout}` on EAGAIN |
| `LWIP_MAX_SOCKETS` | 10 (hard cap on concurrent sockets) |
| `TCP_SND_BUF_DEFAULT` | 5760 bytes (4× TCP_MSS) |
| `TCP_MSS` | 1440 bytes |
| Partial send (`{ok, Rest}`) | Normal on ESP32 — tcp_write accepts at most TCP_MSS per call |

---

## Approach: Two Phases

### Phase A — Standalone `tcp_server` + echo example (this phase)

Build and validate `tcp_server.erl` as a standalone per-connection-process TCP
server. Includes:
- `src/tcp_server.erl` — the library module
- `test/tcp_server_test.exs` — host-side ExUnit tests (run on OTP)
- `examples/tcp_echo/` — ESP32 example app with WiFi, echo protocol
- `examples/tcp_echo/scripts/test.sh` — hardware load test script (targets real
  ESP32 over network, exercises concurrent connections)

### Phase B — HTTP migration (future session)

Refactor `httpd.erl` to implement the `tcp_server` behavior. Remove
`gen_tcp_server.erl`. Update all tests. (Covered at end of this document.)

---

## Phase A: Standalone `tcp_server`

### Architecture

```
tcp_server (listener gen_server)
  ├── Acceptor process            ← socket:accept, notify listener, become worker
  └── Connection worker processes ← each owns 1 socket for full lifecycle
       ├── Worker A (socket 1)    recv → Protocol:handle_data → send → loop
       ├── Worker B (socket 2)
       └── Worker C (socket 3)
```

### Behavior API (`tcp_server`)

```erlang
-callback init(Socket :: socket:socket(), Args :: term()) ->
    {ok, State :: term()} | {error, Reason :: term()}.

-callback handle_data(Data :: binary(), State :: term()) ->
    {send, Response :: iodata(), NewState :: term()}
  | {send_close, Response :: iodata()}
  | {continue, NewState :: term()}
  | {close, NewState :: term()}
  | {error, Reason :: term()}.

-callback handle_info(Msg :: term(), State :: term()) ->
    {ok, NewState :: term()}
  | {send, Response :: iodata(), NewState :: term()}
  | {close, NewState :: term()}.

-callback handle_close(Reason :: term(), State :: term()) -> ok.
```

### Public API

```erlang
-export([start_link/4, start_link/3, stop/1, send/3]).

start_link(BindOptions, ProtocolModule, ProtocolArgs)
start_link(BindOptions, SocketOptions, ProtocolModule, ProtocolArgs)
stop(Server)
send(Socket, Data, ChunkSize)   %% helper for protocol modules
```

### Components

#### 1. Listener gen_server

Responsibilities:
- Open, setopt, bind, listen (same socket setup as current `gen_tcp_server:init/1`)
- Extract `max_connections` and `chunk_size` from SocketOptions before setopt
  (same strip logic: `maps:remove(chunk_size, maps:remove(max_connections, Opts))`)
- Spawn initial acceptor process (linked to listener)
- Track active connection workers: `#{Pid => MonitorRef}`
- Enforce `max_connections` — on `{accepted, Socket, WorkerPid}`, check count;
  if over limit, send `{tcp_server, close}` to the worker
- Handle `{'DOWN', Ref, process, Pid, _}` — remove worker from tracking
- `terminate/2` — close listen socket

State record:
```erlang
-record(listener_state, {
    listen_socket,
    protocol,           %% callback module
    protocol_args,      %% args passed to Protocol:init/2
    chunk_size,         %% default 4096
    max_connections,    %% 0 = unlimited
    connections = #{}   %% #{Pid => MonitorRef}
}).
```

#### 2. Acceptor process

```erlang
accept(Listener, ListenSocket, Protocol, ProtocolArgs, ChunkSize) ->
    case socket:accept(ListenSocket) of
        {ok, Connection} ->
            spawn_link(fun() ->
                accept(Listener, ListenSocket, Protocol, ProtocolArgs, ChunkSize)
            end),
            Listener ! {accepted, Connection, self()},
            connection_init(Connection, Protocol, ProtocolArgs, ChunkSize);
        _Error ->
            timer:sleep(100),
            accept(Listener, ListenSocket, Protocol, ProtocolArgs, ChunkSize)
    end.
```

The acceptor becomes the connection worker. A new acceptor is spawned first so
the accept loop never stalls. Acceptors are linked to the listener so they are
cleaned up on server stop.

**Link management**: When the acceptor becomes a worker, it is already linked to
the listener. The next acceptor is also `spawn_link`ed — but from the *current*
process (which is about to become a worker), not the listener. We need to ensure
each acceptor is linked to the listener. Options:
- After spawn, explicitly `link(Listener)` in the new acceptor
- Or have the listener spawn acceptors via a message protocol
- Simplest: acceptors call `erlang:unlink(Spawner)` + `erlang:link(Listener)`
  at the start of `accept/5`

#### 3. Connection worker

```erlang
connection_init(Socket, Protocol, ProtocolArgs, ChunkSize) ->
    case Protocol:init(Socket, ProtocolArgs) of
        {ok, State} ->
            connection_loop(Socket, Protocol, State, ChunkSize);
        {error, _Reason} ->
            try_close(Socket)
    end.

connection_loop(Socket, Protocol, State, ChunkSize) ->
    case check_messages(Protocol, State) of
        {ok, NewState} ->
            case socket:recv(Socket) of
                {ok, Data} ->
                    handle_protocol_result(
                        Protocol:handle_data(Data, NewState),
                        Socket, Protocol, ChunkSize);
                {error, closed} ->
                    Protocol:handle_close(closed, NewState);
                {error, timeout} ->
                    connection_loop(Socket, Protocol, NewState, ChunkSize);
                {error, Reason} ->
                    Protocol:handle_close(Reason, NewState),
                    try_close(Socket)
            end;
        {send, Response, NewState} ->
            do_send(Socket, Response, ChunkSize),
            connection_loop(Socket, Protocol, NewState, ChunkSize);
        {close, NewState} ->
            Protocol:handle_close(normal, NewState),
            try_close(Socket)
    end.

check_messages(Protocol, State) ->
    receive
        {tcp_server, close} -> {close, State};
        Msg ->
            case Protocol:handle_info(Msg, State) of
                {ok, NewState}             -> check_messages(Protocol, NewState);
                {send, Response, NewState} -> {send, Response, NewState};
                {close, NewState}          -> {close, NewState}
            end
    after 0 ->
        {ok, State}
    end.

handle_protocol_result(Result, Socket, Protocol, ChunkSize) ->
    case Result of
        {send, Response, NewState} ->
            do_send(Socket, Response, ChunkSize),
            connection_loop(Socket, Protocol, NewState, ChunkSize);
        {send_close, Response} ->
            do_send(Socket, Response, ChunkSize),
            try_close(Socket);
        {continue, NewState} ->
            connection_loop(Socket, Protocol, NewState, ChunkSize);
        {close, _NewState} ->
            try_close(Socket);
        {error, _Reason} ->
            try_close(Socket)
    end.
```

#### 4. `do_send/3` — Chunked send helper

Extracted from current `gen_tcp_server:try_send_binary/3` (lines 265–303).
Runs in the worker process, so blocking is fine.

```erlang
do_send(_Socket, <<>>, _ChunkSize) ->
    ok;
do_send(Socket, Packet, ChunkSize) when is_list(Packet) ->
    do_send(Socket, erlang:iolist_to_binary(Packet), ChunkSize);
do_send(Socket, Packet, ChunkSize) when is_binary(Packet) ->
    Size = byte_size(Packet),
    Chunk = erlang:min(Size, ChunkSize),
    <<ToSend:Chunk/binary, Rest/binary>> = Packet,
    case socket:send(Socket, ToSend) of
        ok ->
            case byte_size(Rest) > 0 of
                true -> receive after 0 -> ok end;   %% yield scheduler
                false -> ok
            end,
            do_send(Socket, Rest, ChunkSize);
        {ok, Unsent} ->
            receive after 10 -> ok end,  %% lwIP send buffer full
            do_send(Socket, <<Unsent/binary, Rest/binary>>, ChunkSize);
        {error, closed} -> {error, closed};
        {error, Reason} -> {error, Reason}
    end.
```

---

### Host-side tests: `test/tcp_server_test.exs`

ExUnit integration tests running on host OTP. Uses `:gen_tcp` as the client.
Same test infrastructure pattern as existing `httpd_integration_test.exs`:
dynamic port allocation, `:gen_tcp.connect`, `on_exit` cleanup.

Tests:
- Basic echo round-trip
- Multiple sequential requests on one connection
- Large payload echo (64KB)
- Connection close on `{send_close, ...}`
- 5 concurrent connections all echoing simultaneously
- Large echo on one connection does not block another connection
- Rapid connect/disconnect cycles
- max_connections enforcement
- Custom chunk_size

Test support module: `test/support/test_echo_protocol.ex` — implements
`:tcp_server` behavior, echoes data back, sends notifications to test pid.

---

### ESP32 example: `examples/tcp_echo/`

A complete ESP32 application following the same pattern as `examples/httpd_debug/`.
Connects to WiFi, starts a `tcp_server` with an echo protocol, and reports its
IP address on serial output.

#### Structure

```
examples/tcp_echo/
  ├── mix.exs                         # Mix project, depends on atomvm_httpd
  ├── lib/
  │   ├── tcp_echo.ex                 # Entry point: WiFi connect, start server
  │   ├── tcp_echo/
  │   │   ├── echo_protocol.ex        # tcp_server protocol: echo bytes back
  │   │   └── wifi.ex                 # WiFi STA helper (same as httpd_debug)
  ├── scripts/
  │   ├── flash.sh                    # Build + flash to ESP32
  │   ├── monitor.sh                  # Serial monitor
  │   └── test.sh                     # Concurrent load test (targets ESP32 IP)
  └── README.md
```

#### `lib/tcp_echo.ex` — Entry point

```elixir
defmodule TcpEcho do
  def start do
    IO.puts("TcpEcho starting...")

    case TcpEcho.WiFi.connect() do
      {:ok, ip_info} ->
        ip = format_ip(extract_ip(ip_info))
        port = 8080
        IO.puts("TCP Echo starting on #{ip}:#{port}")

        {:ok, _pid} = :tcp_server.start_link(
          %{port: port},
          %{chunk_size: 4096},
          TcpEcho.EchoProtocol,
          %{}
        )

        IO.puts("TCP Echo ready at #{ip}:#{port}")
        IO.puts("Run: ./scripts/test.sh #{ip}")
        Process.sleep(:infinity)

      {:error, reason} ->
        IO.puts("ERROR: WiFi failed: #{inspect(reason)}")
        :erlang.halt(1)
    end
  end

  defp extract_ip({ip, _netmask, _gateway}), do: ip
  defp extract_ip(ip), do: ip

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: inspect(ip)
end
```

#### `lib/tcp_echo/echo_protocol.ex` — Echo protocol

```elixir
defmodule TcpEcho.EchoProtocol do
  @behaviour :tcp_server

  @impl true
  def init(_socket, _args) do
    IO.puts("EchoProtocol: new connection")
    {:ok, %{bytes_received: 0}}
  end

  @impl true
  def handle_data(data, state) do
    new_total = state.bytes_received + byte_size(data)
    {:send, data, %{state | bytes_received: new_total}}
  end

  @impl true
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_close(_reason, state) do
    IO.puts("EchoProtocol: connection closed (#{state.bytes_received} bytes total)")
    :ok
  end
end
```

#### `lib/tcp_echo/wifi.ex`

Same as `examples/httpd_debug/lib/httpd_debug/wifi.ex`. Copy verbatim, change
module name to `TcpEcho.WiFi`.

#### `scripts/flash.sh`

Same pattern as httpd_debug. Calls `mix atomvm.esp32.flash`.

#### `scripts/monitor.sh`

Same as httpd_debug. picocom on /dev/ttyACM0.

#### `scripts/test.sh` — Hardware concurrent load test

**Usage**: `./scripts/test.sh <esp32-ip> [port]`

This script tests the TCP echo server running on real ESP32 hardware over the
network. Uses `nc` (netcat) for raw TCP connections and bash background jobs
for concurrency.

**Tests to include:**

```
=== Basic Echo ===
1. Send "hello", verify exact echo
2. Send 1KB, verify exact echo (byte count match)
3. Send/recv 10 sequential messages on one connection

=== Payload Size Sweep ===
4. For SIZE in 100 500 1024 2048 4096 8192 16384 32768 65536:
   - Generate SIZE random bytes
   - Send to server, recv response
   - Verify response size matches
   - Report timing

=== Concurrent Connections ===
5. Open 5 connections simultaneously, each sends "conn-N" and verifies echo
6. Open 5 connections, each sends 4KB, all verify correct echo
7. Open 8 connections (near LWIP_MAX_SOCKETS), all echo concurrently

=== Concurrent Load Under Stress ===
8. One connection sends 64KB (slow/large) while 3 others send 100 bytes each.
   Verify small responses complete quickly (< 1s) even while large transfer
   is in progress. THIS IS THE KEY CONCURRENCY TEST — it would fail with
   the current gen_tcp_server serialized design.

=== Rapid Connect/Disconnect ===
9. 20 rapid sequential connect → send → recv → close cycles
10. Verify server stays healthy after rapid cycling (final echo works)

=== Summary ===
Report pass/fail counts, total time.
```

**Script pattern** (matching httpd_debug/scripts/test.sh style):

```bash
#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <esp32-ip> [port]"
    exit 1
fi

HOST="$1"
PORT="${2:-8080}"
PASSED=0
FAILED=0

inc_passed() { PASSED=$((PASSED + 1)); }
inc_failed() { FAILED=$((FAILED + 1)); }

echo "=== TCP Echo Server - Concurrent Load Test ==="
echo "Target: $HOST:$PORT"

# Helper: send data and verify echo
echo_test() {
    local name="$1"
    local data="$2"
    local expected_size="$3"
    echo -n "Testing: $name ... "
    RESPONSE=$(echo -n "$data" | nc -w 5 "$HOST" "$PORT" 2>/dev/null)
    if [ ${#RESPONSE} -eq "$expected_size" ]; then
        echo "PASS"
        inc_passed
    else
        echo "FAIL (got ${#RESPONSE} bytes, expected $expected_size)"
        inc_failed
    fi
}

# ... (full test sections as described above)
```

**Important**: The concurrent stress test (#8) is the primary validation that
per-connection processes work. With `gen_tcp_server`, the large transfer would
block the small ones. With `tcp_server`, they should run independently.

---

### mix.exs for tcp_echo example

```elixir
defmodule TcpEcho.MixProject do
  use Mix.Project

  def project do
    [
      app: :tcp_echo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      atomvm: [start: TcpEcho, flash_offset: 0x250000]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:atomvm_httpd, path: "../.."},
      {:exatomvm, github: "atomvm/exatomvm", runtime: false}
    ]
  end
end
```

---

## Execution Order (Phase A)

1. Create `src/tcp_server.erl` — listener, acceptor, worker, send helper
2. Create `test/support/test_echo_protocol.ex` — test protocol module
3. Create `test/tcp_server_test.exs` — host-side ExUnit tests
4. Run `mix test test/tcp_server_test.exs` — iterate until green
5. Verify `mix test` (all existing tests still pass — tcp_server is additive)
6. Create `examples/tcp_echo/mix.exs`
7. Create `examples/tcp_echo/lib/tcp_echo.ex`
8. Create `examples/tcp_echo/lib/tcp_echo/echo_protocol.ex`
9. Create `examples/tcp_echo/lib/tcp_echo/wifi.ex` (copy from httpd_debug)
10. Create `examples/tcp_echo/scripts/flash.sh`
11. Create `examples/tcp_echo/scripts/monitor.sh`
12. Create `examples/tcp_echo/scripts/test.sh` — concurrent load test
13. Flash to ESP32, run `test.sh` against real hardware

---

## Risk Areas

### 1. recv + message interleaving

`socket:recv/1` internally suspends in a `receive` block. `check_messages/2`
runs BEFORE each recv to drain pending messages. For long-idle connections, the
protocol layer should use `socket:recv/3` with a timeout to periodically check.

### 2. Acceptor→worker max_connections race

The acceptor becomes the worker before the listener checks `max_connections`.
The listener sends `{tcp_server, close}` if over limit; `check_messages` in the
worker loop catches this before any real work.

### 3. Worker crash cleanup

Listener monitors workers. `{'DOWN', ...}` removes the worker from tracking.
AtomVM's `socket_dtor` handles socket resource cleanup on process termination.

### 4. Acceptor link chain

Acceptors are `spawn_link`ed from the previous acceptor (which becomes a
worker). Need to ensure each acceptor is linked to the listener, not to the
previous worker. The new acceptor should `unlink` from its parent and `link`
to the listener at the start of `accept/5`.

### 5. netcat (`nc`) behavior across platforms

Different `nc` implementations handle EOF and timeouts differently. The test
script should use `nc -w <timeout>` and `-q 0` (or `-N` on BSD nc) to close
the send side after input. Test on the host OS first before running against
hardware.

---

## Phase B: HTTP Migration (future session)

After Phase A is validated on hardware:

1. Refactor `httpd.erl`: change behavior to `tcp_server`, flatten per-connection
   state (no more socket-keyed maps)
2. Adjust WebSocket upgrade path in `httpd_ws_handler.erl`
3. Run existing HTTP + WebSocket test suites
4. Add concurrent HTTP request tests to `httpd_integration_test.exs`
5. Delete `gen_tcp_server.erl`
6. Update `AGENTS.md`

### Callback mapping (httpd)

| gen_tcp_server callback | tcp_server callback | Changes |
|-------------------------|---------------------|---------|
| `init({Options, Config})` | `init(Socket, {Options, Config})` | Receives socket; per-connection state |
| `handle_receive(Socket, Packet, State)` | `handle_data(Data, State)` | No socket arg; no socket-keyed maps |
| `handle_tcp_closed(Socket, State)` | `handle_close(Reason, State)` | Cleanup WS handler if any |
| `handle_info(Msg, State)` | `handle_info(Msg, State)` | Slightly different return types |

### State simplification (httpd)

| Current (shared across all connections) | New (per-connection) |
|-----------------------------------------|----------------------|
| `pending_request_map #{Socket => ...}` | `pending_request` (direct field) |
| `pending_buffer_map #{Socket => ...}` | `buffer` (direct field) |
| `pending_timer_map #{Socket => ...}` | `timer_ref` (direct field) |
| `ws_socket_map #{Socket => ...}` | `ws_handler` (direct field) |
