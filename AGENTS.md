# AI Agent Reference for AtomVM HTTPD

This project is an HTTP server library for **AtomVM** - a lightweight Erlang/Elixir virtual machine designed for microcontrollers and embedded systems.

## What is AtomVM?

AtomVM is a tiny Erlang VM that runs on resource-constrained devices like ESP32, STM32, and other microcontrollers. It allows you to write Erlang and Elixir code for embedded systems.

- **GitHub**: https://github.com/atomvm/AtomVM
- **Documentation**: https://www.atomvm.net/doc/master/
- **Programming Guide**: https://www.atomvm.net/doc/master/programmers-guide.html

## Key Differences from Standard Erlang/OTP

When working on this codebase, keep in mind:

1. **Limited OTP Support**: AtomVM implements a subset of OTP. Not all standard library modules are available.

2. **No `gen_server` callbacks with `handle_continue`**: Some newer OTP features may not be implemented.

3. **Memory Constraints**: Code should be memory-efficient. Avoid large data structures and prefer streaming/chunked processing.

4. **No Hot Code Loading**: Unlike standard Erlang, AtomVM doesn't support hot code swapping.

5. **Limited Process Dictionary**: Use sparingly if at all.

6. **Binary Handling**: Binaries are well-supported and preferred for string/data handling.

## AtomVM-Specific Modules

AtomVM provides platform-specific modules:

- `atomvm:platform/0` - Returns the current platform (e.g., `esp32`, `stm32`, `generic_unix`)
- `esp:*` - ESP32-specific functions (GPIO, WiFi, etc.)
- `network:*` - Network configuration for embedded platforms

## Project Structure

- `src/` - Erlang source files (.erl)
- `lib/` - Elixir source files (.ex)
- `include/` - Header files (.hrl)
- `priv/` - Static assets and resources
- `test/` - Test files

## Building

This is a mixed Erlang/Elixir project using Mix:

```bash
mix deps.get
mix compile
```

For deploying to ESP32, you'll need to create an AVM file and flash it.

## Useful Tips

1. **Debugging**: Use `io:format/2` or `erlang:display/1` for debugging - standard Erlang debugger is not available.

2. **Testing Locally**: Tests run on the host machine using standard Erlang VM, not AtomVM itself.

3. **Handler Pattern**: This httpd uses a handler-based architecture. Each `*_handler.erl` module handles specific route patterns.

4. **WebSocket Support**: `httpd_ws_handler.erl` provides WebSocket functionality.

5. **API Handlers**: Files ending in `_api_handler.erl` are REST API endpoints.

## Common Patterns in This Codebase

### Handler Behavior

Handlers implement callbacks for HTTP request processing. Check `httpd_handler.erl` for the behavior definition.

### TCP Server

`gen_tcp_server.erl` provides the underlying TCP socket management.

## References

- [AtomVM GitHub](https://github.com/atomvm/AtomVM)
- [AtomVM Docs](https://www.atomvm.net/doc/master/)
- [ESP32 Platform Notes](https://www.atomvm.net/doc/master/build-instructions.html#esp32)
- [Erlang Compatibility](https://www.atomvm.net/doc/master/programmers-guide.html#erlang-compatibility)
