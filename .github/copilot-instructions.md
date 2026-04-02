# AtomVM HTTPD - AI Coding Guide

## Project Overview

HTTP server library for **AtomVM** - a lightweight Erlang VM for microcontrollers (ESP32, STM32). Mixed Erlang/Elixir codebase using Mix build system.

## Architecture

### Core Components
```
gen_tcp_server.erl → httpd.erl → Handler Modules
     (TCP layer)     (HTTP parsing,   (Request processing)
                      routing)
```

- **`gen_tcp_server`**: Generic TCP server behavior wrapping socket operations. Handlers implement `init/1`, `handle_receive/3`, `handle_tcp_closed/2`.
- **`httpd`**: HTTP 1.1 protocol implementation. Routes requests to handlers based on path prefix matching. Implements `gen_tcp_server` behavior.
- **Handler behaviors**: Three handler types for different use cases:
  - `httpd_handler` - Low-level HTTP request handling
  - `httpd_api_handler` - REST APIs with JSON encoding (implement `handle_api_request/4`)
  - `httpd_ws_handler` - WebSocket communication (implement `handle_ws_init/3`, `handle_ws_message/2`)

### Handler Return Values
Handlers return tuples indicating response behavior:
```erlang
{reply, Headers, Body, State}   %% Send response, keep connection
{close, Headers, Body}          %% Send response, close connection
{noreply, State}                %% Continue accumulating request (streaming)
{error, not_found | bad_request | internal_server_error}
```

## Key Patterns

### Path-Based Routing
Configuration maps URL path prefixes to handler modules:
```erlang
Config = [
    {[<<"api">>], #{handler => httpd_api_handler, handler_config => #{module => MyApi}}},
    {[<<"ws">>], #{handler => httpd_ws_handler, handler_config => #{module => MyWs}}},
    {[], #{handler => httpd_file_handler, handler_config => #{app => my_app}}}
]
```
The first matching prefix wins. Path prefix is stripped before passing to handler.

### Creating API Handlers
Implement `httpd_api_handler` behavior - see `httpd_stats_api_handler.erl`:
```erlang
-behavior(httpd_api_handler).
-export([handle_api_request/4]).

handle_api_request(get, [<<"endpoint">>], HttpRequest, Args) ->
    {ok, #{status => <<"ok">>}};  %% Auto-encoded to JSON
handle_api_request(_Method, _Path, _HttpRequest, _Args) ->
    not_found.
```

### Tracing/Debugging
Enable per-module tracing by uncommenting the define before the include:
```erlang
-define(TRACE_ENABLED, true).
-include_lib("atomvm_httpd/include/trace.hrl").
```
Use `?TRACE("format ~p", [args])` macro. Disabled traces compile to `ok`.

## AtomVM Constraints

- **No hot code loading** - full redeploy required
- **Limited OTP** - subset of standard library; no `handle_continue`
- **Memory-sensitive** - prefer binaries, avoid large data structures, use streaming for big payloads
- **Platform modules**: `atomvm:platform/0`, `esp:*`, `atomvm:read_priv/2` for embedded resources

## Development Commands

```bash
mix deps.get          # Fetch dependencies
mix compile           # Build (uses erlc_paths: ["src"])
mix test              # Run tests (on host Erlang VM, not AtomVM)
```

Tests run on standard Erlang VM. The `-ifdef(TEST)` guard exposes internal functions for testing.

## Testing Patterns
Tests use ExUnit. See `test/httpd_integration_test.exs` for socket-level testing:
- Create test handlers in `test/support/` (added to elixirc_paths in test env)
- Use `@tag handler_config: %{...}` to customize handler per-test
- Start server with `:httpd.start_link(port, config)`, test via `:gen_tcp`

## File Organization

| Directory | Purpose |
|-----------|---------|
| `src/*.erl` | Erlang source - handlers and core modules |
| `lib/*.ex` | Elixir source (thin wrapper) |
| `include/*.hrl` | Header files - HTTP codes, trace macros |
| `priv/` | Static assets (served via `httpd_file_handler`) |
| `test/support/` | Test-only modules |
| `erlang_example` | Erlang example implementation |
