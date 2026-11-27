# ESP32-C3 vs ESP32-S3 Hardware Benchmarks

Measured behaviour of `atomvm_httpd` on two real ESP32 parts: the single-core
**ESP32-C3** (no PSRAM) and the dual-core **ESP32-S3** (8 MB physical PSRAM, but
running a firmware build that does not mount it). The numbers below come from
`scripts/test.sh`, manual concurrent `curl` matrices, and `scripts/soak.sh` runs,
all against the `httpd_debug` app.

Every figure here is an observed measurement, not an estimate. Where a board
crashed, the exact allocation failure and panic type are quoted from the serial
log.

## Hardware & firmware profiles

| Item | ESP32-C3 | ESP32-S3 |
|------|----------|----------|
| Package / revision | QFN32, rev v0.4 | QFN56, rev v0.2 |
| CPU | 1× RISC-V @ 160 MHz | 2× Xtensa @ 160 MHz |
| Flash | 4 MB | 8 MB physical |
| PSRAM | none | 8 MB physical embedded PSRAM (see note) |
| Boot dynamic RAM | ~247 KiB (`121+113+10+3` KiB) | ~317 KiB internal SRAM (`257+21+32+7` KiB) |
| Free heap after WiFi + HTTPD boot | `104,820–110,688 B` | `157,364–163,340 B` |
| Largest free block after boot | `~94,208 B` | `112,640–122,880 B` |
| WiFi RSSI | `-78 dBm` | `-72 to -75 dBm` |

Common to both:

- **Software:** `atomvm_httpd` (`optimizations` branch), `examples/httpd_debug`
  app, AtomVM `0.7.0-beta.1+git.dd3d0ea`, ESP-IDF `v5.5.5`.
- **Network:** WiFi STA (`WPA2-PSK`), AP on channel 1.
- **Transport:** HTTP/1.1 keep-alive, `chunk_size` default (4096).

### Important firmware observation on the S3

The flashed AtomVM `0.7.0-beta.1` binary was built with a **4 MB flash header**
and **did not mount PSRAM** — the boot log shows no `esp_psram` / `spiram`
initialization. As a result the board ran entirely out of ~317 KiB of internal
SRAM with `157,364–163,340 B` free after boot, i.e. a "large internal SRAM"
board rather than an 8 MB PSRAM board. This single fact explains most of the S3
results below: roughly 50 % more headroom than the C3, which raises the
concurrent ceiling — but nowhere near PSRAM-sized capacity. A build with
`CONFIG_SPIRAM=y` would change these ceilings substantially.

## Sequential & functional baseline (`scripts/test.sh`)

Both boards, same suite, keep-alive connections, static dashboard included:

- **20/20 PASS** on `scripts/test.sh` for both C3 and S3.
- HTTP/1.1 **keep-alive connection reuse**: PASS (both).
- `Connection: close` handling: PASS (both).
- Static `GET /` (`11,469 B` dashboard): PASS (both).

### Sequential GET `/api/generate` latency

ESP32-C3 (selected sizes measured):

| Response size | Latency |
|---------------|---------|
| 16 KB | ~1.6 s |
| 32 KB | ~2.5 s |
| 64 KB | ~4.8 s |

ESP32-S3 (full sweep):

| Response size | Latency |
|---------------|---------|
| 100 B | 149 ms |
| 500 B | 204 ms |
| 1 KB | 268 ms |
| 2 KB | 441 ms |
| 4 KB | 700 ms |
| 8 KB | 1311 ms |
| 16 KB | 2459 ms |
| 32 KB | 4753 ms |
| 64 KB | 9348 ms |

The S3's *single-stream* throughput was worse than the C3's at equal payload
sizes despite the extra SRAM. Its WiFi link was weaker/noisier (`RSSI -72..-75
dBm`, versus a steadier `-78 dBm` on the C3), and single-stream latency is
dominated by per-chunk send/ACK turnaround, so link conditions very likely
account for most of the gap. Do not read these sequential numbers as a CPU
comparison.

### Sequential POST `/api/echo` (S3)

