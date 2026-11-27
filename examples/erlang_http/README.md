# erlang_http

An Erlang example application for [`atomvm_httpd`](../../README.md), targeting
the AtomVM (ESP32). It serves a small static dashboard from `priv/`, a JSON API
under `/api`, live memory updates over a WebSocket at `/ws`, and OTA firmware
uploads at `/ota`.

## Endpoints

| Method | Path               | Handler               | Description                                     |
| ------ | ------------------ | --------------------- | ----------------------------------------------- |
| `GET`  | `/`                | `httpd_file_handler`  | Dashboard (`priv/index.html` + `priv/js/app.js`) |
| `GET`  | `/favicon.ico`     | `httpd_file_handler`  | Favicon                                         |
| `GET`  | `/api/system_info` | `httpd_api_handler`   | Platform / AtomVM / chip info (JSON)            |
| `GET`  | `/api/memory`      | `httpd_api_handler`   | Atom, process, port and ESP32 heap stats (JSON) |
| `WS`   | `/ws`              | `httpd_ws_handler`    | Sends changed memory fields every 5 seconds     |
| `POST` | `/ota`             | `httpd_ota_handler`   | Writes an uploaded `.avm` to the `app2.avm` partition and boots it |

The dashboard polls the API on load and then receives live memory updates over
the WebSocket.

## Configuration

WiFi credentials are read from `config:get/0`. Copy the template and edit it:

```shell
cp src/config.erl-template src/config.erl
$EDITOR src/config.erl   # set your ssid/psk
```

`src/config.erl` is git-ignored, so your credentials stay out of version
control.

## Build and flash

The application depends on `atomvm_httpd` from the `main` branch of its
repository (see `rebar.config`). Build the AtomVM bundle and flash the device:

```shell
rebar3 packbeam -p
rebar3 esp32_flash
```

The server listens on port 8080. Open `http://<device-ip>:8080/` once the device
has joined the network.

To upgrade firmware over the air, POST an AtomVM bundle to `/ota`:

```shell
curl -X POST --data-binary @atomvm/atomvmlib.avm http://<device-ip>:8080/ota
```

The device writes the image to the `app2.avm` partition, records it as the boot
partition in NVS, and boots it on the next restart.
