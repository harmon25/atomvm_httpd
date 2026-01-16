defmodule ElixirHttpTest do
  use ExUnit.Case

  @moduledoc """
  HTTP Server stress tests.

  Configure the target server with environment variables:
    HTTP_TEST_HOST - IP address of the HTTP server (default: "127.0.0.1")
    HTTP_TEST_PORT - Port of the HTTP server (default: "8080")

  Example:
    HTTP_TEST_HOST=192.168.25.103 HTTP_TEST_PORT=8080 mix test
  """

  @default_host "127.0.0.1"
  @default_port 8080
  @request_timeout 10_000
  # Disable retries - if it fails, we want to know immediately
  @req_opts [receive_timeout: @request_timeout, retry: false]

  setup_all do
    host = System.get_env("HTTP_TEST_HOST", @default_host)
    port = System.get_env("HTTP_TEST_PORT", "#{@default_port}") |> String.to_integer()
    base_url = "http://#{host}:#{port}"

    %{host: host, port: port, base_url: base_url}
  end

  # Helper to make requests with consistent options
  defp req_get(url), do: Req.get(url, @req_opts)
  defp req_head(url), do: Req.head(url, @req_opts)

  # Verify Content-Length header matches actual body size
  defp verify_content_length(response) do
    content_length = get_content_length(response)
    body_size = byte_size(response.body)

    if content_length do
      assert content_length == body_size,
             "Content-Length mismatch: header=#{content_length}, body=#{body_size}"
    end

    response
  end

  defp get_content_length(response) do
    case Req.Response.get_header(response, "content-length") do
      [value | _] -> String.to_integer(value)
      [] -> nil
    end
  end

  describe "basic connectivity" do
    test "connects to server", %{base_url: base_url} do
      assert {:ok, response} = req_get(base_url)
      assert response.status in [200, 304]
    end

    test "multiple sequential requests", %{base_url: base_url} do
      for _ <- 1..10 do
        {:ok, response} = req_get(base_url)
        assert response.status in [200, 304]
      end
    end
  end

  describe "static file serving" do
    test "serves index.html at root", %{base_url: base_url} do
      {:ok, response} = req_get(base_url)
      assert response.status == 200
      verify_content_length(response)

      assert String.contains?(response.body, "<!DOCTYPE html>") or
               String.contains?(response.body, "<html")
    end

    test "serves index.html explicitly", %{base_url: base_url} do
      {:ok, response} = req_get("#{base_url}/index.html")
      assert response.status == 200
      verify_content_length(response)
    end

    test "serves favicon", %{base_url: base_url} do
      {:ok, response} = req_get("#{base_url}/favicon.ico")
      assert response.status == 200
      verify_content_length(response)
    end

    test "serves app.js", %{base_url: base_url} do
      {:ok, response} = req_get("#{base_url}/js/app.js")
      assert response.status == 200
      verify_content_length(response)
    end

    test "returns 404 for missing file", %{base_url: base_url} do
      {:ok, response} = req_get("#{base_url}/nonexistent.html")
      assert response.status == 404
    end
  end

  describe "API endpoints" do
    test "GET /api/system_info returns JSON", %{base_url: base_url} do
      {:ok, response} = req_get("#{base_url}/api/system_info")
      assert response.status == 200
      assert is_map(response.body)
      assert Map.has_key?(response.body, "platform")
    end

    test "GET /api/memory returns memory data", %{base_url: base_url} do
      {:ok, response} = req_get("#{base_url}/api/memory")
      assert response.status == 200
      assert is_map(response.body)
      # Check for expected memory fields
      assert Map.has_key?(response.body, "atom_count") or
               Map.has_key?(response.body, "process_count")
    end

    test "GET /api/unknown returns 404", %{base_url: base_url} do
      {:ok, response} = req_get("#{base_url}/api/unknown")
      assert response.status == 404
    end

    test "multiple API requests on same connection", %{base_url: base_url} do
      for _ <- 1..20 do
        {:ok, response} = req_get("#{base_url}/api/system_info")
        assert response.status == 200
      end
    end
  end

  describe "concurrent connections" do
    test "handles 5 concurrent requests", %{base_url: base_url} do
      run_concurrent_requests(base_url, 5)
    end

    # ESP32 lwIP has limited socket resources - 10+ concurrent connections
    # may exceed platform limits. Mark as slow for stress testing only.
    # @tag :slow
    # test "handles 10 concurrent requests", %{base_url: base_url} do
    #   run_concurrent_requests(base_url, 10)
    # end
  end

  describe "stress tests" do
    @tag :slow
    test "rapid fire requests (50 requests)", %{base_url: base_url} do
      for i <- 1..50 do
        {:ok, response} = req_get("#{base_url}/api/system_info")
        assert response.status == 200, "Request #{i} failed"
      end
    end

    @tag :slow
    test "sustained load (250 requests)", %{base_url: base_url} do
      for i <- 1..250 do
        {:ok, response} = req_get(base_url)
        assert response.status in [200, 304], "Request #{i} failed with status #{response.status}"
      end
    end

    @tag :slow
    test "mixed endpoint requests", %{base_url: base_url} do
      endpoints = [
        "/",
        "/index.html",
        "/api/system_info",
        "/api/memory"
      ]

      for _ <- 1..25 do
        endpoint = Enum.random(endpoints)
        {:ok, response} = req_get("#{base_url}#{endpoint}")
        assert response.status == 200, "Request to #{endpoint} failed"
      end
    end

    @tag :slow
    test "concurrent mixed requests (5 clients, 10 requests each)", %{base_url: base_url} do
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            endpoints = ["/", "/api/system_info", "/api/memory"]

            for j <- 1..10 do
              endpoint = Enum.at(endpoints, rem(j, 3))
              {:ok, response} = req_get("#{base_url}#{endpoint}")
              assert response.status == 200
            end

            :ok
          end)
        end

      results = Task.await_many(tasks, 120_000)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  describe "HTTP methods and edge cases" do
    @tag :skip
    test "HEAD request works", %{base_url: base_url} do
      # HEAD is not currently supported by httpd
      {:ok, response} = req_head(base_url)
      assert response.status in [200, 304]
    end

    test "handles query parameters", %{base_url: base_url} do
      {:ok, response} = req_get("#{base_url}/api/system_info?foo=bar")
      assert response.status == 200
    end

    test "handles URL-encoded paths", %{base_url: base_url} do
      # Request for a file that doesn't exist but tests URL handling
      {:ok, response} = req_get("#{base_url}/test%20file.html")
      assert response.status == 404
    end
  end

  describe "WebSocket" do
    test "connects to WebSocket endpoint", %{host: host, port: port} do
      ws_url = "ws://#{host}:#{port}/ws"

      {:ok, pid} = WebSockex.start_link(ws_url, ElixirHttpTest.WsClient, %{parent: self()})
      assert Process.alive?(pid)

      # Send ping and expect pong
      WebSockex.send_frame(pid, {:text, "ping"})

      assert_receive {:ws_message, "pong"}, 5_000

      WebSockex.cast(pid, :close)
    end

    @tag :slow
    test "multiple WebSocket messages", %{host: host, port: port} do
      ws_url = "ws://#{host}:#{port}/ws"

      {:ok, pid} = WebSockex.start_link(ws_url, ElixirHttpTest.WsClient, %{parent: self()})

      for _ <- 1..20 do
        WebSockex.send_frame(pid, {:text, "ping"})
        assert_receive {:ws_message, "pong"}, 5_000
      end

      WebSockex.cast(pid, :close)
    end

    @tag :slow
    test "multiple concurrent WebSocket connections", %{host: host, port: port} do
      ws_url = "ws://#{host}:#{port}/ws"

      pids =
        for _ <- 1..5 do
          {:ok, pid} = WebSockex.start_link(ws_url, ElixirHttpTest.WsClient, %{parent: self()})
          pid
        end

      # Send ping from all connections
      for pid <- pids do
        WebSockex.send_frame(pid, {:text, "ping"})
      end

      # Expect pong from all connections
      for _ <- pids do
        assert_receive {:ws_message, "pong"}, 5_000
      end

      for pid <- pids do
        WebSockex.cast(pid, :close)
      end
    end
  end

  # Helper functions

  defp run_concurrent_requests(base_url, num_requests) do
    tasks =
      for _i <- 1..num_requests do
        Task.async(fn ->
          {:ok, response} = req_get("#{base_url}/api/system_info")
          assert response.status == 200
          :ok
        end)
      end

    results = Task.await_many(tasks, 60_000)
    assert Enum.all?(results, &(&1 == :ok))
  end
end

defmodule ElixirHttpTest.WsClient do
  @moduledoc false
  use WebSockex

  def handle_frame({:text, msg}, %{parent: parent} = state) do
    send(parent, {:ws_message, msg})
    {:ok, state}
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  def handle_cast(:close, state) do
    {:close, state}
  end
end