| Upload size | Latency |
|-------------|---------|
| 100 B | 153 ms |
| 16 KB | 489 ms |

## Concurrent stress matrix (fresh firmware)

Each cell is a burst of simultaneous requests issued after a clean boot, with
the pass count and the observed timing/crash.

| Workload | ESP32-C3 | ESP32-S3 |
|----------|----------|----------|
| `6× 8 KB GET` + 1 concurrent `/api/ping` | **7/7 PASS** | **7/7 PASS** (8 KB: `3.20–5.51 s`; concurrent `/api/ping`: **248 ms**) |
| `4× 16 KB GET` | **4/4 PASS** (isolated) | **4/4 PASS** (`5.93–6.39 s`) |
| `2× 32 KB GET` | **Flaky** — intermittent `out_of_memory` crash/reboot (`min_free` ~3.8–4.6 KB) | **2/2 PASS** (`5.87–5.89 s`) |
| `6× 64 KB GET` + ping + memory | **0/8 FAIL** — OOM panic | **0/8 FAIL** — `memory_create_refc_binary: Unable to allocate 65536 bytes` → `StoreProhibited` panic |
| `4× 4 KB POST /api/echo` | **4/4 PASS** | **4/4 PASS** (`0.58–0.74 s`; `0.744 s` wall) |
| `4× 16 KB POST /api/echo` | — | **0/4 FAIL** — `memory_create_refc_binary: Unable to allocate 16384 bytes` → `StoreProhibited` panic |

The `6× 8 KB GET` row is the clearest demonstration of the per-connection worker
design: while six 8 KB responses were still streaming (`3.20–5.51 s`), a seventh
`/api/ping` connection on the S3 answered in **248 ms**. A slow/large response
does not block other connections.

The `6× 64 KB` row also shows the hard limit of a no-PSRAM build on the S3: six
simultaneous 64 KB buffers cannot fit in ~158 KB of internal SRAM even with the
extra headroom, so it fails the same way the C3 does (just at a larger
concurrency ceiling).

## Mixed-workload soak results (`scripts/soak.sh`)

Random mixed load (~25 % ping, ~50 % generate, ~25 % echo) per the harness, heap
sampled every interval. Fail counts are complete-body validated by `curl`.

### 30 s, `-c 4`, `--max-size 8192`

| Metric | ESP32-C3 | ESP32-S3 |
|--------|----------|----------|
| Requests OK | **144/144 (0.000 % fail)** | **117/117 (0.000 % fail)** |
| Throughput | 4.4 req/s | 3.4 req/s |
| Heap start → end | `104,864 B → 103,988 B` (`-876 B`) | `158,200 B → 157,144 B` (`-1,056 B`) |
| Low-water heap | `76,164 B` | `133,568 B` (`min_free 103,404 B`) |
| Fragmentation | 24.7 % | — |
| Serial errors | 0 | 0 |

### 30 s, `-c 4`, `--max-size 16384`

| Metric | ESP32-C3 | ESP32-S3 |
|--------|----------|----------|
| Requests OK | **54/66 (18.2 % fail)** | **74/74 (0.000 % fail)** |
| Throughput | — | 2.2 req/s |
| Heap start → end | — | `158,164 B → 157,180 B` (`-984 B`) |
| Low-water heap | — | `107,180 B` (`min_free 75,332 B`) |
| Peak fragmentation | — | 58.0 % |
| Serial errors | 2 `Guru Meditation` OOM panics (`Unable to allocate 16384 bytes`) | 0 |

### 60 s, `-c 6`, `--max-size 65536` (harness default)

| Metric | ESP32-C3 | ESP32-S3 |
|--------|----------|----------|
| Requests OK | **58/88 (34.1 % fail)** | **8/37 (78.4 % fail)** |
| Serial errors | 8 `Guru Meditation` OOM panics (an earlier run: 6/30 OK = 80 % fail) | 2 `Guru Meditation` OOM panics on 65,536-byte `refc_binary` |

