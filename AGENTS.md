# AtomVM HTTPD — Agent Guide

HTTP/WebSocket server **library** for AtomVM (lightweight Erlang VM for
microcontrollers: ESP32, STM32). Implementation is Erlang (`src/`); `lib/` is a
thin Elixir convenience wrapper. Built with Mix.

## Architecture

```
gen_tcp_server.erl  →  httpd.erl            →  Handler modules
(TCP/socket layer)     (HTTP/1.1 parse,         (request processing)
                        routing, send)
```

- **`gen_tcp_server`**: generic TCP server behavior wrapping AtomVM `socket`.
  Implementers provide `init/1`, `handle_receive/3`, `handle_tcp_closed/2`
  (optional `handle_info/2`). A single gen_server owns the listen socket AND all
  handler state; per-connection processes only own `recv` and forward data to it.
  Parsing, dispatch, and the chunked `send` all run in that one gen_server — so
  responses are serialized across connections (known throughput bottleneck for
  large/parallel responses).
- **`httpd`**: HTTP/1.1 protocol + path-prefix routing; implements the
  `gen_tcp_server` behavior.
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
  `gen_tcp_server:set_socket_options/2` uses strict `ok = socket:setopt(...)`, so an
  unsupported key **crashes the server at startup**.
- **App-level keys are not socket options**: `max_connections` and `chunk_size` ride in
  the same `SocketOptions` map but are stripped via `maps:without/2` in `init/1` before the
  setopt fold. Add any new app-level key to that strip list.
- `socket:send/2` returns `ok | {ok, Rest} | {error, Reason}`; partial sends must be retried
  (see `try_send_binary/3`).
- Responses are sent in `chunk_size` slices (default 4096; configurable per server).
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
