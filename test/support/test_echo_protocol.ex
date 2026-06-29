defmodule AtomvmHttpd.TestEchoProtocol do
  @moduledoc """
  A `:tcp_server` protocol used by the host-side tcp_server tests.

  Behaviour:
    * echoes received data back to the client
    * if `test_pid` is set in args, forwards lifecycle events to it:
      `{:tcp_init, socket}`, `{:tcp_data, data}`, `{:tcp_closed, reason}`
    * if received data equals `"CLOSE"`, replies `"bye"` then closes the
      connection (exercises the `{:send_close, ...}` return)
  """
  @behaviour :tcp_server

  @impl true
  def init(socket, args) do
    notify(args, {:tcp_init, socket})
    {:ok, %{args: args, bytes: 0}}
  end

  @impl true
  def handle_data("CLOSE", state) do
    notify(state.args, {:tcp_data, "CLOSE"})
    {:send_close, "bye"}
  end

  def handle_data(data, state) do
    notify(state.args, {:tcp_data, data})
    {:send, data, %{state | bytes: state.bytes + byte_size(data)}}
  end

  @impl true
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_close(reason, state) do
    notify(state.args, {:tcp_closed, reason})
    :ok
  end

  defp notify(args, msg) do
    case Map.get(args, :test_pid) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end
end
