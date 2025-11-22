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

    {:close, %{"Content-Type" => "text/plain"}, "ok"}
  end
end
