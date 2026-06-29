#!/bin/bash
set -e

echo "=== AtomVM TCP Echo - Flash Script ==="

# Kill any existing serial monitor
echo "Stopping any existing serial monitor..."
pkill -f "picocom.*ttyACM0" 2>/dev/null || true
sleep 1

# Source ESP-IDF environment to get esptool.py
echo "Loading ESP-IDF environment..."
source "$HOME/.espressif/v5.5.4/esp-idf/export.sh" >/dev/null 2>&1

# Navigate to project directory
cd "$(dirname "$0")/.."

# Check for WiFi credentials
if [ -z "$ATOMVM_WIFI_SSID" ]; then
    echo ""
    echo "ERROR: ATOMVM_WIFI_SSID not set"
    echo "Set WiFi credentials before building:"
    echo "  export ATOMVM_WIFI_SSID=\"your-ssid\""
    echo "  export ATOMVM_WIFI_PSK=\"your-password\""
    echo ""
    exit 1
fi

echo "WiFi SSID: $ATOMVM_WIFI_SSID"

# Build and flash
echo "Building and flashing to /dev/ttyACM0..."
mix atomvm.esp32.flash --port /dev/ttyACM0 --baud 921600

echo ""
echo "=== Flash complete ==="
echo "Run './scripts/monitor.sh' to view serial output"
