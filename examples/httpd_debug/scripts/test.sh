#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <esp32-ip>"
    echo "Example: $0 192.168.1.100"
    exit 1
fi

HOST="$1"
BASE="http://$HOST"
FAILED=0
PASSED=0
# Helper: increment without triggering set -e on zero-to-one transition
inc_passed() { PASSED=$((PASSED + 1)); }
inc_failed() { FAILED=$((FAILED + 1)); }

echo "=== AtomVM HTTPD Debug - Automated Test Suite ==="
echo "Target: $BASE"
echo ""

# Helper function to run a test
run_test() {
    local name="$1"
    local cmd="$2"
    
    echo -n "Testing: $name ... "
    
    if eval "$cmd" >/dev/null 2>&1; then
        echo "✓ PASS"
        inc_passed
        return 0
    else
        echo "✗ FAIL"
        inc_failed
        return 1
    fi
}

# Test 1: Ping endpoint
echo "=== Basic Connectivity ==="
run_test "Ping" "curl -sf -m 5 '$BASE/api/ping'" || true
echo ""

# Test 2: Memory endpoint
echo "=== Memory Info ==="
if curl -sf -m 5 "$BASE/api/memory" | grep -q '"free_heap"'; then
    echo "✓ Memory endpoint working"
    curl -sf "$BASE/api/memory" 2>/dev/null | head -5
    inc_passed
else
    echo "✗ Memory endpoint failed"
    inc_failed
fi
echo ""

# Test 3: Response generation with increasing sizes
echo "=== Response Size Tests ==="
for SIZE in 100 500 1024 2048 4096 8192 16384 32768 65536; do
    echo -n "Generate $SIZE bytes ... "
    
    START=$(date +%s%N)
    # Scale timeout with size: 10s base + 1s per 4KB
    TIMEOUT=$(( 10 + SIZE / 4096 ))
    if RESPONSE=$(curl -sf -m $TIMEOUT "$BASE/api/generate?size=$SIZE" 2>/dev/null); then
        END=$(date +%s%N)
        ELAPSED=$(( (END - START) / 1000000 ))
        
        # Check if response is valid JSON
        if echo "$RESPONSE" | grep -q '"data"'; then
            ACTUAL_SIZE=$(echo "$RESPONSE" | grep -o '"data":"[^"]*"' | sed 's/"data":"//;s/"$//' | wc -c)
            ACTUAL_SIZE=$((ACTUAL_SIZE - 1))  # Subtract newline
            echo "✓ PASS (${ELAPSED}ms, ~${ACTUAL_SIZE} bytes)"
            inc_passed
        else
            echo "✗ FAIL (invalid JSON response)"
            inc_failed
        fi
    else
        echo "✗ FAIL (request failed)"
        inc_failed
    fi
done
echo ""

# Test 4: POST echo with increasing sizes
echo "=== Upload Size Tests ==="
for SIZE in 100 500 1024 2048 4096 8192 16384; do
    echo -n "Upload $SIZE bytes ... "
    
    START=$(date +%s%N)
    if RESPONSE=$(dd if=/dev/urandom bs=$SIZE count=1 2>/dev/null | \
                   curl -sf -m 10 -X POST \
                   -H "Content-Type: application/octet-stream" \
                   --data-binary @- \
                   "$BASE/api/echo" 2>/dev/null); then
        END=$(date +%s%N)
        ELAPSED=$(( (END - START) / 1000000 ))
        
        # Check if server received correct size
        if echo "$RESPONSE" | grep -q '"received_bytes":'$SIZE; then
            echo "✓ PASS (${ELAPSED}ms)"
            inc_passed
        else
            RECEIVED=$(echo "$RESPONSE" | grep -o '"received_bytes":[0-9]*' | grep -o '[0-9]*')
            echo "✗ FAIL (server received $RECEIVED bytes instead of $SIZE)"
            inc_failed
        fi
    else
        echo "✗ FAIL (request failed)"
        inc_failed
    fi
done
echo ""

# Test 5: Stats endpoints
echo "=== Stats Endpoints ==="
run_test "System stats" "curl -sf -m 5 '$BASE/api/stats/system' | grep -q 'platform'" || true
run_test "Memory stats" "curl -sf -m 5 '$BASE/api/stats/memory' | grep -q 'esp32_free_heap_size'" || true
echo ""

# Summary
echo "=== Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "✓ All tests passed!"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
