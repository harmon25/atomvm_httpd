defmodule HttpdWebsocketTest do
  @moduledoc """
  Integration tests for WebSocket functionality in atomvm_httpd.

  Tests cover:
  - WebSocket handshake (HTTP Upgrade)
  - Sending and receiving text frames
  - Handling masked client frames
  - Multiple message exchanges
  - Medium-length payloads (extended 16-bit length)
  - Large payloads (>65KB with 64-bit length)
  - Server-initiated push messages
  - TCP fragmentation handling for large frames
  """
  use ExUnit.Case
  import Bitwise

  @receive_timeout 2_000

  setup do
    flush_mailbox()
    port = find_free_tcp_port()

    config = [
      {[<<"ws">>],
       %{
         handler: :httpd_ws_handler,
         handler_config: %{module: TestWebSocketHandler, args: self()}
       }}
    ]

    {:ok, server} = :httpd.start_link(port, config)
    Process.sleep(20)

    on_exit(fn -> safe_stop(server) end)

    {:ok, port: port}
  end

  # The server is linked to the test process and traps exits, so it shuts down as
  # the test process exits — racing on_exit's stop. Tolerate an already-gone server.
  defp safe_stop(server) do
    if Process.alive?(server) do
      try do
        :httpd.stop(server)
      catch
        :exit, _ -> :ok
      end
    end
  end

  test "completes websocket handshake", %{port: port} do
    {:ok, socket} = connect(port)

    try do
      # Send WebSocket upgrade request
      request = """
      GET /ws HTTP/1.1\r
      Host: localhost:#{port}\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
      Sec-WebSocket-Version: 13\r
      \r
      """

      :ok = :gen_tcp.send(socket, request)

      # Receive complete upgrade response
      response = read_http_response(socket)
      assert response =~ "HTTP/1.1 101 Switching Protocols"
      # Response headers are normalized to lowercase keys by the server.
      assert response =~ "upgrade: websocket"
      assert response =~ "connection: Upgrade"
      assert response =~ "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

      # Verify handler received init
      assert_receive {:ws_init, _websocket, _path}, @receive_timeout
    after
      :gen_tcp.close(socket)
    end
  end

  test "sends and receives websocket text frames", %{port: port} do
    {:ok, socket} = ws_connect(port)

    try do
      # Send a masked text frame: "hello"
      frame = create_ws_frame("hello", :text, true)
      :ok = :gen_tcp.send(socket, frame)

      # Verify handler received message
      assert_receive {:ws_message, <<"hello">>}, @receive_timeout

      # Receive echoed response (unmasked from server)
      assert {:ok, response_frame} = :gen_tcp.recv(socket, 0, @receive_timeout)
      assert parse_ws_frame(response_frame) == {:ok, "echo: hello"}
    after
      :gen_tcp.close(socket)
    end
  end

  test "handles multiple websocket messages", %{port: port} do
    {:ok, socket} = ws_connect(port)

    try do
      messages = ["first", "second", "third"]

      for msg <- messages do
        frame = create_ws_frame(msg, :text, true)
        :ok = :gen_tcp.send(socket, frame)
        assert_receive {:ws_message, ^msg}, @receive_timeout

        assert {:ok, response_frame} = :gen_tcp.recv(socket, 0, @receive_timeout)
        assert parse_ws_frame(response_frame) == {:ok, "echo: #{msg}"}
      end
    after
      :gen_tcp.close(socket)
    end
  end

  test "handles medium length payload (126 bytes)", %{port: port} do
    {:ok, socket} = ws_connect(port)

    try do
      # 126 bytes requires extended payload length
      payload = String.duplicate("a", 126)
      frame = create_ws_frame(payload, :text, true)
      :ok = :gen_tcp.send(socket, frame)

      assert_receive {:ws_message, ^payload}, @receive_timeout

      assert {:ok, response_frame} = :gen_tcp.recv(socket, 0, @receive_timeout)
      assert {:ok, response_payload} = parse_ws_frame(response_frame)
      assert response_payload == "echo: #{payload}"
    after
      :gen_tcp.close(socket)
    end
  end

  test "handles large payload (> 65535 bytes)", %{port: port} do
    {:ok, socket} = ws_connect(port)

    try do
      # Large payload requires 64-bit length
      payload = String.duplicate("x", 70_000)
      frame = create_ws_frame(payload, :text, true)
      :ok = :gen_tcp.send(socket, frame)

      assert_receive {:ws_message, ^payload}, @receive_timeout

      # Receive echoed response
      assert {:ok, response_frame} = recv_all_ws_frame(socket)
      assert {:ok, response_payload} = parse_ws_frame(response_frame)
      assert response_payload == "echo: #{payload}"
    after
      :gen_tcp.close(socket)
    end
  end

  test "websocket handler can send messages to client", %{port: port} do
    {:ok, socket} = ws_connect(port)

    try do
      # Send "trigger_push" which causes handler to send a message
      frame = create_ws_frame("trigger_push", :text, true)
      :ok = :gen_tcp.send(socket, frame)

      # Should receive both the echo and the pushed message
      assert {:ok, frame1} = :gen_tcp.recv(socket, 0, @receive_timeout)
      assert {:ok, frame2} = :gen_tcp.recv(socket, 0, @receive_timeout)

      responses = [parse_ws_frame(frame1), parse_ws_frame(frame2)]
      assert {:ok, "echo: trigger_push"} in responses
      assert {:ok, "pushed message"} in responses
    after
      :gen_tcp.close(socket)
    end
  end

  # Helper functions

  defp ws_connect(port) do
    {:ok, socket} = connect(port)

    request = """
    GET /ws HTTP/1.1\r
    Host: localhost:#{port}\r
    Upgrade: websocket\r
    Connection: Upgrade\r
    Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
    Sec-WebSocket-Version: 13\r
    \r
    """

    :ok = :gen_tcp.send(socket, request)

    # Consume entire handshake response (read until we get \r\n\r\n)
    handshake = read_http_response(socket)

    unless handshake =~ "101 Switching Protocols" do
      raise "Failed to establish WebSocket connection: #{inspect(handshake)}"
    end

    # Clear init message
    receive do
      {:ws_init, _, _} -> :ok
    after
      @receive_timeout -> :ok
    end

    {:ok, socket}
  end

  defp read_http_response(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, @receive_timeout) do
      {:ok, data} ->
        new_acc = <<acc::binary, data::binary>>

        if :binary.match(new_acc, <<"\r\n\r\n">>) != :nomatch do
          new_acc
        else
          read_http_response(socket, new_acc)
        end

      {:error, reason} ->
        raise "Failed to read HTTP response: #{inspect(reason)}"
    end
  end

  defp connect(port) do
    :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw])
  end

  defp find_free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # WebSocket frame creation with masking (client -> server)
  defp create_ws_frame(payload, type, mask?) when is_binary(payload) or is_list(payload) do
    payload_bin = IO.iodata_to_binary(payload)
    payload_len = byte_size(payload_bin)

    fin_opcode =
      case type do
        :text -> 0x81
        :binary -> 0x82
        :close -> 0x88
        :ping -> 0x89
        :pong -> 0x8A
      end

    if mask? do
      masking_key = :crypto.strong_rand_bytes(4)
      masked = mask_payload(payload_bin, masking_key)

      cond do
        payload_len <= 125 ->
          <<fin_opcode, bor(0x80, payload_len), masking_key::binary, masked::binary>>

        payload_len <= 65535 ->
          <<fin_opcode, 0xFE, payload_len::16, masking_key::binary, masked::binary>>

        true ->
          <<fin_opcode, 0xFF, payload_len::64, masking_key::binary, masked::binary>>
      end
    else
      cond do
        payload_len <= 125 ->
          <<fin_opcode, payload_len, payload_bin::binary>>

        payload_len <= 65535 ->
          <<fin_opcode, 126, payload_len::16, payload_bin::binary>>

        true ->
          <<fin_opcode, 127, payload_len::64, payload_bin::binary>>
      end
    end
  end

  defp mask_payload(payload, masking_key) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, idx} ->
      mask_byte = :binary.at(masking_key, rem(idx, 4))
      Bitwise.bxor(byte, mask_byte)
    end)
    |> :binary.list_to_bin()
  end

  # Parse WebSocket frame (server -> client, unmasked)
  defp parse_ws_frame(<<_fin_opcode, mask_len, rest::binary>>) do
    payload_len = band(mask_len, 0x7F)

    case payload_len do
      126 ->
        <<actual_len::16, payload::binary-size(actual_len), _::binary>> = rest
        {:ok, payload}

      127 ->
        <<actual_len::64, payload::binary-size(actual_len), _::binary>> = rest
        {:ok, payload}

      len ->
        <<payload::binary-size(len), _::binary>> = rest
        {:ok, payload}
    end
  end

  defp recv_all_ws_frame(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, @receive_timeout) do
      {:ok, chunk} ->
        new_acc = <<acc::binary, chunk::binary>>

        # Try to determine if we have a complete frame
        case has_complete_frame?(new_acc) do
          {:complete, _total_size} ->
            {:ok, new_acc}

          :incomplete ->
            recv_all_ws_frame(socket, new_acc)
        end

      {:error, :closed} ->
        {:ok, acc}

      error ->
        error
    end
  end

  defp has_complete_frame?(data) when byte_size(data) < 2, do: :incomplete

  defp has_complete_frame?(data) do
    <<_fin_opcode, mask_len, rest::binary>> = data
    payload_len_indicator = band(mask_len, 0x7F)
    mask? = band(mask_len, 0x80) != 0
    mask_size = if mask?, do: 4, else: 0

    case payload_len_indicator do
      126 ->
        if byte_size(rest) >= 2 do
          <<actual_len::16, _::binary>> = rest
          total_needed = 2 + 2 + mask_size + actual_len
          if byte_size(data) >= total_needed, do: {:complete, total_needed}, else: :incomplete
        else
          :incomplete
        end

      127 ->
        if byte_size(rest) >= 8 do
          <<actual_len::64, _::binary>> = rest
          total_needed = 2 + 8 + mask_size + actual_len
          if byte_size(data) >= total_needed, do: {:complete, total_needed}, else: :incomplete
        else
          :incomplete
        end

      len ->
        total_needed = 2 + mask_size + len
        if byte_size(data) >= total_needed, do: {:complete, total_needed}, else: :incomplete
    end
  end
end
