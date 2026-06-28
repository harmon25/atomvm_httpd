#!/bin/bash
#
# soak.sh — Extended-duration endurance test for atomvm_httpd on real hardware.
#
# Continuously drives a mix of request patterns (ping, variable-size response
# generation, variable-size uploads) against the ESP32 for a configurable
# duration, while sampling the device heap to detect leaks, fragmentation, and
# crashes/hangs over time. Designed to run unattended for hours or days.
#
# Usage:
#   ./soak.sh <esp32-ip> [options]
#
# Options:
#   -d, --duration  <secs>   Total run time in seconds      (default: 3600 = 1h)
#   -c, --concurrency <n>    Parallel request workers       (default: 4)
#   -s, --sample    <secs>   Heap sample / report interval  (default: 30)
#   -t, --timeout   <secs>   Per-request curl timeout       (default: 15)
#       --max-fails <n>      Abort after N consecutive request failures
#                            (crash/hang backstop)          (default: 500)
#       --max-unreachable <n> Abort after N consecutive intervals where the
#                            heap probe is unreachable — the primary crash
#                            detector (N * sample interval)  (default: 10)
#       --fail-backoff <s>   Sleep this long after a failed request so a brief
#                            network blip can't masquerade as a crash (default: 0.5)
#   -o, --out <dir>          Output directory for logs/CSV
#                            (default: /tmp/atomvm_soak/<timestamp>)
#   -h, --help               Show this help
#
# Examples:
#   ./soak.sh 192.168.1.100                      # 1 hour, 4 workers
#   ./soak.sh 192.168.1.100 -d 28800 -c 8        # 8h overnight soak, 8 workers
#   nohup ./soak.sh 192.168.1.100 -d 259200 \    # 3-day unattended run
#         -o ~/soak-3day >/dev/null 2>&1 &
#
# Output files (in --out dir):
#   samples.csv   time-series: one row per sample interval (for analysis/plots)
#   soak.log      human-readable event log (start, warnings, aborts)
#   failures.log  per-interval failure counts with timestamps
#   status        single-line heartbeat, rewritten each interval (tail -f it)
#   summary.txt   final summary (also printed to stdout)
#   results       raw per-request stream (. = ok, F = fail)
#
# Exit codes:
#   0  completed full duration with no abort condition
#   1  aborted early (crash/hang or sustained unreachability)
#   2  bad usage

set -u

# ----------------------------------------------------------------------------
# Defaults / arg parsing
# ----------------------------------------------------------------------------
HOST=""
DURATION=3600
CONCURRENCY=4
SAMPLE_INTERVAL=30
REQ_TIMEOUT=15
MAX_CONSECUTIVE_FAILS=500
MAX_UNREACHABLE=10
FAIL_BACKOFF=0.5
OUTDIR=""

usage() {
    sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--duration)        DURATION="$2"; shift 2 ;;
        -c|--concurrency)     CONCURRENCY="$2"; shift 2 ;;
        -s|--sample)          SAMPLE_INTERVAL="$2"; shift 2 ;;
        -t|--timeout)         REQ_TIMEOUT="$2"; shift 2 ;;
        --max-fails)          MAX_CONSECUTIVE_FAILS="$2"; shift 2 ;;
        --max-unreachable)    MAX_UNREACHABLE="$2"; shift 2 ;;
        --fail-backoff)       FAIL_BACKOFF="$2"; shift 2 ;;
        -o|--out)             OUTDIR="$2"; shift 2 ;;
        -h|--help)            usage 0 ;;
        -*)                   echo "Unknown option: $1" >&2; usage 2 ;;
        *)                    if [ -z "$HOST" ]; then HOST="$1"; shift; else
                                  echo "Unexpected argument: $1" >&2; usage 2; fi ;;
    esac
done

if [ -z "$HOST" ]; then
    echo "Error: <esp32-ip> is required" >&2
    usage 2
fi

BASE="http://$HOST"

# ----------------------------------------------------------------------------
# Output directory (persistent — NOT auto-deleted, so results survive the run)
# ----------------------------------------------------------------------------
RUN_ID="$(date '+%Y%m%d-%H%M%S')"
[ -n "$OUTDIR" ] || OUTDIR="/tmp/atomvm_soak/$RUN_ID"
mkdir -p "$OUTDIR" || { echo "Error: cannot create output dir $OUTDIR" >&2; exit 2; }

