defmodule ElixirTcpTest do
  use ExUnit.Case

  @moduledoc """
  TCP Echo Server stress tests.

  Configure the target server with environment variables:
    TCP_TEST_HOST - IP address of the echo server (default: "127.0.0.1")
    TCP_TEST_PORT - Port of the echo server (default: "9090")

  Example:
    TCP_TEST_HOST=192.168.25.103 TCP_TEST_PORT=9090 mix test
  """

  @default_host "127.0.0.1"
  @default_port 9090
  @connect_timeout 5_000
  @recv_timeout 5_000

  setup_all do
    host =
      System.get_env("TCP_TEST_HOST", @default_host)
      |> String.to_charlist()

    port =
      System.get_env("TCP_TEST_PORT", "#{@default_port}")
      |> String.to_integer()

    %{host: host, port: port}
  end

  defp connect(host, port) do
    :gen_tcp.connect(host, port, [:binary, active: false, packet: :raw], @connect_timeout)
  end

  defp send_and_recv(socket, data) do
    :ok = :gen_tcp.send(socket, data)
    :gen_tcp.recv(socket, byte_size(data), @recv_timeout)
  end

  describe "basic connectivity" do
    test "connects to server", %{host: host, port: port} do
      assert {:ok, socket} = connect(host, port)
      :gen_tcp.close(socket)
    end

    test "multiple sequential connections", %{host: host, port: port} do
      for _ <- 1..10 do
        {:ok, socket} = connect(host, port)
        :gen_tcp.close(socket)
      end
    end

    test "handles connection close gracefully", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)
      :ok = :gen_tcp.close(socket)

      # Should be able to reconnect immediately
      {:ok, socket2} = connect(host, port)
      :gen_tcp.close(socket2)
    end
  end

  describe "echo functionality" do
    test "echoes simple message", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      message = "Hello, World!"
      assert {:ok, ^message} = send_and_recv(socket, message)

      :gen_tcp.close(socket)
    end

    test "echoes binary data", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      # Binary with non-printable characters
      message = <<0, 1, 2, 3, 255, 254, 253, 252>>
      assert {:ok, ^message} = send_and_recv(socket, message)

      :gen_tcp.close(socket)
    end

    test "echoes multiple messages on same connection", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      for i <- 1..20 do
        message = "Message #{i}"
        assert {:ok, ^message} = send_and_recv(socket, message)
      end

      :gen_tcp.close(socket)
    end

    test "echoes empty-ish message (single byte)", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      message = "x"
      assert {:ok, ^message} = send_and_recv(socket, message)

      :gen_tcp.close(socket)
    end
  end

  describe "payload sizes" do
    test "echoes small payload (100 bytes)", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      message = :crypto.strong_rand_bytes(100)
      assert {:ok, ^message} = send_and_recv(socket, message)

      :gen_tcp.close(socket)
    end

    test "echoes medium payload (1KB)", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      message = :crypto.strong_rand_bytes(1024)
      :ok = :gen_tcp.send(socket, message)

      # May need to recv in chunks for larger payloads
      {:ok, response} = recv_all(socket, byte_size(message))
      assert response == message

      :gen_tcp.close(socket)
    end

    test "echoes large payload (10KB)", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      message = :crypto.strong_rand_bytes(10 * 1024)
      :ok = :gen_tcp.send(socket, message)

      {:ok, response} = recv_all(socket, byte_size(message))
      assert response == message

      :gen_tcp.close(socket)
    end

    @tag :slow
    test "echoes very large payload (100KB)", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      message = :crypto.strong_rand_bytes(100 * 1024)
      :ok = :gen_tcp.send(socket, message)

      {:ok, response} = recv_all(socket, byte_size(message), 30_000)
      assert response == message

      :gen_tcp.close(socket)
    end
  end

  describe "concurrent connections" do
    test "handles 5 concurrent connections", %{host: host, port: port} do
      run_concurrent_echo_test(host, port, 5)
    end

    test "handles 10 concurrent connections", %{host: host, port: port} do
      run_concurrent_echo_test(host, port, 10)
    end

    @tag :slow
    test "handles 20 concurrent connections", %{host: host, port: port} do
      run_concurrent_echo_test(host, port, 20)
    end
  end

  describe "stress tests" do
    @tag :slow
    test "rapid fire messages (100 messages)", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      for i <- 1..100 do
        message = "Rapid #{i}"
        assert {:ok, ^message} = send_and_recv(socket, message)
      end

      :gen_tcp.close(socket)
    end

    @tag :slow
    test "sustained load (1000 small messages)", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      for i <- 1..1000 do
        message = "Msg#{i}"
        assert {:ok, ^message} = send_and_recv(socket, message)
      end

      :gen_tcp.close(socket)
    end

    @tag :slow
    test "mixed payload sizes", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      sizes = [1, 10, 100, 500, 1000, 100, 10, 1]

      for size <- sizes do
        message = :crypto.strong_rand_bytes(size)
        :ok = :gen_tcp.send(socket, message)
        {:ok, response} = recv_all(socket, size)
        assert response == message
      end

      :gen_tcp.close(socket)
    end

    @tag :slow
    test "connection churn (50 connect/disconnect cycles)", %{host: host, port: port} do
      for i <- 1..50 do
        {:ok, socket} = connect(host, port)
        message = "Churn test #{i}"
        assert {:ok, ^message} = send_and_recv(socket, message)
        :gen_tcp.close(socket)
      end
    end
  end

  describe "edge cases" do
    test "handles newlines in message", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      message = "Line1\nLine2\r\nLine3\n"
      assert {:ok, ^message} = send_and_recv(socket, message)

      :gen_tcp.close(socket)
    end

    test "handles unicode", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      message = "Hello 世界 🌍 émoji"
      assert {:ok, ^message} = send_and_recv(socket, message)

      :gen_tcp.close(socket)
    end

    test "handles null bytes", %{host: host, port: port} do
      {:ok, socket} = connect(host, port)

      message = "before\x00after"
      assert {:ok, ^message} = send_and_recv(socket, message)

      :gen_tcp.close(socket)
    end
  end

  # Helper functions

  defp recv_all(socket, expected_size, timeout \\ @recv_timeout) do
    recv_all(socket, expected_size, <<>>, timeout)
  end

  defp recv_all(_socket, expected_size, acc, _timeout) when byte_size(acc) >= expected_size do
    {:ok, acc}
  end

  defp recv_all(socket, expected_size, acc, timeout) do
    remaining = expected_size - byte_size(acc)

    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        recv_all(socket, expected_size, acc <> data, timeout)

      {:error, :timeout} when byte_size(acc) > 0 ->
        # Return what we have if we timeout with partial data
        {:ok, acc}

      error ->
        error
    end
  end

  defp run_concurrent_echo_test(host, port, num_connections) do
    parent = self()

    tasks =
      for i <- 1..num_connections do
        Task.async(fn ->
          {:ok, socket} = connect(host, port)

          for j <- 1..10 do
            message = "Conn#{i}-Msg#{j}"
            {:ok, response} = send_and_recv(socket, message)
            assert response == message
          end

          :gen_tcp.close(socket)
          :ok
        end)
      end

    results = Task.await_many(tasks, 30_000)
    assert Enum.all?(results, &(&1 == :ok))
  end
end
