defmodule HttpdDebug.WsEchoHandler do
  @moduledoc """
  WebSocket handler for stress-testing the atomvm_httpd WebSocket send path
  (`tcp_server:send/2` backpressure handling) on real hardware.

  Protocol:

    * A message of the form `gen:<N>` makes the server reply with an `N`-byte
      payload whose byte at index `i` equals `rem(i, 256)`. This exercises large
      server -> client frames (the backpressure / eagain retry path) without
      requiring the client to upload `N` bytes, and the positional pattern lets
      the client detect truncation, duplication or reordering.

    * Any other message is echoed back verbatim, validating full round-trip
      integrity for large client -> server -> client payloads.

  Used by `scripts/ws_stress.py`.
  """

  @behaviour :httpd_ws_handler

  # Cap generated payloads to stay memory-safe on device.
  @max_gen 262_144

  @impl true
  def handle_ws_init(websocket, _path, _args) do
    {:ok, %{websocket: websocket}}
  end

  @impl true
  def handle_ws_message(<<"gen:", rest::binary>>, state) do
    n =
      rest
      |> parse_int()
      |> min(@max_gen)
      |> max(0)

    {:reply, pattern(n), state}
  end

  def handle_ws_message(payload, state) do
    # Echo the exact bytes received.
    {:reply, payload, state}
  end

  # Build N bytes where byte i == rem(i, 256).
  defp pattern(0), do: <<>>

  defp pattern(n) do
    # :lists.seq/2 and :erlang.list_to_binary/1 are available on AtomVM.
    block = :erlang.list_to_binary(:lists.seq(0, 255))
    full = :binary.copy(block, div(n, 256) + 1)
    <<out::binary-size(n), _::binary>> = full
    out
  end

  # Minimal non-negative integer parser (avoids String.to_integer edge cases).
  defp parse_int(bin), do: parse_int(bin, 0)

  defp parse_int(<<d, rest::binary>>, acc) when d >= ?0 and d <= ?9 do
    parse_int(rest, acc * 10 + (d - ?0))
  end

  defp parse_int(_, acc), do: acc
end
