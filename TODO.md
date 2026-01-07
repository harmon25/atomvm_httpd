# AtomVM HTTPD - Stability & Memory Leak Fixes

Tracking document for memory leak and VM stability issues identified during code review.

## Critical Issues

### 1. ✅ Fix accept loop crash recovery
**File:** `src/gen_tcp_server.erl` lines 271-283

**Problem:** When `socket:accept` fails (e.g., `emfile` - too many open files), the accept loop silently exits without spawning a replacement. The server stops accepting new connections permanently but the gen_server keeps running.

**Solution:** Handle errors by retrying with a backoff, or notify the controlling process.

---

### 2. ❌ Add pending request timeouts
**File:** `src/httpd.erl` - `pending_request_map` and `pending_buffer_map`

**Problem:** Clients can open connections and send partial data, leaving entries in the maps indefinitely. These are only cleaned up when the socket closes or request completes. A malicious or buggy client could cause unbounded memory growth.

**Solution:** Implement timeouts for incomplete requests:
- Periodic cleanup timer that removes stale entries
- Maximum buffer size per connection
- Maximum number of pending connections

---

### 3. ❌ Fix WebSocket process leak on error
**File:** `src/httpd.erl` lines 172-193

**Problem:** If `get_reply_token/1` throws after `WsHandler:start/3` succeeds (e.g., missing `Sec-WebSocket-Key` header), the WebSocket process is started but never added to `ws_socket_map` and never stopped - becoming an orphaned process.

**Solution:** Validate headers before starting WebSocket process, or wrap in try/catch with cleanup.

---

## Medium Issues

### 4. ❌ Link loop processes to controller
**File:** `src/gen_tcp_server.erl` lines 285-296

**Problem:** The `loop/2` process is spawned but not linked to anything. If the controlling gen_server crashes, loop processes continue running, try to send messages to dead processes, and sockets may not be properly closed.

**Solution:** Use `spawn_link` or monitors, and handle exit signals appropriately.

---

### 5. ✅ Fix update_state map operator
**File:** `src/httpd.erl` line 309

**Problem:** Uses `:=` (update existing key) instead of `=>` (insert/update). Will crash if the socket isn't already in the map, which can happen if a handler returns `{noreply, ...}` on the first call.

**Solution:** Change `:=` to `=>` for robustness.

---

### 6. ❌ Improve WebSocket unmask memory usage
**File:** `src/httpd_ws_handler.erl` lines 208-214

**Problem:** The `unmask/4` function builds a list in reverse then converts to binary. For very large WebSocket payloads, this could consume excessive memory and block the scheduler.

**Solution:** Process in chunks or use binary comprehensions for better memory behavior.

---

## Minor Issues

### 7. ❌ Fix atom leak in query params
**File:** `src/httpd.erl` line 454

**Problem:** Uses `list_to_atom/1` on user-supplied query parameter keys. Could exhaust atom table resources with many unique query parameters.

**Solution:** Use `list_to_binary/1` instead for query param keys.

---

### 8. ❌ Add connection limit
**File:** `src/gen_tcp_server.erl` accept loop

**Problem:** Every incoming connection spawns a new process. Under load or attack, this could exhaust process limit, file descriptor limit, or memory.

**Solution:** Add a configurable maximum connection count.

---

## Progress Log

| Date | Issue # | Status | Notes |
|------|---------|--------|-------|
| 2024-12-07 | - | - | Initial review and documentation |
| 2024-12-07 | 5 | ✅ | Fixed map update operator in httpd.erl |
| 2024-12-07 | 1 | ✅ | Fixed accept loop crash recovery in gen_tcp_server.erl |

---

## Legend
- ❌ Not started
- 🔄 In progress  
- ✅ Complete
- ⏸️ Blocked
