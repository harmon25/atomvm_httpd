# AtomVM HTTPD — Agent Guide

HTTP/WebSocket server **library** for AtomVM (lightweight Erlang VM for
microcontrollers: ESP32, STM32). Implementation is Erlang (`src/`); `lib/` is a
thin Elixir convenience wrapper. Built with Mix.

## Architecture

```
tcp_server.erl      →  httpd.erl            →  Handler modules
(TCP/socket layer)     (HTTP/1.1 parse,         (request processing)
                        routing, send)
```

- **`tcp_server`**: generic per-connection-process TCP server wrapping AtomVM
  `socket`. A listener gen_server owns the listen socket and spawns/monitors one
  worker process per connection; an acceptor process runs a pure `socket:accept`
  loop. Each worker owns its socket for the whole lifecycle: `recv →
  Protocol:handle_data → chunked send`, all in that worker. Connections are
  therefore independent — a large/slow response on one never blocks another.
  Behavior callbacks: `init/2`, `handle_data/2`, `handle_close/2` (optional
  `handle_info/2`, `handle_timeout/1`). See "tcp_server behavior" below.
- **`httpd`**: HTTP/1.1 protocol + path-prefix routing; implements the
  `tcp_server` behavior. State is **per-connection** (no socket-keyed maps): each
  worker holds its own `pending_request`, `buffer`, and `ws` handler pid.
- **Handler behaviors**:
  - `httpd_handler` — low-level HTTP (`init_handler/2`, `handle_http_req/2`)
  - `httpd_api_handler` — REST/JSON (`handle_api_request/4`)
  - `httpd_ws_handler` — WebSocket (`handle_ws_init/3`, `handle_ws_message/2`)

### Handler return values

```erlang
{reply, Headers, Body, State}   %% send response, keep connection open
{close, Headers, Body}          %% send response, then close
{noreply, State}                %% keep accumulating request (streaming)
{error, not_found | bad_request | internal_server_error}
```

### tcp_server behavior

Generic per-connection TCP server. A protocol module implements:

```erlang
init(Socket, Args)        -> {ok, State} | {error, Reason}    %% in the worker
handle_data(Data, State)  -> {send, Resp, State} | {send_close, Resp}
                           | {continue, State} | {close, State} | {error, Reason}
handle_close(Reason, State) -> ok
handle_info(Msg, State)     -> {ok, State} | {send, Resp, State} | {close, State}   %% optional
handle_timeout(State)       -> {continue, State} | {close, State}                   %% optional
```

`handle_timeout/1` fires when a blocking recv hits the `recv_timeout` socket
option (httpd maps `request_timeout` → `recv_timeout` to close stalled
requests). Out-of-band sends from another process go straight to the socket
(`tcp_server:send/3` or `socket:send`), as the WebSocket handler does. See
`examples/tcp_echo/` for a standalone protocol example.

### Path-based routing

First matching prefix wins; the prefix is stripped before reaching the handler.

```erlang
Config = [
  {[<<"api">>], #{handler => httpd_api_handler, handler_config => #{module => MyApi}}},
  {[<<"ws">>],  #{handler => httpd_ws_handler,  handler_config => #{module => MyWs}}},
  {[],          #{handler => httpd_file_handler, handler_config => #{app => my_app}}}
]
```

File handler is the catch-all and must be last.

### API handler example (see `httpd_stats_api_handler.erl`)

```erlang
handle_api_request(get, [<<"endpoint">>], _HttpRequest, _Args) ->
    {ok, #{status => <<"ok">>}};   %% map auto-encoded to JSON
handle_api_request(_M, _P, _R, _A) ->
    not_found.
```

## Commands

- `mix compile` — build (`erlc_paths: ["src"]`).
- `mix test` — full suite, runs on **host Erlang/OTP**, not AtomVM.
- `mix test test/httpd_integration_test.exs:NN` — run a single test.
- `mix format` — Elixir only (`lib`, `test`); does NOT touch Erlang `src/`.
- `mix deps.get` is a no-op here (no deps). The README dep snippet is for *consumers*.
- No CI exists; local `mix test` is the only gate.