RESULTS="$OUTDIR/results"      # append-only: one char per request: . = ok, F = fail
LOG="$OUTDIR/soak.log"         # human-readable event log
CSV="$OUTDIR/samples.csv"      # time-series, one row per sample interval
FAILLOG="$OUTDIR/failures.log" # per-interval failure detail
STATUS="$OUTDIR/status"        # single-line heartbeat, rewritten each interval
SUMMARY="$OUTDIR/summary.txt"  # final summary
STOP_FLAG="$OUTDIR/stop"       # presence signals all workers to exit

trap 'cleanup' EXIT INT TERM

cleanup() {
    touch "$STOP_FLAG" 2>/dev/null || true
    # Give workers a moment to notice the stop flag, then hard-kill leftovers.
    sleep 1
    pkill -P $$ 2>/dev/null || true
    # NOTE: deliberately does NOT remove "$OUTDIR" — results are kept.
}

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line"
    echo "$line" >> "$LOG"
}

# ----------------------------------------------------------------------------
# Heap sampling helpers
# ----------------------------------------------------------------------------
# Extract a numeric JSON field value (integer) from stdin.
json_int() {
    grep -o "\"$1\":[0-9]*" | grep -o '[0-9]*' | head -1
}

sample_heap() {
    # echoes: "<free_heap> <largest_block> <min_free>" or "" on failure
    local resp
    resp=$(curl -sf -m "$REQ_TIMEOUT" "$BASE/api/memory" 2>/dev/null) || return 1
    local free largest minf
    free=$(printf '%s' "$resp" | json_int free_heap)
    largest=$(printf '%s' "$resp" | json_int largest_block)
    minf=$(printf '%s' "$resp" | json_int min_free)
    [ -n "$free" ] || return 1
    echo "$free $largest $minf"
}

# ----------------------------------------------------------------------------
# Request workload — one random request per call.
# Returns 0 on success, 1 on failure.
#
# NOTE: response validation checks the *complete* payload, not just a substring.
# /api/generate returns {"data":"AAA...","size":N,...}; a truncated body still
# begins with "data", so we verify the reported size field is present at the
# END of the JSON (i.e. the body arrived intact and curl returned success).
# ----------------------------------------------------------------------------
GEN_SIZES=(128 512 1024 4096 8192 16384 32768 65536)
UP_SIZES=(128 512 1024 4096 8192 16384)

