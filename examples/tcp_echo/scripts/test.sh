#!/bin/bash
#
# TCP Echo Server - Concurrent Load Test (wrapper)
#
# Thin wrapper around load_test.exs, a pure-Elixir/:gen_tcp client. Uses only
# OTP's gen_tcp, so there is no netcat/curl dependency and behaviour is the same
# on every host.
#
# Usage: ./scripts/test.sh <esp32-ip> [port]

if [ -z "$1" ]; then
    echo "Usage: $0 <esp32-ip> [port]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec elixir "$SCRIPT_DIR/load_test.exs" "$@"
