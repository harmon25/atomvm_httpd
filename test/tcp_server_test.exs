defmodule TcpServerTest do
  use ExUnit.Case, async: false

  alias AtomvmHttpd.TestEchoProtocol

  @recv_timeout 2_000

  defp start_server(socket_opts \\ %{}, args_extra \\ %{}) do
    port = find_free_tcp_port()
    args = Map.merge(%{test_pid: self()}, args_extra)

    {:ok, server} =
      :tcp_server.start_link(%{port: port}, socket_opts, TestEchoProtocol, args)

    Process.sleep(20)

    on_exit(fn ->
      if Process.alive?(server) do
        try do
          :tcp_server.stop(server)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {server, port}
  end

  describe "basic echo" do
    test "single round-trip" do
      {_server, port} = start_server()
      {:ok, socket} = connect(port)

      try do
        :ok = :gen_tcp.send(socket, "hello")
        assert {:ok, "hello"} = :gen_tcp.recv(socket, 5, @recv_timeout)
        assert_receive {:tcp_init, _socket}, @recv_timeout
        assert_receive {:tcp_data, "hello"}, @recv_timeout
      after
        :gen_tcp.close(socket)
      end
    end

    test "multiple sequential requests on one connection" do
      {_server, port} = start_server()
      {:ok, socket} = connect(port)

      try do
        for n <- 1..10 do
          msg = "msg-#{n}"
          :ok = :gen_tcp.send(socket, msg)
          assert {:ok, echoed} = :gen_tcp.recv(socket, byte_size(msg), @recv_timeout)
          assert echoed == msg
        end
      after
        :gen_tcp.close(socket)
      end
    end

    test "large payload echo (64KB)" do
      {_server, port} = start_server()
      {:ok, socket} = connect(port)
      payload = :binary.copy("z", 65_536)

      try do
        :ok = :gen_tcp.send(socket, payload)
        assert {:ok, echoed} = recv_exact(socket, byte_size(payload))
        assert echoed == payload
      after
        :gen_tcp.close(socket)
      end
    end
  end

  describe "connection lifecycle" do
    test "send_close sends response then closes" do
      {_server, port} = start_server()
      {:ok, socket} = connect(port)

      try do
        :ok = :gen_tcp.send(socket, "CLOSE")
        assert {:ok, "bye"} = :gen_tcp.recv(socket, 3, @recv_timeout)
        # Server closes after sending; next recv should report closed.
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, @recv_timeout)
      after
        :gen_tcp.close(socket)
      end
    end

    test "handle_close fires on peer close" do
      {_server, port} = start_server()
      {:ok, socket} = connect(port)
      :ok = :gen_tcp.send(socket, "hi")
      assert {:ok, "hi"} = :gen_tcp.recv(socket, 2, @recv_timeout)
      :gen_tcp.close(socket)
      assert_receive {:tcp_closed, :closed}, @recv_timeout
    end

    test "rapid connect/disconnect cycles" do
      {_server, port} = start_server()

      for n <- 1..20 do
        {:ok, socket} = connect(port)
        msg = "cycle-#{n}"
        :ok = :gen_tcp.send(socket, msg)
        assert {:ok, ^msg} = :gen_tcp.recv(socket, byte_size(msg), @recv_timeout)
        :gen_tcp.close(socket)
      end

      # Server is still healthy after rapid cycling.
      {:ok, socket} = connect(port)
      :ok = :gen_tcp.send(socket, "final")
      assert {:ok, "final"} = :gen_tcp.recv(socket, 5, @recv_timeout)
      :gen_tcp.close(socket)
    end
  end

  describe "concurrency" do
    test "5 concurrent connections all echo simultaneously" do
      {_server, port} = start_server()

      tasks =
        for n <- 1..5 do
          Task.async(fn ->
            {:ok, socket} = connect(port)
            msg = "conn-#{n}"
            :ok = :gen_tcp.send(socket, msg)
            result = :gen_tcp.recv(socket, byte_size(msg), @recv_timeout)
            :gen_tcp.close(socket)
            {msg, result}
          end)
        end

      for {msg, result} <- Task.await_many(tasks, 5_000) do
        assert {:ok, ^msg} = result
      end
    end

    test "large transfer on one connection does not block small ones" do
      {_server, port} = start_server(%{chunk_size: 512})
      big = :binary.copy("Q", 65_536)

      # Start a slow/large transfer in the background.
      big_task =
        Task.async(fn ->
          {:ok, socket} = connect(port)
          :ok = :gen_tcp.send(socket, big)
          result = recv_exact(socket, byte_size(big))
          :gen_tcp.close(socket)
          result
        end)

      # While the large transfer is in flight, several small requests on
      # independent connections must complete quickly.
      {:ok, s} = connect(port)

      try do
        for n <- 1..5 do
          msg = "small-#{n}"

          {elapsed_us, _} =
            :timer.tc(fn ->
              :ok = :gen_tcp.send(s, msg)
              assert {:ok, ^msg} = :gen_tcp.recv(s, byte_size(msg), @recv_timeout)
            end)

          assert elapsed_us < 1_000_000,
                 "small request #{n} took #{elapsed_us}us while large transfer in flight"
        end
      after
        :gen_tcp.close(s)
      end

      assert {:ok, echoed} = Task.await(big_task, 10_000)
      assert echoed == big
    end
  end

  describe "max_connections" do
    test "rejects connections over the limit" do
      {_server, port} = start_server(%{max_connections: 2})

      # Two persistent connections occupy the two available slots.
      {:ok, c1} = connect(port)
      :ok = :gen_tcp.send(c1, "a")
      assert {:ok, "a"} = :gen_tcp.recv(c1, 1, @recv_timeout)

      {:ok, c2} = connect(port)
      :ok = :gen_tcp.send(c2, "b")
      assert {:ok, "b"} = :gen_tcp.recv(c2, 1, @recv_timeout)

      # Third connection is accepted at the TCP layer then closed by the server.
      {:ok, c3} = connect(port)
      :gen_tcp.send(c3, "c")
      assert {:error, :closed} = recv_until_closed(c3)

      :gen_tcp.close(c1)
      :gen_tcp.close(c2)
    end
  end

  describe "chunk_size option" do
    test "custom chunk_size delivers large body intact" do
      {_server, port} = start_server(%{chunk_size: 512})
      {:ok, socket} = connect(port)
      payload = :binary.copy("x", 16_384)

      try do
        :ok = :gen_tcp.send(socket, payload)
        assert {:ok, echoed} = recv_exact(socket, byte_size(payload))
        assert byte_size(echoed) == byte_size(payload)
        assert echoed == payload
      after
        :gen_tcp.close(socket)
      end
    end
  end

  describe "bounded iodata chunking" do
    test "preserves deeply nested mixed iodata across byte boundaries" do
      data = [<<"ab">>, [99, [<<"defgh">>, []]], [105 | <<"jkl">>]]

      chunks = collect_chunks(data, 4)

      assert Enum.all?(chunks, fn chunk -> :erlang.iolist_size(chunk) <= 4 end)
      assert :erlang.iolist_to_binary(chunks) == "abcdefghijkl"
    end

    test "bounds temporary entries for many one-byte elements" do
      data = List.duplicate(?x, 1_000)
      [first | _] = chunks = collect_chunks(data, 4_096)

      assert length(first) == 64
      assert Enum.all?(chunks, fn chunk -> length(chunk) <= 64 end)
      assert :erlang.iolist_to_binary(chunks) == :binary.copy("x", 1_000)
    end

    test "rejects invalid iodata and chunk sizes" do
      assert catch_error(:tcp_server.next_chunk([256], 32)) == :badarg
      assert catch_error(:tcp_server.next_chunk("ok", 0)) == :badarg
    end
  end

  ## helpers

  defp connect(port) do
    :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw])
  end

  defp collect_chunks(iodata, chunk_size, acc \\ []) do
    case :tcp_server.next_chunk(iodata, chunk_size) do
      :done -> Enum.reverse(acc)
      {chunk, rest} -> collect_chunks(rest, chunk_size, [chunk | acc])
    end
  end

  defp find_free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Receive exactly `n` bytes, looping across TCP frames.
  defp recv_exact(socket, n, acc \\ <<>>)
  defp recv_exact(_socket, 0, acc), do: {:ok, acc}

  defp recv_exact(socket, n, acc) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, chunk} ->
        acc = <<acc::binary, chunk::binary>>
        remaining = n - byte_size(chunk)
        if remaining <= 0, do: {:ok, acc}, else: recv_exact(socket, remaining, acc)

      error ->
        error
    end
  end

  defp recv_until_closed(socket) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, _data} -> recv_until_closed(socket)
      error -> error
    end
  end
end
