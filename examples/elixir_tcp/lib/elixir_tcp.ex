defmodule ElixirTcp do
  # @compile {:no_warn_undefined, :avm_pubsub}
  @compile {:no_warn_undefined, :network}

  @moduledoc """
  Elixir tcp example
  """

  def start do
    :ok = start_network()

    :ok = start_tcp()

    Process.sleep(:infinity)
  end

  # resolved at compile time
  @ssid System.get_env("SSID")
  @psk System.get_env("PSK")

  def start_network() do
    case :network.wait_for_sta([ssid: @ssid, psk: @psk], 30_000) do
      {:ok, _} ->
        :ok

      {:error, :disconnected} ->
        # try again...
        start_network()

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, err} ->
        IO.puts("Error starting network #{inspect(err)}")

        :error
    end
  end

  defp start_tcp(port \\ 9090) do
    IO.puts("Starting TCP echo Server on port #{port}")

    case :gen_tcp_server.start_link(%{port: port}, ElixirTcp.EchoHandler, []) do
      {:ok, _pid} ->
        IO.puts("Echo server listening on port #{port}")
        :ok

      {:error, reason} ->
        IO.puts("Failed to start echo server: #{inspect(reason)}")
        :error
    end
  end
end
