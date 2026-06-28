# AtomVM HTTPD Debug Example

Complete debug/test application for iterating on ESP32 hardware with real-world HTTP loads.

## Features

- **WiFi STA connectivity** with compile-time credential injection; self-healing
  (retries association and never halts, so it survives AP outages during long runs)
- **Debug API endpoints** for stress-testing various request/response sizes
- **Built-in stats handlers** for system info and memory monitoring
- **Browser test dashboard** with interactive controls
- **Automated test suite** with curl-based size sweeps
- **Endurance/soak harness** (`scripts/soak.sh` + `scripts/soak_analyze.sh`) for
  unattended multi-hour/day stability runs — see [SOAK.md](./SOAK.md)
- **Serial monitoring** with persistent logs for debugging

## Prerequisites

1. **ESP32 with AtomVM base firmware flashed**
2. **ESP-IDF environment** (available via `get_idf` alias)
3. **WiFi network** (2.4 GHz for ESP32 compatibility)

## Quick Start

### 1. Set WiFi credentials

```bash
export ATOMVM_WIFI_SSID="your-ssid"
export ATOMVM_WIFI_PSK="your-password"
```

### 2. Build and flash

```bash
cd examples/httpd_debug
./scripts/flash.sh
```

The script will:
- Source ESP-IDF environment (for esptool.py)
- Kill any existing serial monitor
- Build the application with ExAtomVM
- Flash to `/dev/ttyACM0` at 921600 baud

### 3. Monitor serial output

```bash
./scripts/monitor.sh
```

Watch for the line:
```
HTTPD ready at http://192.168.1.XXX:80
```

Press `Ctrl+A` then `Ctrl+X` to exit picocom.

Serial output is also logged to `/tmp/atomvm_serial.log` for later analysis.

### 4. Test the server

**Option A: Browser dashboard**
```bash
open http://192.168.1.XXX/
```

The dashboard provides:
- Response size test (100B to 64KB)
- Upload test (100B to 16KB)
- Memory monitor
- System info display
- Live console log

**Option B: Automated test suite**
```bash
./scripts/test.sh 192.168.1.XXX
```

Runs a comprehensive test suite:
- Connectivity (ping)
- Response generation (100B → 64KB)
- Upload echo (100B → 16KB)
- Stats endpoints validation

## API Endpoints

### Debug Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/ping` | GET | Minimal response, baseline test |
| `/api/echo` | POST | Echoes back request body size + preview |
| `/api/generate?size=N` | GET | Generates N bytes of data (up to 1MB) |
| `/api/memory` | GET | Quick memory snapshot |

### Built-in Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/stats/system` | GET | Platform, AtomVM version, chip info |
| `/api/stats/memory` | GET | ESP32 heap stats (free, largest block, min free) |
| `/api/cmd/restart` | POST | Restart ESP32 (3 second delay) |
| `/` | GET | Browser test dashboard |

## Development Workflow

### Typical iteration cycle

```bash
# 1. Edit code in ../../src/ (library) or ./lib/ (test app)
vim ../../src/httpd.erl

# 2. Flash changes
./scripts/flash.sh

# 3. Monitor in background or separate terminal
./scripts/monitor.sh &

# 4. Wait for IP, then test
./scripts/test.sh 192.168.1.XXX

# 5. Check for errors in serial log
grep -i "error\|crash" /tmp/atomvm_serial.log
```

### Debugging crashes

If the ESP32 crashes (Guru Meditation), the stack trace is in `/tmp/atomvm_serial.log`:

```bash
# Show crash details
grep -A 20 "Guru Meditation" /tmp/atomvm_serial.log

# Show all errors
grep -i "error\|abort\|panic" /tmp/atomvm_serial.log
```

## Configuration

### WiFi

WiFi credentials are **compile-time** values (baked into the BEAM bytecode).

To change WiFi:
```bash
export ATOMVM_WIFI_SSID="new-ssid"
export ATOMVM_WIFI_PSK="new-password"
./scripts/flash.sh
```

### Tuning

**chunk_size** (default 4096): Edit the `@chunk_size` attribute in `lib/httpd_debug.ex`:
```elixir
@chunk_size 4096  # or another value
```

ESP32's lwIP send buffer is small (a few KB, ~`4 × TCP_MSS`), and lwIP accepts at
most `TCP_MSS` (~1440 B) per `socket:send`, so a larger `chunk_size` just loops
internally. The library's `tcp_server:do_send/3` retries on send-buffer
backpressure, so large responses complete reliably regardless; 2048–4096 is a
sensible range.

**request_timeout** (default 30s): Modify `start_httpd/0` to use `:httpd.start_link/5`:
```elixir
options = %{request_timeout: 60_000}  # 60 seconds
:httpd.start_link(:any, port, socket_options, options, config)
```

## Serial Port

Default: `/dev/ttyACM0` (ESP32-S3 native USB)

If your ESP32 uses a different port (e.g., `/dev/ttyUSB0` for CP2102/CH340):
1. Edit `scripts/flash.sh` line 29: `--port /dev/ttyUSB0`
2. Edit `scripts/monitor.sh` line 11: `/dev/ttyUSB0`

## Troubleshooting

### Flash script fails with "esptool.py: command not found"

The `get_idf` alias may not be configured correctly. Check:
```bash
type get_idf
# Should show: get_idf is aliased to `. $HOME/.espressif/v5.5.4/esp-idf/export.sh'
```

If missing, add to `~/.bashrc`:
```bash
alias get_idf='. $HOME/.espressif/v5.5.4/esp-idf/export.sh'
```

### "ATOMVM_WIFI_SSID not set" error

You must export WiFi credentials **before** running `flash.sh`. They are compiled into the firmware.

### Monitor shows garbage characters

Wrong baud rate. The monitor uses 115200; if AtomVM is configured differently, update `scripts/monitor.sh` line 11.

### Tests fail with "Connection refused"

1. Check serial log for the actual IP address
2. Verify ESP32 and your computer are on the same network
3. Try pinging the ESP32: `ping 192.168.1.XXX`

### Large response tests fail (truncated bodies)

Large concurrent responses (e.g. 64 KB) truncating mid-body used to be common —
the root cause was lwIP send-buffer backpressure being treated as a fatal error.
`tcp_server:do_send/3` now retries on backpressure, which eliminates the vast
majority of these (verified ~65% → ~0% on a single 64 KB response). If you still
see truncations:
1. Confirm you're on a build that includes the `do_send` retry (current `src/`).
2. Check `/api/memory` — a healthy heap with truncation points to lwIP buffer
   pressure under very high concurrency (run the soak to characterize it).
3. Serial log for crash traces or OOM errors.

## Files

```
examples/httpd_debug/
├── mix.exs                                 # ExAtomVM project config
├── SOAK.md                                 # Endurance/soak testing guide
├── lib/
│   ├── httpd_debug.ex                      # Entrypoint: WiFi + HTTPD, self-healing retry loop
│   └── httpd_debug/
│       ├── wifi.ex                         # WiFi STA (patient connect, no halt-on-failure)
│       └── debug_api_handler.ex            # Debug/test API endpoints
├── priv/
│   └── index.html                          # Browser test dashboard
└── scripts/
    ├── flash.sh                            # Build and flash to ESP32
    ├── monitor.sh                          # Serial monitor with logging
    ├── test.sh                             # Automated curl test suite (size sweeps)
    ├── soak.sh                             # Unattended endurance/soak runner (CSV + heap sampling)
    └── soak_analyze.sh                     # Post-process a soak run into a leak/fail verdict
```

## License

Same as atomvm_httpd (Apache-2.0 OR LGPL-2.1-or-later).
