# Endurance / Soak Testing

Long-duration stability testing for `atomvm_httpd` on real ESP32 hardware.
The soak harness drives a continuous mixed HTTP load while sampling the device
heap, so you can catch **memory leaks, heap fragmentation, throughput
regressions, and crashes/hangs** that only appear over hours or days.

Scripts (in `scripts/`):

| Script             | Purpose                                              |
|--------------------|------------------------------------------------------|
| `soak.sh`          | Run the load + sample heap, emit a CSV time-series   |
| `soak_analyze.sh`  | Post-process a run's `samples.csv` into a verdict     |

## Prerequisites

1. The `httpd_debug` app flashed and running (it provides `/api/ping`,
   `/api/generate`, `/api/echo`, `/api/memory`):
   ```bash
   ./scripts/flash.sh
   ```
2. The device on the network. Grab its IP from the serial log
   (`HTTPD ready at http://<ip>:80`).
3. `curl` on the host. `awk` is used by the analyzer (preinstalled on
   Linux/macOS). `gnuplot` is optional, only for plotting.

> The debug app self-heals across WiFi drops (it retries association and never
> halts), so a transient AP blip during a multi-day run will not end the test —
> the soak harness rides through brief unreachable windows and only aborts on a
> *sustained* outage.

## Running a soak

```bash
# 1 hour, 4 concurrent workers (defaults)
./scripts/soak.sh 192.168.1.100

# 8-hour overnight run, 8 workers, sample every 60s
./scripts/soak.sh 192.168.1.100 -d 28800 -c 8 -s 60

# 3-day unattended run, results to a chosen dir
nohup ./scripts/soak.sh 192.168.1.100 -d 259200 -o ~/soak-3day \
      > ~/soak-3day.console.log 2>&1 &
```

### Options

| Flag                  | Default                        | Meaning                                   |
|-----------------------|--------------------------------|-------------------------------------------|
| `-d, --duration`      | `3600` (1h)                    | Total run time, seconds                   |
| `-c, --concurrency`   | `4`                            | Parallel request workers                  |
| `-s, --sample`        | `30`                           | Heap-sample / report interval, seconds    |
| `-t, --timeout`       | `15`                           | Per-request curl timeout, seconds         |
| `--max-fails`         | `50`                           | Abort after N consecutive request failures (crash/hang detector) |
| `--max-unreachable`   | `10`                           | Abort after N consecutive unreachable heap samples (device down) |
| `-o, --out`           | `/tmp/atomvm_soak/<timestamp>` | Output directory                          |

The load mix per request is random: ~25% ping, ~50% response generation
(128 B – 64 KB), ~25% uploads (128 B – 16 KB). Each response is validated for a
**complete** body (curl fails on a short read because the server always sends
`Content-Length`), so truncated/partial responses are counted as failures.

### Running unattended (hours/days)

For long runs, detach the process so it survives your shell closing:

```bash
# Option A: nohup + background
nohup ./scripts/soak.sh <ip> -d 86400 -o ~/soak-day >/dev/null 2>&1 &

# Option B: tmux/screen (lets you re-attach to watch live)
tmux new -s soak './scripts/soak.sh <ip> -d 86400 -o ~/soak-day'
#   detach: Ctrl-b d   reattach: tmux attach -t soak
```

Pick a sample interval that keeps the CSV manageable: at `-s 30` a 3-day run
produces ~8,600 rows (tiny). Higher concurrency = higher req/s = more stress but
also more host CPU; 4–8 workers is plenty to saturate a single ESP32.

## Watching a run in progress

Every interval the harness rewrites a `status` heartbeat and appends to the CSV:

```bash
# Live one-line status (updated each interval)
watch -n5 cat ~/soak-3day/status

# Follow the time-series as it grows
tail -f ~/soak-3day/samples.csv

# Follow notable events (warnings, aborts, WiFi blips)
tail -f ~/soak-3day/soak.log
```

`status` looks like:

```
run_id=20260627-141500 host=192.168.1.100 pid=12345
updated=2026-06-27 15:10:00 elapsed=3300s of 86400s
reqs=6021 ok=6019 fail=2 rps=2
free_heap=8503112 min_free=8264472 d_free=-1880 low_water=8358004
consec_req_fails=0 consec_unreachable=0
```

## Output files

All under the run's output directory (`-o`, or `/tmp/atomvm_soak/<timestamp>`):

