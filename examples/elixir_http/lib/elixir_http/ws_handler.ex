defmodule ElixirHttp.WsHandler do
  @moduledoc """
  WebSocket handler that sends memory updates to connected clients.
  Implements the httpd_ws_handler behavior.
  """

  @behaviour :httpd_ws_handler

  @impl true
  def handle_ws_init(websocket, _path, _args) do
    IO.puts("Initializing websocket pid=#{inspect(self())}")
    last_memory = ElixirHttp.ApiHandler.get_memory_data()
    spawn(fn -> update_loop(websocket, last_memory) end)
    {:ok, nil}
  end

  @impl true
  def handle_ws_message("ping", state) do
    {:reply, "pong", state}
  end

  def handle_ws_message(message, state) do
    # IO.puts("Received message from web socket. Message: #{inspect(message)}")
    {:noreply, state}
  end

  defp update_loop(websocket, last_memory_data) do
    Process.sleep(5000)
    latest_memory_data = ElixirHttp.ApiHandler.get_memory_data()

    new_memory_data = get_difference(last_memory_data, latest_memory_data)

    case new_memory_data do
      [] ->
        :ok

      _ ->
        binary = :erlang.iolist_to_binary(:json_encoder.encode(Map.new(new_memory_data)))
        # IO.puts("Sending websocket message to client #{inspect(binary)} ... ")
        :httpd_ws_handler.send(websocket, binary)
        IO.puts("sent.")
    end

    update_loop(websocket, latest_memory_data)
  end

  defp get_difference(map1, map2) do
    Enum.reduce(map1, [], fn {key, value}, acc ->
      case Map.get(map2, key) do
        nil -> [{key, value} | acc]
        ^value -> acc
        new_value -> [{key, new_value} | acc]
      end
    end)
  end
end
