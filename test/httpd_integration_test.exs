defmodule HttpdIntegrationTest do
  use ExUnit.Case

  alias AtomvmHttpd.TestEchoHandler

  @receive_timeout 2_000
  @chunk_delay 5
  @large_body :binary.copy("a", 8_192)
  @large_iolist Enum.map(1..8_192, fn _ -> "b" end)
  @large_iolist_len Integer.to_string(:erlang.iolist_size(@large_iolist))

  setup context do
    flush_mailbox()
    port = find_free_tcp_port()

    handler_config =
      %{test_pid: self()}
      |> Map.merge(Map.get(context, :handler_config, %{}))

    config = [
      {[], %{handler: TestEchoHandler, handler_config: handler_config}}
    ]

    {:ok, server} = :httpd.start_link(port, config)
    Process.sleep(20)

    on_exit(fn ->
      if Process.alive?(server) do
        :httpd.stop(server)
      end
    end)

    {:ok, port: port}
  end

  test "reassembles POST bodies across tcp frames", %{port: port} do
    {:ok, socket} = connect(port)

    try do
      request_chunks = [
        "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 11\r\n\r\nhe",
        "llo=",
        "world"
      ]

      send_chunks(socket, request_chunks)

      assert_receive {:http_request, request}, @receive_timeout
      assert :post = Map.fetch!(request, :method)
      assert <<"hello=world">> = Map.fetch!(request, :body)

      assert {:ok, response} = recv_all(socket)
      assert response =~ "HTTP/1.1 200 OK"
    after
      :gen_tcp.close(socket)
    end
  end

  test "buffers headers split across frames", %{port: port} do
    {:ok, socket} = connect(port)

    try do
      request_chunks = [
        "GET / HTTP/1.1\r\nHost: example.com\r\nX-Custom",
        "-Header: value123\r\n\r\n"
      ]

      send_chunks(socket, request_chunks)

      assert_receive {:http_request, request}, @receive_timeout
      headers = Map.fetch!(request, :headers)
      assert <<"value123">> = Map.fetch!(headers, <<"X-Custom-Header">>)

      assert {:ok, response} = :gen_tcp.recv(socket, 0, @receive_timeout)
      assert response =~ "HTTP/1.1 200 OK"
    after
      :gen_tcp.close(socket)
    end
  end

  @tag handler_config: %{
         reply_body: @large_body,
         reply_headers: %{"Content-Type" => "text/plain"}
       }
  test "sends large close responses without truncation", %{port: port} do
    {:ok, socket} = connect(port)

    try do
      request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      :ok = :gen_tcp.send(socket, request)

      assert {:ok, response} = recv_all(socket)
      [headers, body] = :binary.split(response, <<"\r\n\r\n">>)

      assert String.contains?(headers, "HTTP/1.1 200 OK")
      assert byte_size(body) == byte_size(@large_body)
    after
      :gen_tcp.close(socket)
    end
  end

  @tag handler_config: %{
         reply_body: @large_iolist,
         reply_headers: %{"Content-Type" => "text/plain"}
       }
  test "sends large iolist close responses without truncation", %{port: port} do
    {:ok, socket} = connect(port)

    try do
      request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      :ok = :gen_tcp.send(socket, request)

      assert {:ok, response} = recv_all(socket)
      [headers, body] = :binary.split(response, <<"\r\n\r\n">>)

      assert String.contains?(headers, "HTTP/1.1 200 OK")
      assert String.contains?(headers, "Content-Length: " <> @large_iolist_len)
      assert byte_size(body) == :erlang.iolist_size(@large_iolist)
    after
      :gen_tcp.close(socket)
    end
  end

  @tag handler_config: %{
         reply_body: ["Hello", " ", "World"],
         reply_headers: %{"Content-Type" => "text/plain"}
       }
  test "handles simple nested iolist with correct content-length", %{port: port} do
    iolist = ["Hello", " ", "World"]
    expected_body = "Hello World"
    {:ok, socket} = connect(port)

    try do
      request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      :ok = :gen_tcp.send(socket, request)

      assert {:ok, response} = recv_all(socket)
      [headers, body] = :binary.split(response, <<"\r\n\r\n">>)

      assert String.contains?(headers, "HTTP/1.1 200 OK")

      expected_length = :erlang.iolist_size(iolist)
      assert String.contains?(headers, "Content-Length: #{expected_length}"),
             "Expected Content-Length: #{expected_length}"

      assert body == expected_body
      assert byte_size(body) == expected_length
    after
      :gen_tcp.close(socket)
    end
  end

  @tag handler_config: %{
         reply_body: [["Deep"], [["ly"], " nested"]],
         reply_headers: %{"Content-Type" => "text/plain"}
       }
  test "handles deeply nested iolist with correct content-length", %{port: port} do
    iolist = [["Deep"], [["ly"], " nested"]]
    expected_body = "Deeply nested"
    {:ok, socket} = connect(port)

    try do
      request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      :ok = :gen_tcp.send(socket, request)

      assert {:ok, response} = recv_all(socket)
      [headers, body] = :binary.split(response, <<"\r\n\r\n">>)

      assert String.contains?(headers, "HTTP/1.1 200 OK")

      expected_length = :erlang.iolist_size(iolist)
      assert String.contains?(headers, "Content-Length: #{expected_length}"),
             "Expected Content-Length: #{expected_length}"

      assert body == expected_body
      assert byte_size(body) == expected_length
    after
      :gen_tcp.close(socket)
    end
  end

  @tag handler_config: %{
         reply_body: [<<"Binary">>, " and ", "string"],
         reply_headers: %{"Content-Type" => "text/plain"}
       }
  test "handles mixed binary and string iolist with correct content-length", %{port: port} do
    iolist = [<<"Binary">>, " and ", "string"]
    expected_body = "Binary and string"
    {:ok, socket} = connect(port)

    try do
      request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      :ok = :gen_tcp.send(socket, request)

      assert {:ok, response} = recv_all(socket)
      [headers, body] = :binary.split(response, <<"\r\n\r\n">>)

      assert String.contains?(headers, "HTTP/1.1 200 OK")

      expected_length = :erlang.iolist_size(iolist)
      assert String.contains?(headers, "Content-Length: #{expected_length}"),
             "Expected Content-Length: #{expected_length}"

      assert body == expected_body
      assert byte_size(body) == expected_length
    after
      :gen_tcp.close(socket)
    end
  end

  @tag handler_config: %{
         reply_body: [<<"Start">>, 32, <<"End">>],
         reply_headers: %{"Content-Type" => "text/plain"}
       }
  test "handles iolist with byte integers with correct content-length", %{port: port} do
    iolist = [<<"Start">>, 32, <<"End">>]
    expected_body = "Start End"
    {:ok, socket} = connect(port)

    try do
      request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      :ok = :gen_tcp.send(socket, request)

      assert {:ok, response} = recv_all(socket)
      [headers, body] = :binary.split(response, <<"\r\n\r\n">>)

      assert String.contains?(headers, "HTTP/1.1 200 OK")

      expected_length = :erlang.iolist_size(iolist)
      assert String.contains?(headers, "Content-Length: #{expected_length}"),
             "Expected Content-Length: #{expected_length}"

      assert body == expected_body
      assert byte_size(body) == expected_length
    after
      :gen_tcp.close(socket)
    end
  end

  @tag handler_config: %{
         reply_body: [<<"A">>, [<<"B">>, [<<"C">>]], <<"D">>],
         reply_headers: %{"Content-Type" => "text/plain"}
       }
  test "handles complex nested iolist structure with correct content-length", %{port: port} do
    iolist = [<<"A">>, [<<"B">>, [<<"C">>]], <<"D">>]
    expected_body = "ABCD"
    {:ok, socket} = connect(port)

    try do
      request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      :ok = :gen_tcp.send(socket, request)

      assert {:ok, response} = recv_all(socket)
      [headers, body] = :binary.split(response, <<"\r\n\r\n">>)

      assert String.contains?(headers, "HTTP/1.1 200 OK")

      expected_length = :erlang.iolist_size(iolist)
      assert String.contains?(headers, "Content-Length: #{expected_length}"),
             "Expected Content-Length: #{expected_length}"

      assert body == expected_body
      assert byte_size(body) == expected_length
    after
      :gen_tcp.close(socket)
    end
  end

  @tag handler_config: %{
         reply_body: [<<"X">>, [], <<"Y">>, [[], <<"Z">>]],
         reply_headers: %{"Content-Type" => "text/plain"}
       }
  test "handles iolist with empty lists with correct content-length", %{port: port} do
    iolist = [<<"X">>, [], <<"Y">>, [[], <<"Z">>]]
    expected_body = "XYZ"
    {:ok, socket} = connect(port)

    try do
      request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      :ok = :gen_tcp.send(socket, request)

      assert {:ok, response} = recv_all(socket)
      [headers, body] = :binary.split(response, <<"\r\n\r\n">>)

      assert String.contains?(headers, "HTTP/1.1 200 OK")

      expected_length = :erlang.iolist_size(iolist)
      assert String.contains?(headers, "Content-Length: #{expected_length}"),
             "Expected Content-Length: #{expected_length}"

      assert body == expected_body
      assert byte_size(body) == expected_length
    after
      :gen_tcp.close(socket)
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

  defp send_chunks(socket, chunks) do
    Enum.each(chunks, fn chunk ->
      :ok = :gen_tcp.send(socket, chunk)
      Process.sleep(@chunk_delay)
    end)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp recv_all(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, @receive_timeout) do
      {:ok, chunk} -> recv_all(socket, <<acc::binary, chunk::binary>>)
      {:error, :closed} -> {:ok, acc}
      error -> error
    end
  end
end
