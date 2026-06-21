#!/bin/bash

echo "=== AtomVM HTTPD Debug - Serial Monitor ==="
echo "Monitoring /dev/ttyACM0 at 115200 baud"
echo "Log file: /tmp/atomvm_serial.log"
echo "Press Ctrl+A then Ctrl+X to exit picocom"
echo ""

# Truncate log file
LOG=/tmp/atomvm_serial.log
> "$LOG"

# Start picocom with tee to log file
picocom -b 115200 /dev/ttyACM0 | tee "$LOG"