## Repo gotchas

- **AtomVM `socket` setopt is an allow-list**: only `{socket, reuseaddr|linger|type}`,
  `{otp, recvbuf}`, `{ip, add_membership}` are supported — **no `{tcp, nodelay}`**.
  `tcp_server:set_socket_options/2` uses strict `ok = socket:setopt(...)`, so an
  unsupported key **crashes the server at startup**.
- **App-level keys are not socket options**: `max_connections`, `chunk_size`, and
  `recv_timeout` ride in the same `SocketOptions` map but are stripped with **nested
  `maps:remove/2`** in `tcp_server:init/1` before the setopt fold. Add any new app-level
  key to that strip chain.
- **AtomVM `maps` has no `maps:without/2`** — using it crashes with `undef` at runtime
  (only surfaces on hardware, not host OTP). Strip keys with chained `maps:remove/2`.
  Likewise **`erlang:halt/1` is not implemented** (use `halt/0` or just idle).
- `socket:send/2` returns `ok | {ok, Rest} | {error, Reason}`. Two backpressure cases must
  both be handled in `tcp_server:do_send/3`:
  - `{ok, Rest}` — explicit partial send; resend the remainder.
  - `{error, Reason}` (commonly `{error, closed}`) — on ESP32 the **small lwIP send buffer**
    (~`4 × TCP_MSS`, a few KB) surfaces backpressure as a *transient error* even though the
    connection is alive. `do_send` **retries the chunk** with a short backoff (bounded by
    `MAX_SEND_RETRIES`) instead of treating it as fatal. Without this, large responses
    (e.g. 64 KB) truncate mid-body a large fraction of the time under concurrency — verified
    on hardware (~65% → ~0% with retry). A genuinely-dead connection keeps failing and is
    given up after the bounded budget.
- Responses are sent in `chunk_size` slices (default 4096; configurable per server). lwIP
  accepts at most `TCP_MSS` (~1440 B) per `socket:send`, so larger chunks just loop internally.
- Never flatten a complete response with `iolist_to_binary/1`. `tcp_server` walks nested
  iodata into chunks bounded by both byte size and entry count, and partial sends retry only
  the unsent part of the current chunk. This is required to avoid response-sized allocations
  and heap fragmentation on memory-constrained devices.
- No `priv/` in this repo; `httpd_file_handler` serves from a *consumer* app's `priv`.

## Testing

- `erlc_options(:test)` injects `{d, TEST}`, enabling `-ifdef(TEST)` internal exports in `httpd.erl`.
- `test/support/*.ex` (e.g. `TestEchoHandler`) compile only in `:test` (`elixirc_paths`).
- Integration tests drive the server over raw `:gen_tcp`; per-test handler config via the
  `handler_config` setup-context key.
- `TestEchoHandler` replies with its configured `:reply_body` (default `"ok"`) — it does NOT
  echo the request body.

## Debugging & tracing

Per-module tracing: uncomment the define *before* the include, then use `?TRACE`.

```erlang
-define(TRACE_ENABLED, true).
-include_lib("atomvm_httpd/include/trace.hrl").
```

Disabled traces compile to `ok`. Keep default log output quiet — gate noise behind `?TRACE`,
not `io:format`.

## AtomVM constraints

- Subset of OTP (no `handle_continue`); no hot code loading (full redeploy required).
- Memory-sensitive: prefer binaries, stream large payloads, avoid the process dictionary.
- Platform modules: `atomvm:platform/0`, `esp:*`, `atomvm:read_priv/2`.

## Conventions

- Active development branch is `improvements` (not `main`); README dep examples pin `main`.
- Erlang `src/` is the source of truth; `lib/atomvm_httpd.ex` is only a convenience wrapper.

## ESP32 Debug Loop (examples/httpd_debug/)

A complete debug/test application for iterating on ESP32 hardware with real-world HTTP loads.

### Setup (one-time)

1. **WiFi credentials** (compile-time):
   ```bash
   export ATOMVM_WIFI_SSID="your-ssid"
   export ATOMVM_WIFI_PSK="your-password"
   ```

