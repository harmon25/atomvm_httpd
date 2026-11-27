# ElixirHttp

An Elixir example application for [`atomvm_httpd`](../../README.md), targeting
the AtomVM (ESP32). It serves a small static dashboard from `priv/`, a JSON API
under `/api/*`, and streams live memory updates over a WebSocket at `/ws`.

## Endpoints

| Method | Path               | Description                                    |
| ------ | ------------------ | ---------------------------------------------- |
| `GET`  | `/`                | Dashboard (`priv/index.html` + `priv/js/app.js`) |
| `GET`  | `/favicon.ico`     | Favicon                                        |
| `GET`  | `/api/system_info` | Platform / AtomVM / chip information (JSON)    |
| `GET`  | `/api/memory`      | Atom, process, port and ESP32 heap stats (JSON) |
| `WS`   | `/ws`              | Sends changed memory fields every 5 seconds    |

## Build and flash

WiFi credentials are resolved at compile time from environment variables:

```shell
export ATOMVM_WIFI_SSID="your-ssid"
export ATOMVM_WIFI_PSK="your-password"
```

(For backwards compatibility, `SSID` / `PSK` are used if the `ATOMVM_WIFI_*`
variables are unset.)

Then fetch dependencies and flash the device:

```shell
cd examples/elixir_http
mix deps.get
mix atomvm.esp32.flash
```

The server listens on port 8080. Open `http://<device-ip>:8080/` once the
device has joined the network.

## Running the integration tests

The test suite in `test/elixir_http_test.exs` drives a *running* server (on a
device or locally), so point it at the host:

```shell
HTTP_TEST_HOST=192.168.1.42 HTTP_TEST_PORT=8080 mix test
```

`HTTP_TEST_HOST` defaults to `127.0.0.1` and `HTTP_TEST_PORT` to `8080`.
Tests tagged `:slow` can be skipped with `mix test --exclude slow`.