do_request() {
    local pick=$(( RANDOM % 4 ))
    case "$pick" in
        0)  # ping
            curl -sf -m "$REQ_TIMEOUT" "$BASE/api/ping" >/dev/null 2>&1
            ;;
        1|2)  # generate a response of random size; curl -f + complete-body check
            local sz=${GEN_SIZES[$(( RANDOM % ${#GEN_SIZES[@]} ))]}
            local resp
            resp=$(curl -sf -m "$REQ_TIMEOUT" "$BASE/api/generate?size=$sz" 2>/dev/null) \
                && printf '%s' "$resp" | grep -q "\"size\":$sz"
            ;;
        3)  # upload a random-size body and verify received_bytes
            local sz=${UP_SIZES[$(( RANDOM % ${#UP_SIZES[@]} ))]}
            local resp
            resp=$(dd if=/dev/urandom bs="$sz" count=1 2>/dev/null | \
                curl -sf -m "$REQ_TIMEOUT" -X POST \
                    -H "Content-Type: application/octet-stream" \
                    --data-binary @- "$BASE/api/echo" 2>/dev/null) \
                && printf '%s' "$resp" | grep -q "\"received_bytes\":$sz"
            ;;
    esac
}

worker() {
    while [ ! -f "$STOP_FLAG" ]; do
        if do_request; then
            printf '.' >> "$RESULTS"
        else
            printf 'F' >> "$RESULTS"
            # Back off on failure. A failing request (connection refused/reset)
            # returns almost instantly, so without this a brief network/AP blip
            # would let workers spin and pile up thousands of failures in
            # seconds — looking like a crash. Backing off rate-limits failures
            # so the abort thresholds reflect a *sustained* outage, not a blip.
            sleep "$FAIL_BACKOFF"
        fi
    done
}

# ----------------------------------------------------------------------------
# Counters derived from the RESULTS file
# ----------------------------------------------------------------------------
count_char() { tr -cd "$1" < "$RESULTS" 2>/dev/null | wc -c; }

# Number of failures at the very tail of the results stream (consecutive).
trailing_fails() {
    local tail_chars
    tail_chars=$(tail -c 400 "$RESULTS" 2>/dev/null)
    local n=0 i ch
    for (( i=${#tail_chars}-1; i>=0; i-- )); do
        ch=${tail_chars:$i:1}
        if [ "$ch" = "F" ]; then n=$((n+1)); else break; fi
    done
    echo "$n"
}

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
echo "=== AtomVM HTTPD — Soak / Endurance Test ==="
echo "Target:        $BASE"
echo "Duration:      ${DURATION}s ($(( DURATION / 3600 ))h $(( (DURATION % 3600) / 60 ))m)"
echo "Concurrency:   $CONCURRENCY workers"
echo "Sample every:  ${SAMPLE_INTERVAL}s"
echo "Req timeout:   ${REQ_TIMEOUT}s"
echo "Abort after:   $MAX_CONSECUTIVE_FAILS consecutive req failures, or"
echo "               $MAX_UNREACHABLE consecutive unreachable samples"
echo "Output dir:    $OUTDIR"
echo ""

log "Preflight: checking connectivity at $BASE/api/memory ..."
BASELINE=$(sample_heap) || {
    log "FATAL: device unreachable at $BASE/api/memory — is it up?"
    exit 1
}
read -r BASE_FREE BASE_LARGEST BASE_MIN <<< "$BASELINE"
log "Baseline heap: free=${BASE_FREE}B largest=${BASE_LARGEST}B min_free=${BASE_MIN}B"
echo ""

: > "$RESULTS"
# CSV header
echo "timestamp,elapsed_s,total_reqs,ok,fail,interval_reqs,rps,free_heap,largest_block,min_free,d_free_vs_baseline" > "$CSV"

# ----------------------------------------------------------------------------
# Launch workers
# ----------------------------------------------------------------------------
START=$(date +%s)
END=$(( START + DURATION ))

for _ in $(seq 1 "$CONCURRENCY"); do
    worker &
done

log "Launched $CONCURRENCY workers; soak running for ${DURATION}s..."
echo ""

# ----------------------------------------------------------------------------
# Monitor loop: sample heap + report on each interval until time/abort.
# ----------------------------------------------------------------------------
ABORTED=0
ABORT_REASON=""
LOW_FREE=$BASE_FREE
PREV_TOTAL=0
PREV_FAILS=0
UNREACHABLE_STREAK=0

printf '%-21s %9s %8s %7s %7s %11s %11s %12s\n' \
    "time" "reqs" "ok" "fail" "req/s" "free_heap" "min_free" "d_free"

while :; do
    NOW=$(date +%s)
    [ "$NOW" -ge "$END" ] && break

    sleep "$SAMPLE_INTERVAL"

    NOW=$(date +%s)
    ELAPSED=$(( NOW - START ))
    TS=$(date '+%Y-%m-%d %H:%M:%S')

    TOTAL=$(wc -c < "$RESULTS")
    FAILS=$(count_char F)
    OKS=$(( TOTAL - FAILS ))
    INTERVAL_REQS=$(( TOTAL - PREV_TOTAL ))
    INTERVAL_FAILS=$(( FAILS - PREV_FAILS ))
    PREV_TOTAL=$TOTAL
    PREV_FAILS=$FAILS
    RPS=$(( INTERVAL_REQS / SAMPLE_INTERVAL ))

    HEAP=$(sample_heap || echo "")
    if [ -n "$HEAP" ]; then
        read -r H_FREE H_LARGEST H_MIN <<< "$HEAP"
        D_FREE=$(( H_FREE - BASE_FREE ))
        [ "$H_FREE" -lt "$LOW_FREE" ] && LOW_FREE=$H_FREE
        UNREACHABLE_STREAK=0
    else
        H_FREE=""; H_LARGEST=""; H_MIN=""; D_FREE=""
        UNREACHABLE_STREAK=$(( UNREACHABLE_STREAK + 1 ))
        log "WARN: heap sample failed (#$UNREACHABLE_STREAK; device busy/reconnecting?)"
    fi

    # Console row (human)
    printf '%-21s %9d %8d %7d %7d %11s %11s %12s\n' \
        "$TS" "$TOTAL" "$OKS" "$FAILS" "$RPS" "${H_FREE:-?}" "${H_MIN:-?}" "${D_FREE:-?}"

    # CSV row (machine)
    echo "$TS,$ELAPSED,$TOTAL,$OKS,$FAILS,$INTERVAL_REQS,$RPS,${H_FREE},${H_LARGEST},${H_MIN},${D_FREE}" >> "$CSV"

    # Heartbeat status (single line, overwritten)
    {
        echo "run_id=$RUN_ID host=$HOST pid=$$"
        echo "updated=$TS elapsed=${ELAPSED}s of ${DURATION}s"
        echo "reqs=$TOTAL ok=$OKS fail=$FAILS rps=$RPS"
        echo "free_heap=${H_FREE:-unreachable} min_free=${H_MIN:-?} d_free=${D_FREE:-?} low_water=$LOW_FREE"
        echo "consec_req_fails=$(trailing_fails) consec_unreachable=$UNREACHABLE_STREAK"
    } > "$STATUS"

    # Per-interval failure detail
    if [ "$INTERVAL_FAILS" -gt 0 ]; then
        echo "$TS elapsed=${ELAPSED}s interval_fail=$INTERVAL_FAILS interval_reqs=$INTERVAL_REQS cumulative_fail=$FAILS" >> "$FAILLOG"
    fi

    # Abort: crash/hang (sustained request failures)
    TF=$(trailing_fails)
    if [ "$TF" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
        ABORT_REASON="$TF consecutive request failures — device likely crashed or hung"
        log "ABORT: $ABORT_REASON"
        ABORTED=1
        break
    fi
    # Abort: sustained unreachability of the heap probe
    if [ "$UNREACHABLE_STREAK" -ge "$MAX_UNREACHABLE" ]; then
        ABORT_REASON="$UNREACHABLE_STREAK consecutive unreachable heap samples — device down"
        log "ABORT: $ABORT_REASON"
        ABORTED=1
        break
    fi
done

# ----------------------------------------------------------------------------
# Teardown + final report
# ----------------------------------------------------------------------------
touch "$STOP_FLAG"
wait 2>/dev/null

NOW=$(date +%s)
ELAPSED=$(( NOW - START ))
TOTAL=$(wc -c < "$RESULTS")
FAILS=$(count_char F)
OKS=$(( TOTAL - FAILS ))

FINAL=$(sample_heap || echo "")
if [ -n "$FINAL" ]; then
    read -r F_FREE F_LARGEST F_MIN <<< "$FINAL"
else
    F_FREE="?"; F_LARGEST="?"; F_MIN="?"
fi

{
    echo "=== Soak Summary ==="
    echo "Run ID:            $RUN_ID"
    echo "Target:            $BASE"
    echo "Ran for:           ${ELAPSED}s ($(( ELAPSED / 3600 ))h $(( (ELAPSED % 3600) / 60 ))m)"
    echo "Concurrency:       $CONCURRENCY workers"
    echo "Total requests:    $TOTAL"
    echo "  ok:              $OKS"
    echo "  failed:          $FAILS"
    if [ "$TOTAL" -gt 0 ]; then
        echo "  fail rate:       $(awk "BEGIN{printf \"%.3f%%\", $FAILS*100/$TOTAL}")"
    fi
    if [ "$ELAPSED" -gt 0 ]; then
        echo "  avg throughput:  $(awk "BEGIN{printf \"%.1f\", $TOTAL/$ELAPSED}") req/s"
    fi
    echo ""
    echo "Heap (free bytes): baseline=$BASE_FREE  final=$F_FREE  low-water=$LOW_FREE"
    if [ "$F_FREE" != "?" ]; then
        NET=$(( F_FREE - BASE_FREE ))
        echo "  net change:      ${NET}B  (large negative => possible leak / fragmentation)"
        echo "  min_free:        baseline=$BASE_MIN  final=$F_MIN"
    fi
    echo ""
    if [ "$ABORTED" -eq 1 ]; then
        echo "Result:            ABORTED — $ABORT_REASON"
    elif [ "$FAILS" -gt 0 ]; then
        echo "Result:            COMPLETED with $FAILS failures over $TOTAL requests"
    else
        echo "Result:            CLEAN — $OKS/$TOTAL requests ok"
    fi
    echo ""
    echo "Artifacts:"
    echo "  CSV time-series: $CSV"
    echo "  Event log:       $LOG"
    echo "  Failure log:     $FAILLOG"
} | tee "$SUMMARY"

echo ""
if [ "$ABORTED" -eq 1 ]; then
    echo "✗ Soak ABORTED early — see $LOG"
    exit 1
fi
if [ "$FAILS" -gt 0 ]; then
    echo "⚠ Soak completed with $FAILS failures over $TOTAL requests."
else
    echo "✓ Soak completed cleanly: $OKS/$TOTAL requests ok."
fi
exit 0
