defmodule TestWebSocketHandler do
  @moduledoc """
  Test WebSocket handler for integration tests.
  """
  @behaviour :httpd_ws_handler

  @impl true
  def handle_ws_init(websocket, path, test_pid) do
    if is_pid(test_pid) do
      send(test_pid, {:ws_init, websocket, path})
    end

    {:ok, %{test_pid: test_pid, websocket: websocket}}
  end

  @impl true
  def handle_ws_message(payload, state) do
    if test_pid = Map.get(state, :test_pid) do
      send(test_pid, {:ws_message, payload})
    end

    # Special command to trigger a push
    case payload do
      <<"trigger_push">> ->
        websocket = Map.get(state, :websocket)
        # Send additional message asynchronously
        spawn(fn ->
          Process.sleep(10)
          :httpd_ws_handler.send(websocket, "pushed message")
        end)
        {:reply, "echo: #{payload}", state}

      _ ->
        {:reply, "echo: #{payload}", state}
    end
  end
end
