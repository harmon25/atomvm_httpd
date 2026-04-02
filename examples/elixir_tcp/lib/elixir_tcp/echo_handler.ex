defmodule ElixirTcp.EchoHandler do
  @moduledoc """
  Simple echo handler for gen_tcp_server.
  Echoes back any data received from the client.
  """

  @behaviour :gen_tcp_server

  @impl true
  def init(_args) do
    {:ok, %{}}
  end

  @impl true
  def handle_receive(_socket, packet, state) do
    IO.puts("Received bytes: #{:erlang.iolist_size(packet)}")
    {:reply, packet, state}
  end

  @impl true
  def handle_tcp_closed(_socket, state) do
    IO.puts("Client disconnected")
    state
  end
end
