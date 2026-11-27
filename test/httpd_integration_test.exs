defmodule ApiKeepAliveHandler do
  @moduledoc false
  @behaviour :httpd_api_handler

  @impl true
  def handle_api_request(:get, [<<"open">>], _request, _args), do: {:ok, %{status: "open"}}
  def handle_api_request(:get, [<<"shut">>], _request, _args), do: {:close, %{status: "shut"}}
  def handle_api_request(_method, _path, _request, _args), do: {:error, :not_found}
end

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

    on_exit(fn -> safe_stop(server) end)

    {:ok, port: port}
  end

  # The server is linked to the test process (start_link) and traps exits, so it
  # shuts down as the test process exits — racing on_exit's stop. Tolerate a
  # server that is already gone.
  defp safe_stop(server) do
    if Process.alive?(server) do
      try do
        :httpd.stop(server)
      catch
        :exit, _ -> :ok
      end
    end
  end

  test "reassembles POST bodies across tcp frames", %{port: port} do
    {:ok, socket} = connect(port)

    try do
      request_chunks = [
        "POST / HTTP/1.1\r\nHost: example.com\r\ncontent-length: 11\r\n\r\nhe",
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
      assert <<"value123">> = Map.fetch!(headers, <<"x-custom-header">>)

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
      assert String.contains?(headers, "content-length: " <> @large_iolist_len)
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

      assert String.contains?(headers, "content-length: #{expected_length}"),
             "Expected content-length: #{expected_length}"

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

      assert String.contains?(headers, "content-length: #{expected_length}"),
             "Expected content-length: #{expected_length}"

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

      assert String.contains?(headers, "content-length: #{expected_length}"),
             "Expected content-length: #{expected_length}"

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

      assert String.contains?(headers, "content-length: #{expected_length}"),
             "Expected content-length: #{expected_length}"

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

      assert String.contains?(headers, "content-length: #{expected_length}"),
             "Expected content-length: #{expected_length}"

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

      assert String.contains?(headers, "content-length: #{expected_length}"),
             "Expected content-length: #{expected_length}"

      assert body == expected_body
      assert byte_size(body) == expected_length
    after
      :gen_tcp.close(socket)
    end
  end

  describe "chunk_size socket option" do
    # Deliberately small chunk size to exercise multi-chunk send path on a
    # small test body, and verify the key is stripped so socket:setopt is
    # never called with it (which would crash with a badmatch).
    @small_chunk 512
    @large_response_body :binary.copy("x", 16_384)

    setup do
      port = find_free_tcp_port()

      config = [
        {[], %{handler: TestEchoHandler, handler_config: %{test_pid: self()}}}
      ]

      {:ok, server} =
        :httpd.start_link(:any, port, %{chunk_size: @small_chunk}, config)

      Process.sleep(20)

      on_exit(fn ->
        safe_stop(server)
      end)

      {:ok, port: port}
    end

    test "server starts successfully with chunk_size option (option is not passed to socket:setopt)",
         %{port: port} do
      # If chunk_size leaked into set_socket_options/2 the server would have
      # crashed at startup — this assertion also validates that.
      {:ok, socket} = connect(port)

      try do
        :ok =
          :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")

        assert {:ok, response} = recv_all(socket)
        assert response =~ "HTTP/1.1 200 OK"
      after
        :gen_tcp.close(socket)
      end
    end

    test "large response body is delivered intact across many small chunks" do
      # Start a fresh server whose handler is configured to reply with the large
      # body — this exercises the multi-chunk send path without coupling to the
      # echo handler's default behaviour.
      port = find_free_tcp_port()
      body_size = byte_size(@large_response_body)

      config = [
        {[],
         %{
           handler: TestEchoHandler,
           handler_config: %{
             test_pid: self(),
             reply_body: @large_response_body,
             reply_headers: %{"Content-Type" => "application/octet-stream"}
           }
         }}
      ]

      {:ok, server} =
        :httpd.start_link(:any, port, %{chunk_size: @small_chunk}, config)

      Process.sleep(20)

      {:ok, socket} = connect(port)

      try do
        :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")

        assert_receive {:http_request, _}, @receive_timeout

        assert {:ok, response} = recv_all(socket)
        assert response =~ "HTTP/1.1 200 OK"

        [_headers, body] = :binary.split(response, <<"\r\n\r\n">>)

        assert byte_size(body) == body_size,
               "Expected #{body_size} bytes; got #{byte_size(body)}"
      after
        :gen_tcp.close(socket)
        :httpd.stop(server)
      end
    end
  end

  describe "httpd_file_handler gzip support" do
    @gz_body :binary.copy("g", 128)
    @plain_index "<html>index</html>"
    @plain_js "console.log('plain');"

    setup do
      :atomvm.reset_priv()

      :atomvm.put_priv(:test_app, "index.html.gz", @gz_body)
      :atomvm.put_priv(:test_app, "index.html", @plain_index)
      :atomvm.put_priv(:test_app, "js/app.js.gz", @gz_body)
      :atomvm.put_priv(:test_app, "js/app.js", @plain_js)
      :atomvm.put_priv(:test_app, "css/style.css", "body{}")

      port = find_free_tcp_port()

      config = [
        {[], %{handler: :httpd_file_handler, handler_config: %{app: :test_app}}}
      ]

      {:ok, server} = :httpd.start_link(port, config)
      Process.sleep(20)

      on_exit(fn ->
        :atomvm.reset_priv()
        safe_stop(server)
      end)

      {:ok, port: port}
    end

    test "serves pre-compressed .gz assets when the client accepts gzip", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok =
          :gen_tcp.send(
            socket,
            "GET /js/app.js HTTP/1.1\r\nHost: example.com\r\nAccept-Encoding: gzip, deflate\r\n\r\n"
          )

        assert {:ok, response} = recv_one_response(socket)
        assert response =~ "HTTP/1.1 200 OK"
        assert response =~ "content-encoding: gzip"
        assert response =~ "content-type: text/javascript"

        [_headers, body] = :binary.split(response, <<"\r\n\r\n">>)
        assert byte_size(body) == byte_size(@gz_body)

        # Connection stays open for a subsequent keep-alive request.
        :ok =
          :gen_tcp.send(
            socket,
            "GET / HTTP/1.1\r\nHost: example.com\r\nAccept-Encoding: gzip\r\n\r\n"
          )

        assert {:ok, response2} = recv_one_response(socket)
        assert response2 =~ "HTTP/1.1 200 OK"
        assert response2 =~ "content-encoding: gzip"
        assert response2 =~ "content-type: text/html"
      after
        :gen_tcp.close(socket)
      end
    end

    test "serves compressed assets for mixed-case Accept-Encoding with Connection: close", %{
      port: port
    } do
      {:ok, socket} = connect(port)

      try do
        :ok =
          :gen_tcp.send(
            socket,
            "GET /js/app.js HTTP/1.1\r\nHost: example.com\r\nAccept-Encoding: GZip\r\nConnection: close\r\n\r\n"
          )

        # recv_all/1 returns once the server closes the socket, so a clean close
        # (rather than a timeout) proves Connection: close was honoured.
        assert {:ok, response} = recv_all(socket)
        assert response =~ "HTTP/1.1 200 OK"
        assert response =~ "content-encoding: gzip"
        assert response =~ "content-type: text/javascript"

        [_headers, body] = :binary.split(response, <<"\r\n\r\n">>)
        assert body == @gz_body
      after
        :gen_tcp.close(socket)
      end
    end

    test "falls back to the uncompressed file when no .gz exists", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok =
          :gen_tcp.send(
            socket,
            "GET /css/style.css HTTP/1.1\r\nHost: example.com\r\nAccept-Encoding: gzip\r\n\r\n"
          )

        assert {:ok, response} = recv_one_response(socket)
        assert response =~ "HTTP/1.1 200 OK"
        assert response =~ "content-type: text/css"
        refute response =~ "content-encoding"

        [_headers, body] = :binary.split(response, <<"\r\n\r\n">>)
        assert body == "body{}"
      after
        :gen_tcp.close(socket)
      end
    end

    test "serves the uncompressed file when the client does not accept gzip", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok =
          :gen_tcp.send(
            socket,
            "GET /js/app.js HTTP/1.1\r\nHost: example.com\r\nAccept-Encoding: identity\r\n\r\n"
          )

        assert {:ok, response} = recv_one_response(socket)
        assert response =~ "HTTP/1.1 200 OK"
        assert response =~ "content-type: text/javascript"
        refute response =~ "content-encoding"

        [_headers, body] = :binary.split(response, <<"\r\n\r\n">>)
        assert body == @plain_js
      after
        :gen_tcp.close(socket)
      end
    end

    test "returns 404 when neither the file nor its .gz exists", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok =
          :gen_tcp.send(
            socket,
            "GET /missing.js HTTP/1.1\r\nHost: example.com\r\nAccept-Encoding: gzip\r\n\r\n"
          )

        assert {:ok, response} = recv_one_response(socket)
        assert response =~ "404"
        assert response =~ "not_found"
      after
        :gen_tcp.close(socket)
      end
    end
  end

  describe "request timeout" do
    # A deliberately short timeout so tests finish quickly.
    @timeout_ms 300

    # Start a second httpd with the short timeout; override :port in context.
    setup do
      port = find_free_tcp_port()

      config = [
        {[], %{handler: TestEchoHandler, handler_config: %{test_pid: self(), reply_mode: :reply}}}
      ]

      {:ok, server} =
        :httpd.start_link(:any, port, %{}, %{request_timeout: @timeout_ms}, config)

      Process.sleep(20)

      on_exit(fn ->
        safe_stop(server)
      end)

      {:ok, port: port}
    end

    test "closes socket when request headers are never completed", %{port: port} do
      {:ok, socket} = connect(port)
      # Send an incomplete request — no \r\n\r\n header terminator, so the
      # server buffers and starts the request timer.
      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: example.com\r\n")

      # Wait well past the configured timeout and expect the server to close.
      Process.sleep(@timeout_ms + 200)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 500)
      :gen_tcp.close(socket)
    end

    test "closes socket when declared body is never fully delivered", %{port: port} do
      {:ok, socket} = connect(port)
      # Headers are complete, but Content-Length claims 100 bytes and we only
      # send 5.  The server should start waiting for the rest and time out.
      :ok =
        :gen_tcp.send(
          socket,
          "POST / HTTP/1.1\r\nHost: example.com\r\ncontent-length: 100\r\n\r\nhello"
        )

      Process.sleep(@timeout_ms + 200)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 500)
      :gen_tcp.close(socket)
    end

    test "does not close an idle keep-alive connection", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        assert {:ok, response} = recv_one_response(socket)
        assert response =~ "HTTP/1.1 200 OK"

        # No request is in flight, so the request timer firing must not close
        # the connection (HTTP/1.1 keep-alive).
        Process.sleep(@timeout_ms + 200)

        :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        assert {:ok, response2} = recv_one_response(socket)
        assert response2 =~ "HTTP/1.1 200 OK"
      after
        :gen_tcp.close(socket)
      end
    end
  end

  describe "concurrent connections" do
    # A large response so that, under the old single-gen_server design, serving
    # it would block other connections. With per-connection worker processes,
    # small requests on other connections must stay responsive.
    @big_body :binary.copy("y", 262_144)

    setup do
      port = find_free_tcp_port()

      config = [
        {[<<"big">>],
         %{
           handler: TestEchoHandler,
           handler_config: %{
             reply_body: @big_body,
             reply_headers: %{"Content-Type" => "text/plain"}
           }
         }},
        {[], %{handler: TestEchoHandler, handler_config: %{reply_body: "small"}}}
      ]

      # Tiny chunk_size so the big response takes many send iterations.
      {:ok, server} = :httpd.start_link(:any, port, %{chunk_size: 256}, config)
      Process.sleep(20)
      on_exit(fn -> safe_stop(server) end)
      {:ok, port: port}
    end

    test "multiple connections are served independently", %{port: port} do
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            {:ok, socket} = connect(port)
            :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            result = recv_all(socket)
            :gen_tcp.close(socket)
            result
          end)
        end

      for result <- Task.await_many(tasks, 5_000) do
        assert {:ok, response} = result
        assert response =~ "HTTP/1.1 200 OK"
        [_headers, body] = :binary.split(response, <<"\r\n\r\n">>)
        assert body == "small"
      end
    end

    test "a large response does not block small ones", %{port: port} do
      # Kick off a 256KB download on one connection.
      big_task =
        Task.async(fn ->
          {:ok, socket} = connect(port)
          :ok = :gen_tcp.send(socket, "GET /big HTTP/1.1\r\nHost: x\r\n\r\n")
          result = recv_all(socket)
          :gen_tcp.close(socket)
          result
        end)

      # While it's streaming, small requests on independent connections must
      # complete quickly.
      for _ <- 1..5 do
        {elapsed_us, _} =
          :timer.tc(fn ->
            {:ok, socket} = connect(port)
            :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            assert {:ok, response} = recv_all(socket)
            assert response =~ "HTTP/1.1 200 OK"
            :gen_tcp.close(socket)
          end)

        assert elapsed_us < 1_000_000,
               "small request took #{elapsed_us}us while large response was streaming"
      end

      assert {:ok, big_response} = Task.await(big_task, 10_000)
      [_headers, big_body] = :binary.split(big_response, <<"\r\n\r\n">>)
      assert byte_size(big_body) == byte_size(@big_body)
    end
  end

  describe "keep-alive connections" do
    @tag handler_config: %{reply_mode: :reply}
    test "serves multiple sequential GET/POST requests on one HTTP/1.1 connection", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok = :gen_tcp.send(socket, "GET /one HTTP/1.1\r\nHost: example.com\r\n\r\n")
        assert_receive {:http_request, get_request}, @receive_timeout
        assert get_request.method == :get

        assert {:ok, response1} = recv_one_response(socket)
        assert response1 =~ "HTTP/1.1 200 OK"

        body = "hello"

        :ok =
          :gen_tcp.send(
            socket,
            "POST /two HTTP/1.1\r\nHost: example.com\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
          )

        assert_receive {:http_request, post_request}, @receive_timeout
        assert post_request.method == :post
        assert post_request.body == body

        assert {:ok, response2} = recv_one_response(socket)
        assert response2 =~ "HTTP/1.1 200 OK"

        :ok = :gen_tcp.send(socket, "GET /three HTTP/1.1\r\nHost: example.com\r\n\r\n")
        assert_receive {:http_request, get_request3}, @receive_timeout
        assert get_request3.method == :get

        assert {:ok, response3} = recv_one_response(socket)
        assert response3 =~ "HTTP/1.1 200 OK"
      after
        :gen_tcp.close(socket)
      end
    end

    @tag handler_config: %{reply_mode: :reply}
    test "Connection: close closes even when the handler returns reply", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok =
          :gen_tcp.send(
            socket,
            "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
          )

        # recv_all only returns once the server closes the connection.
        assert {:ok, response} = recv_all(socket)
        assert response =~ "HTTP/1.1 200 OK"
      after
        :gen_tcp.close(socket)
      end
    end

    @tag handler_config: %{reply_mode: :reply}
    test "HTTP/1.0 closes by default even when the handler returns reply", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok = :gen_tcp.send(socket, "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n")

        assert {:ok, response} = recv_all(socket)
        assert response =~ "HTTP/1.1 200 OK"
      after
        :gen_tcp.close(socket)
      end
    end

    @tag handler_config: %{reply_mode: :reply}
    test "HTTP/1.0 stays open when Connection: keep-alive is sent", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok =
          :gen_tcp.send(
            socket,
            "GET /first HTTP/1.0\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n"
          )

        assert {:ok, response1} = recv_one_response(socket)
        assert response1 =~ "HTTP/1.1 200 OK"

        :ok =
          :gen_tcp.send(
            socket,
            "GET /second HTTP/1.0\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n"
          )

        assert {:ok, response2} = recv_one_response(socket)
        assert response2 =~ "HTTP/1.1 200 OK"
      after
        :gen_tcp.close(socket)
      end
    end

    @tag handler_config: %{reply_mode: :reply}
    test "preserves pipelined bytes after a Content-Length body", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        # The POST body is exactly 5 bytes ("hello"); the trailing bytes start
        # the next request and must be buffered, not appended to the body.
        :ok =
          :gen_tcp.send(
            socket,
            "POST /first HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhelloGET /n"
          )

        assert_receive {:http_request, first}, @receive_timeout
        assert first.method == :post
        assert first.body == "hello"

        assert {:ok, response1} = recv_one_response(socket)
        assert response1 =~ "HTTP/1.1 200 OK"

        # Complete the partially-buffered second request.
        :ok = :gen_tcp.send(socket, "ext HTTP/1.1\r\nHost: example.com\r\n\r\n")

        assert_receive {:http_request, second}, @receive_timeout
        assert second.method == :get
        assert second.path == [<<"next">>]

        assert {:ok, response2} = recv_one_response(socket)
        assert response2 =~ "HTTP/1.1 200 OK"
      after
        :gen_tcp.close(socket)
      end
    end
  end

  test "reassembles a 20KB body delivered in many small chunks", %{port: port} do
    body = :binary.copy("z", 20_000)
    {:ok, socket} = connect(port)

    try do
      :ok =
        :gen_tcp.send(
          socket,
          "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: #{byte_size(body)}\r\n\r\n"
        )

      send_chunks(socket, chunk_binary(body, 512))

      assert_receive {:http_request, request}, @receive_timeout
      assert request.method == :post
      assert request.body == body

      assert {:ok, response} = recv_all(socket)
      assert response =~ "HTTP/1.1 200 OK"
    after
      :gen_tcp.close(socket)
    end
  end

  describe "httpd_api_handler keep-alive semantics" do
    setup do
      port = find_free_tcp_port()

      config = [
        {[<<"api">>],
         %{handler: :httpd_api_handler, handler_config: %{module: ApiKeepAliveHandler, args: nil}}}
      ]

      {:ok, server} = :httpd.start_link(port, config)
      Process.sleep(20)

      on_exit(fn -> safe_stop(server) end)

      {:ok, port: port}
    end

    test "{ok, Map} keeps an HTTP/1.1 connection open", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok = :gen_tcp.send(socket, "GET /api/open HTTP/1.1\r\nHost: example.com\r\n\r\n")
        assert {:ok, response1} = recv_one_response(socket)
        assert response1 =~ "HTTP/1.1 200 OK"
        assert response1 =~ "application/json"

        :ok = :gen_tcp.send(socket, "GET /api/open HTTP/1.1\r\nHost: example.com\r\n\r\n")
        assert {:ok, response2} = recv_one_response(socket)
        assert response2 =~ "HTTP/1.1 200 OK"
      after
        :gen_tcp.close(socket)
      end
    end

    test "{close, Map} closes the connection", %{port: port} do
      {:ok, socket} = connect(port)

      try do
        :ok = :gen_tcp.send(socket, "GET /api/shut HTTP/1.1\r\nHost: example.com\r\n\r\n")

        # recv_all returns once the server closes the connection.
        assert {:ok, response} = recv_all(socket)
        assert response =~ "HTTP/1.1 200 OK"
        assert response =~ "application/json"

        assert {:error, reason} = :gen_tcp.recv(socket, 0, @receive_timeout)
        assert reason in [:closed, :enotconn]
      after
        :gen_tcp.close(socket)
      end
    end

    test "function-based handler with {ok, Map, FunState} replies" do
      api_fun = fn :get, _path, _request, _args -> {:ok, %{fun: true}, :fun_state} end
      fn_port = find_free_tcp_port()

      config = [
        {[<<"fnapi">>],
         %{handler: :httpd_api_handler, handler_config: %{module: api_fun, args: nil}}}
      ]

      {:ok, server} = :httpd.start_link(fn_port, config)
      Process.sleep(20)

      {:ok, socket} = connect(fn_port)

      try do
        :ok = :gen_tcp.send(socket, "GET /fnapi/x HTTP/1.1\r\nHost: example.com\r\n\r\n")
        assert {:ok, response} = recv_one_response(socket)
        assert response =~ "HTTP/1.1 200 OK"
        assert response =~ "application/json"

        # The connection stays open, so a second request still succeeds.
        :ok = :gen_tcp.send(socket, "GET /fnapi/y HTTP/1.1\r\nHost: example.com\r\n\r\n")
        assert {:ok, response2} = recv_one_response(socket)
        assert response2 =~ "HTTP/1.1 200 OK"
      after
        :gen_tcp.close(socket)
        safe_stop(server)
      end
    end
  end

  test "AtomvmHttpd.start_link/5 works with socket and server options" do
    port = find_free_tcp_port()
    config = [{[], %{handler: TestEchoHandler, handler_config: %{test_pid: self()}}}]

    {:ok, server} =
      AtomvmHttpd.start_link(
        :any,
        port,
        %{chunk_size: 1024, send_timeout: 5000},
        %{request_timeout: 5000},
        config
      )

    Process.sleep(20)
    {:ok, socket} = connect(port)

    try do
      :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")

      assert {:ok, response} = recv_all(socket)
      assert response =~ "HTTP/1.1 200 OK"
    after
      :gen_tcp.close(socket)
      safe_stop(server)
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

  # Receive exactly one keep-alive HTTP response (headers + Content-Length body),
  # leaving the connection open for subsequent requests.
  defp recv_one_response(socket, acc \\ <<>>) do
    case :binary.split(acc, "\r\n\r\n") do
      [_headers] ->
        case :gen_tcp.recv(socket, 0, @receive_timeout) do
          {:ok, chunk} -> recv_one_response(socket, acc <> chunk)
          error -> error
        end

      [headers, rest] ->
        body_len = response_content_length(headers)

        if byte_size(rest) >= body_len do
          {:ok, headers <> "\r\n\r\n" <> binary_part(rest, 0, body_len)}
        else
          case :gen_tcp.recv(socket, 0, @receive_timeout) do
            {:ok, chunk} -> recv_one_response(socket, acc <> chunk)
            error -> error
          end
        end
    end
  end

  defp response_content_length(headers) do
    case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
      [_, len] -> String.to_integer(len)
      _ -> 0
    end
  end

  defp chunk_binary(binary, chunk_size) do
    for <<chunk::binary-size(^chunk_size) <- binary>> do
      chunk
    end
    |> append_remainder(binary, chunk_size)
  end

  defp append_remainder(chunks, binary, chunk_size) do
    remainder = rem(byte_size(binary), chunk_size)

    case remainder do
      0 ->
        chunks

      _ ->
        chunks ++ [binary_part(binary, byte_size(binary) - remainder, remainder)]
    end
  end
end