2. **ESP32 connection**: Connect ESP32-S3 to `/dev/ttyACM0` (or update scripts if different port).

3. **ESP-IDF environment**: Already available via `get_idf` alias (sources `$HOME/.espressif/v5.5.4/esp-idf/export.sh`). Flash script sources this automatically.

### Iteration cycle

```bash
cd examples/httpd_debug

# 1. Edit code in src/ (library) or lib/ (test app)

# 2. Build and flash (kills existing monitor, builds, flashes to ESP32)
./scripts/flash.sh

# 3. Monitor serial output (logs to /tmp/atomvm_serial.log)
./scripts/monitor.sh
# Watch for: "HTTPD ready at http://X.X.X.X:80"

# 4. Test via browser or automated suite
open http://X.X.X.X/              # Browser dashboard
./scripts/test.sh X.X.X.X         # Automated curl tests

# 5. Check serial log for crashes/errors
grep -i "error\|crash\|abort" /tmp/atomvm_serial.log

# 6. Fix and repeat
```

### What's included

- **Debug API endpoints** (`/api/ping`, `/api/echo`, `/api/generate?size=N`, `/api/memory`):
  Stress-test request/response sizes up to 1MB. Every request logs heap state to serial.
- **Built-in stats** (`/api/stats/system`, `/api/stats/memory`): Platform info + ESP32 heap.
- **Command API** (`/api/cmd/restart`): Restart ESP32 over HTTP.
- **Browser dashboard** (`/`): Interactive UI for triggering tests, viewing results, monitoring memory.
- **Automated test suite** (`scripts/test.sh`): Sweeps response sizes (100B → 64KB) and upload sizes (100B → 16KB), reports pass/fail + timing.
- **Endurance/soak test** (`scripts/soak.sh <ip> [-d secs] [-c workers] [-o dir]`): Runs a
  mixed request load (ping/generate/echo) with N concurrent workers for an extended
  duration (default 1h), sampling device heap every interval to catch leaks/fragmentation,
  and aborting on a run of consecutive failures (crash/hang) or sustained unreachability.
  Writes a persistent run dir with `samples.csv` (time-series), `soak.log`, `failures.log`,
  a live `status` heartbeat, and `summary.txt`. Built for unattended multi-hour/day runs
  (`nohup`/`tmux`). Validates **complete** response bodies, so truncated/partial sends are
  counted as failures.
- **Soak analyzer** (`scripts/soak_analyze.sh <run-dir-or-csv>`): Post-processes a run's
  `samples.csv` into a verdict — fail rate, throughput, heap **leak estimate** (linear
  regression slope in B/hour), fragmentation %, low-water, and the worst failure intervals.
- **Full soak docs**: `examples/httpd_debug/SOAK.md` (running long runs, watching live,
  interpreting leak/fragmentation/failure signals, plotting).

### Tuning parameters

- **`chunk_size`** (default 4096): Set in `lib/httpd_debug.ex` line 13. AtomVM lwIP default send buffer is 8KB; values up to 8192 are safe.
- **Request timeout** (default 30s): Set via `:httpd.start_link/5` options map (not currently exposed in debug app, but easy to add).

### AI agent workflow

When debugging performance issues or crashes on hardware:

1. **Flash**: `bash examples/httpd_debug/scripts/flash.sh` (Read tool to check output)
2. **Monitor**: `bash examples/httpd_debug/scripts/monitor.sh` in background, or Read `/tmp/atomvm_serial.log`
3. **Extract IP**: Grep serial log for `"HTTPD ready at http://"`
4. **Test**: `bash examples/httpd_debug/scripts/test.sh <ip>` or individual curl commands
5. **Analyze**: Read serial log for crash traces (Guru Meditation, stack dumps), parse test failures
6. **Edit**: Make fixes in `src/` (library code) or `examples/httpd_debug/lib/` (test app)
7. **Iterate**: Return to step 1

Serial log persists at `/tmp/atomvm_serial.log` across monitor restarts for post-mortem analysis.
