defmodule AtomvmHttpd.TestEchoHandler do
  @behaviour :httpd_handler

  @impl true
  def init_handler(_path_suffix, handler_config) when is_map(handler_config) do
    {:ok, handler_config}
  end

  @impl true
  def handle_http_req(request, state) when is_map(state) do
    if test_pid = Map.get(state, :test_pid) do
      send(test_pid, {:http_request, request})
    end

    headers = Map.get(state, :reply_headers, %{"Content-Type" => "text/plain"})
    body = Map.get(state, :reply_body, "ok")

    {:close, headers, body}
  end
end
