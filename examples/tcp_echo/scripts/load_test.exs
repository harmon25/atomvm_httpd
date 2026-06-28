#!/usr/bin/env elixir
#
# TCP Echo Server - Concurrent Load Test (pure Elixir / :gen_tcp client)
#
# Tests a tcp_server echo server running on real ESP32 hardware over the
# network. The headline test ("Concurrent Load Under Stress") verifies the
# per-connection-process design: a large/slow transfer on one connection must
# NOT block small fast transfers on other connections. This would fail with the
# old serialized gen_tcp_server.
#
# Usage:
#   elixir load_test.exs <esp32-ip> [port]
#
# Uses only OTP's :gen_tcp, so it runs anywhere Elixir/Erlang is installed —
# no netcat/curl dependency.

defmodule LoadTest do
  @recv_timeout 5_000
  @connect_timeout 5_000

  def run(host, port) do
    IO.puts("=== TCP Echo Server - Concurrent Load Test ===")
    IO.puts("Target: #{host}:#{port}\n")

    results =
      []
      |> basic_echo(host, port)
      |> size_sweep(host, port)
      |> concurrent_connections(host, port)
      |> stress(host, port)
      |> rapid_cycles(host, port)

    passed = Enum.count(results, &(&1 == :pass))
    failed = Enum.count(results, &(&1 == :fail))

    IO.puts("\n=== Summary ===")
    IO.puts("Passed: #{passed}")
    IO.puts("Failed: #{failed}")

    if failed == 0 do
      IO.puts("ALL TESTS PASSED")
      System.halt(0)
    else
      IO.puts("SOME TESTS FAILED")
      System.halt(1)
    end
  end

  ## --- test groups ---------------------------------------------------------

  defp basic_echo(acc, host, port) do
    IO.puts("=== Basic Echo ===")

    r1 = check("1. Echo 'hello'", fn -> echo_once(host, port, "hello") == {:ok, "hello"} end)

    payload = :crypto.strong_rand_bytes(1024)

    r2 =
      check("2. Echo 1KB random", fn ->
        echo_once(host, port, payload) == {:ok, payload}
      end)

    acc ++ [r1, r2]
  end

  defp size_sweep(acc, host, port) do
    IO.puts("\n=== Payload Size Sweep ===")

    results =
      for size <- [100, 500, 1024, 2048, 4096, 8192, 16_384, 32_768, 65_536] do
        payload = :crypto.strong_rand_bytes(size)
        {us, result} = :timer.tc(fn -> echo_once(host, port, payload) end)
        ms = Float.round(us / 1000, 1)

        ok = result == {:ok, payload}
        label = "   #{size}B (#{ms}ms)"

        if ok do
          IO.puts("#{label} ... PASS")
          :pass
        else
          IO.puts("#{label} ... FAIL (#{describe(result, size)})")
          :fail
        end
      end

    acc ++ results
  end

  defp concurrent_connections(acc, host, port) do
    IO.puts("\n=== Concurrent Connections ===")

    r5 =
      check("5. 5 concurrent small echoes", fn ->
        concurrent_echo(host, port, for(n <- 1..5, do: "conn-#{n}"))
      end)

    r6 =
      check("6. 5 concurrent 4KB echoes", fn ->
        concurrent_echo(host, port, for(_ <- 1..5, do: :crypto.strong_rand_bytes(4096)))
      end)

    r7 =
      check("7. 8 concurrent echoes (near LWIP_MAX_SOCKETS)", fn ->
        concurrent_echo(host, port, for(n <- 1..8, do: "octo-#{n}"))
      end)

    acc ++ [r5, r6, r7]
  end

  defp stress(acc, host, port) do
    IO.puts("\n=== Concurrent Load Under Stress (KEY TEST) ===")
    IO.puts("   One 64KB transfer in flight while small requests must stay fast.")

    big = :crypto.strong_rand_bytes(65_536)
    parent = self()

    big_task =
      Task.async(fn ->
        result = echo_once(host, port, big, 15_000)
        send(parent, :big_done)
        result
      end)

    # Give the large transfer a head start.
    Process.sleep(200)

    small_results =
      for n <- 1..3 do
        msg = "fast-#{n}"
        {us, result} = :timer.tc(fn -> echo_once(host, port, msg) end)
        ms = Float.round(us / 1000, 1)

        cond do
          result != {:ok, msg} ->
            IO.puts("   fast-#{n} (#{ms}ms) ... FAIL (echo mismatch)")
            :fail

          us < 1_000_000 ->
            IO.puts("   fast-#{n} (#{ms}ms) ... PASS")
            :pass

          true ->
            IO.puts("   fast-#{n} (#{ms}ms) ... SLOW — possible serialization!")
            :fail
        end
      end

    big_result = Task.await(big_task, 20_000)

    big_check =
      if big_result == {:ok, big} do
        IO.puts("   64KB transfer integrity ... PASS")
        :pass
      else
        IO.puts("   64KB transfer integrity ... FAIL (#{describe(big_result, 65_536)})")
        :fail
      end

    acc ++ small_results ++ [big_check]
  end

  defp rapid_cycles(acc, host, port) do
    IO.puts("\n=== Rapid Connect/Disconnect ===")

    r9 =
      check("9. 20 rapid sequential cycles", fn ->
        Enum.all?(1..20, fn n -> echo_once(host, port, "r#{n}") == {:ok, "r#{n}"} end)
      end)

    r10 =
      check("10. Server healthy after cycling", fn ->
        echo_once(host, port, "still-alive") == {:ok, "still-alive"}
      end)

    acc ++ [r9, r10]
  end

  ## --- helpers -------------------------------------------------------------

  defp check(label, fun) do
    if fun.() do
      IO.puts("#{label} ... PASS")
      :pass
    else
      IO.puts("#{label} ... FAIL")
      :fail
    end
  end

  # Open a connection, send `data`, read back exactly byte_size(data) bytes.
  defp echo_once(host, port, data, recv_timeout \\ @recv_timeout) do
    data = IO.iodata_to_binary(data)

    case :gen_tcp.connect(to_charlist(host), port, [:binary, active: false, packet: :raw], @connect_timeout) do
      {:ok, socket} ->
        try do
          case :gen_tcp.send(socket, data) do
            :ok -> recv_exact(socket, byte_size(data), recv_timeout)
            err -> err
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  # Run several echoes concurrently; succeed only if all echo correctly.
  defp concurrent_echo(host, port, payloads) do
    payloads
    |> Enum.map(fn p ->
      bin = IO.iodata_to_binary(p)
      Task.async(fn -> echo_once(host, port, bin) == {:ok, bin} end)
    end)
    |> Task.await_many(20_000)
    |> Enum.all?()
  end

  defp recv_exact(socket, n, timeout, acc \\ <<>>)
  defp recv_exact(_socket, 0, _timeout, acc), do: {:ok, acc}

  defp recv_exact(socket, n, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, chunk} ->
        acc = <<acc::binary, chunk::binary>>
        remaining = n - byte_size(chunk)
        if remaining <= 0, do: {:ok, acc}, else: recv_exact(socket, remaining, timeout, acc)

      error ->
        error
    end
  end

  defp describe({:ok, bin}, expected) when is_binary(bin),
    do: "got #{byte_size(bin)} bytes, expected #{expected}"

  defp describe(other, _expected), do: inspect(other)
end

case System.argv() do
  [host] -> LoadTest.run(host, 8080)
  [host, port] -> LoadTest.run(host, String.to_integer(port))
  _ ->
    IO.puts("Usage: elixir load_test.exs <esp32-ip> [port]")
    System.halt(2)
end
