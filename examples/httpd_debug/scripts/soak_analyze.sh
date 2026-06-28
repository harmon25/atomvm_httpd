#!/bin/bash
#
# soak_analyze.sh — Post-process a soak run's samples.csv into a verdict.
#
# Reads the time-series CSV produced by soak.sh and reports:
#   - run duration, total requests, failure rate, throughput
#   - heap leak estimate (linear-regression slope of free_heap over time)
#   - fragmentation indicator (trend of largest_free_block)
#   - heap low-water mark and net change
#   - the worst failure intervals
#
# Usage:
#   ./soak_analyze.sh <run-dir-or-samples.csv>
#
# Examples:
#   ./soak_analyze.sh /tmp/atomvm_soak/20260627-141500
#   ./soak_analyze.sh ~/soak-3day/samples.csv

set -u

ARG="${1:-}"
if [ -z "$ARG" ]; then
    echo "Usage: $0 <run-dir-or-samples.csv>" >&2
    exit 2
fi

if [ -d "$ARG" ]; then
    CSV="$ARG/samples.csv"
else
    CSV="$ARG"
fi

if [ ! -f "$CSV" ]; then
    echo "Error: no samples.csv found at: $CSV" >&2
    exit 2
fi

ROWS=$(( $(wc -l < "$CSV") - 1 ))   # minus header
if [ "$ROWS" -lt 2 ]; then
    echo "Error: need at least 2 sample rows to analyze (have $ROWS)." >&2
    exit 2
fi

echo "=== Soak Analysis: $CSV ==="
echo "Sample rows: $ROWS"
echo ""

# CSV columns:
# 1 timestamp, 2 elapsed_s, 3 total_reqs, 4 ok, 5 fail, 6 interval_reqs,
# 7 rps, 8 free_heap, 9 largest_block, 10 min_free, 11 d_free_vs_baseline
#
# Linear regression of free_heap (y) over elapsed_s (x) gives the leak rate
# (slope, bytes/sec). Skips rows where free_heap is blank (unreachable sample).
awk -F, '
NR == 1 { next }                         # skip header
$8 == "" { unreachable++; next }         # blank free_heap = unreachable sample
{
    n++
    x = $2 + 0; y = $8 + 0
    sx += x; sy += y; sxx += x*x; sxy += x*y
    if (first == 0) { first = 1; x0 = x; y0 = y; lowy = y; lblock_min = $9+0 }
    if (y < lowy) lowy = y
    lastx = x; lasty = y
    lb = $9 + 0
    if (lb < lblock_min) lblock_min = lb
    lblock_last = lb

    # totals come from the final row (they are cumulative)
    tot = $3 + 0; ok = $4 + 0; fail = $5 + 0
    # track max consecutive interval fails
    ifail = $5 + 0
}
END {
    dur = lastx - x0
    printf "Duration sampled:   %d s (%.2f h)\n", dur, dur/3600.0
    printf "Total requests:     %d\n", tot
    printf "  ok / fail:        %d / %d\n", ok, fail
    if (tot > 0) printf "  fail rate:        %.3f%%\n", fail*100.0/tot
    if (dur > 0) printf "  avg throughput:   %.2f req/s\n", tot/dur
    if (unreachable > 0)
        printf "  unreachable samples: %d (device busy/reconnecting/down)\n", unreachable
    print ""

    # Linear regression slope = (n*Sxy - Sx*Sy) / (n*Sxx - Sx*Sx)
    denom = (n*sxx - sx*sx)
    if (n >= 2 && denom != 0) {
        slope = (n*sxy - sx*sy) / denom       # bytes per second
        per_hour = slope * 3600.0
        printf "Heap free (bytes):  start=%d  end=%d  low-water=%d\n", y0, lasty, lowy
        printf "  net change:       %+d B over %.2f h\n", (lasty - y0), dur/3600.0
        printf "  trend (regress):  %+.1f B/hour", per_hour
        if (per_hour < -1024)
            printf "   <== LEAK SUSPECTED (sustained downward trend)\n"
        else if (per_hour < -64)
            printf "   (slight downward drift — watch over longer run)\n"
        else
            printf "   (flat — no leak signal)\n"
    }
    print ""
    printf "Largest free block: end=%d  min-seen=%d\n", lblock_last, lblock_min
    if (lowy > 0 && lblock_min > 0) {
        frag = 100.0 * (1.0 - lblock_min / lowy)
        printf "  fragmentation:    %.1f%% (1 - min_largest_block / low_water_free)\n", frag
        if (frag > 50.0)
            printf "                    <== HIGH fragmentation at heap low point\n"
    }
}
' "$CSV"

echo ""
echo "=== Worst failure intervals (top 10 by interval fail count) ==="
# interval fails = col5 delta; recompute from cumulative col5
awk -F, '
NR==1 { next }
$5=="" { next }
{
    if (seen) {
        d = ($5+0) - prev
        if (d > 0) printf "%6d fails  @ %s  (elapsed %ss)\n", d, $1, $2
    }
    prev = $5+0; seen=1
}
' "$CSV" | sort -rn | head -10
echo "(none above means zero failures)" 

echo ""
echo "Tip: plot the leak trend with:"
echo "  gnuplot -p -e \"set datafile separator ','; set xlabel 'elapsed_s'; set ylabel 'free_heap'; plot '$CSV' using 2:8 with lines\""
