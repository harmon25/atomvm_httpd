defmodule TcpEcho.EchoProtocol do
  @moduledoc """
  A `:tcp_server` protocol that echoes every received byte back to the client.

  Each connection runs in its own worker process, so a large/slow echo on one
  connection never blocks echoes on another.
  """
  @behaviour :tcp_server

  @impl true
  def init(_socket, _args) do
    IO.puts("EchoProtocol: new connection")
    {:ok, %{bytes_received: 0}}
  end

  @impl true
  def handle_data(data, state) do
    new_total = state.bytes_received + byte_size(data)
    {:send, data, %{state | bytes_received: new_total}}
  end

  @impl true
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_close(_reason, state) do
    IO.puts("EchoProtocol: connection closed (#{state.bytes_received} bytes total)")
    :ok
  end
end