| File           | Contents                                                     |
|----------------|--------------------------------------------------------------|
| `samples.csv`  | One row per interval — the primary analysis artifact         |
| `soak.log`     | Timestamped events: start, warnings, aborts                  |
| `failures.log` | Per-interval failure counts (only intervals with failures)   |
| `status`       | Single-line heartbeat, overwritten each interval             |
| `summary.txt`  | Final summary (also printed to stdout at the end)            |
| `results`      | Raw per-request stream (`.` = ok, `F` = fail)                |

### `samples.csv` columns

```
timestamp, elapsed_s, total_reqs, ok, fail, interval_reqs, rps,
free_heap, largest_block, min_free, d_free_vs_baseline
```

- **free_heap** — current free heap (`esp32_free_heap_size`). The leak signal.
- **largest_block** — largest contiguous free block. Fragmentation signal: if
  this falls much faster than `free_heap`, the heap is fragmenting.
- **min_free** — lowest free heap ever seen by the device (`esp32_minimum_free_size`).
- **d_free_vs_baseline** — `free_heap` minus the baseline taken at startup.

## Analyzing results

Run the analyzer on the run directory (or the CSV directly):

```bash
./scripts/soak_analyze.sh ~/soak-3day
# or
./scripts/soak_analyze.sh ~/soak-3day/samples.csv
```

It reports:

```
Duration sampled, total requests, fail rate, throughput
Heap free: start / end / low-water, net change
  trend (regress): <bytes/hour>   <-- leak verdict from linear regression
Largest free block: end / min-seen, fragmentation %
Worst failure intervals (top 10)
```

### Interpreting the verdict

- **Leak.** The analyzer fits a line to `free_heap` vs time. A sustained
  negative slope is the key signal:
  - `> -64 B/hour` → **flat**, no leak.
  - `-64 … -1024 B/hour` → slight drift; confirm with a longer run (noise from
    request-in-flight buffers can masquerade as a tiny slope).
  - `< -1024 B/hour` → **leak suspected**. Extrapolate: `free_heap / leak_rate`
    ≈ time to exhaustion. Correlate the slope's onset with the load mix.
  - A *flat* trend with a low **low-water** mark is normal — peak concurrent
    request buffers transiently dip free heap; what matters is that it recovers.
- **Fragmentation.** Compare `largest_block` to `free_heap`. If plenty of heap
  is free but `largest_block` keeps shrinking, large responses will start
  failing with allocation errors even though total free looks healthy. The
  analyzer prints a fragmentation % at the heap low point; `> 50%` warrants
  attention.
- **Failures.** Any nonzero `fail` count: open `failures.log` to see *when* they
  clustered, then cross-reference `soak.log` (WiFi blips) and the device serial
  log for the same wall-clock time. A handful of failures spread evenly under
  heavy large-response load points at the send path; a burst at one timestamp
  usually means a WiFi reconnect or a device reset.
- **Crash / hang.** An `ABORTED` result means either `--max-fails` consecutive
  request failures or `--max-unreachable` consecutive dead heap probes. Check
  the device serial log (`/tmp/atomvm_serial.log`) for a crash dump at the abort
  timestamp.

### Plotting (optional)

```bash
# free_heap over time
gnuplot -p -e "set datafile separator ','; \
  set xlabel 'elapsed_s'; set ylabel 'free_heap'; \
  plot '~/soak-3day/samples.csv' using 2:8 with lines title 'free_heap'"

# free_heap vs largest_block (fragmentation)
gnuplot -p -e "set datafile separator ','; set xlabel 'elapsed_s'; \
  plot '~/soak-3day/samples.csv' using 2:8 with lines title 'free', \
       '' using 2:9 with lines title 'largest_block'"
```

## Recommended progression

1. **Smoke (2 min):** `./scripts/soak.sh <ip> -d 120 -c 3` — verify wiring,
   confirm the harness reports and the device is healthy.
2. **Short (1 h):** defaults — establish a baseline heap trend and fail rate.
3. **Overnight (8 h):** `-d 28800` — catch slow leaks / fragmentation.
4. **Endurance (1–3 days):** `-d 86400`/`259200` under `nohup`/`tmux` — prove
   stability and recovery across real WiFi events.

After each, run `soak_analyze.sh` and compare the leak trend and fail rate to
the previous tier.