At the default 64 KB ceiling **both** boards are far beyond their no-PSRAM
limits and both hit `Guru Meditation` OOM panics on the 65,536-byte
`refc_binary` allocation. The percentages above therefore do **not** rank the two
boards by capability: a failed allocation is not catchable in Erlang, the board
reboots and re-joins WiFi, and the harness spends that downtime either not
issuing requests or having them fail outright. The reported fail rate reflects
how much of the soak window each board spent in reboot/WiFi-rejoin downtime (and
how many requests the harness managed to attempt at all — 88 on the C3 vs. 37 on
the S3), not sustainable concurrent capacity. Neither board can serve this
workload; they differ only in how the crash timing shifts the ratio.

## Analysis & practical takeaways

### Zero memory leaks in atomvm_httpd

Across every crash-free soak on both boards, the net heap change stayed within
~1 KB (`-876 B` to `-1,056 B`) and recovered cleanly after the load stopped.
There is no leak signal in the library's request path — the low-water dips are
transient in-flight buffers, not retained memory.

### Why the S3 behaved like a larger-SRAM board, not an 8 MB PSRAM board

The flashed AtomVM image lacked `CONFIG_SPIRAM=y` and carried a 4 MB flash
header, so the S3 ran on ~158 KB of free internal SRAM — about 50 % more headroom
than the C3's ~105 KB. That extra headroom moved the reliable concurrent ceiling
up:

| Workload | C3 (~105 KB free) | S3 no-PSRAM build (~158 KB free) |
|----------|-------------------|----------------------------------|
| Soak ceiling (clean) | 8 KB (`--max-size 8192`) | 16 KB (`--max-size 16384`) |
| Max isolated concurrent GET | 4× 16 KB | 2× 32 KB |
| 6× 64 KB GET | fail | fail |
| 4× 16 KB POST | — | fail |

So the S3 is measurably more capable, but still bounded by internal SRAM — it
cannot serve 6× 64 KB concurrent responses or 4× 16 KB concurrent uploads.

### AtomVM `0.7.0-beta.1` OOM behaviour

A failed `memory_create_refc_binary` does **not** raise a catchable Erlang error.
The VM panics (`StoreProhibited` / `abort()`) and the board reboots. Because the
allocation path cannot be caught in Erlang, the only safe mitigations are:

1. Keep payload sizes bounded (`--max-size 8192` on C3, `16384` on a no-PSRAM
   build).
2. Cap `max_connections` so the worst-case concurrent buffer demand fits in free
   heap.
3. On PSRAM-equipped S3 boards, build AtomVM with `CONFIG_SPIRAM=y` so large
   buffers come from PSRAM instead of internal SRAM.

## Summary recommendation

| Board | Free heap after boot | Recommended `--max-size` | Max concurrent large GET | Notes |
|-------|----------------------|---------------------------|---------------------------|-------|
| ESP32-C3 (no PSRAM) | `104,820–110,688 B` | `8192` (16 KB = at your own risk) | 4× 16 KB (isolated); 2× 32 KB is flaky | 64 KB concurrent = guaranteed OOM |
| ESP32-S3, no-PSRAM build | `157,364–163,340 B` | `16384` | 2× 32 KB | ~50 % more headroom than C3; still internal-SRAM bound |
| ESP32-S3, `CONFIG_SPIRAM=y` | n/a — not measured here | Up to the PSRAM budget | n/a — not measured here | Expected to remove the internal-SRAM ceiling; rebuild AtomVM with SPIRAM enabled and re-measure |

## Reproducing

```bash
cd examples/httpd_debug

# Functional baseline (20/20) + size sweeps
./scripts/test.sh <ip>

# Clean mixed soak within the board's limit
./scripts/soak.sh <ip> -d 30 -c 4 --max-size 8192    # C3
./scripts/soak.sh <ip> -d 30 -c 4 --max-size 16384   # S3 no-PSRAM build

# Post-process a run into a leak/fail verdict
./scripts/soak_analyze.sh <run-dir>
```

For the harness details, output format, and how to read the leak/fragmentation
verdicts, see [SOAK.md](./SOAK.md). Heap baselines and current free heap on a
running device are available at `/api/stats/memory` and `/api/memory`.
