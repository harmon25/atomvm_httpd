defmodule ElixirHttp.ApiHandler do
  @compile {:no_warn_undefined, :atomvm}

  @moduledoc """
  API handler for system info and memory endpoints.
  Implements the httpd_api_handler behavior.
  """

  @behaviour :httpd_api_handler

  @impl true
  def handle_api_request(:get, ["system_info"], http_request, _args) do
    socket = Map.get(http_request, :socket)
    {:ok, %{addr: host, port: port}} = :socket.peername(socket)
    # IO.puts("GET system_info request from #{inspect(host)}:#{port}")

    platform = :atomvm.platform()
    # IO.puts("Platform: #{inspect(platform)}")
    result = {:ok, %{platform: platform}}
    # IO.puts("Returning: #{inspect(result)}")
    result
  end

  def handle_api_request(:get, ["memory"], http_request, _args) do
    socket = Map.get(http_request, :socket)
    {:ok, %{addr: host, port: port}} = :socket.peername(socket)
    # IO.puts("GET memory request from #{inspect(host)}:#{port}")

    data = get_memory_data()
    # IO.puts("Memory data: #{inspect(data)}")
    result = {:ok, data}
    # IO.puts("Returning: #{inspect(result)}")
    result
  end

  def handle_api_request(method, path, _http_request, _args) do
    IO.puts("ERROR! Unsupported method #{inspect(method)} or path #{inspect(path)}")
    {:error, :not_found}
  end

  def get_memory_data() do
    %{
      atom_count: :erlang.system_info(:atom_count),
      process_count: :erlang.system_info(:process_count),
      esp32_free_heap_size: :erlang.system_info(:esp32_free_heap_size),
      esp32_largest_free_block: :erlang.system_info(:esp32_largest_free_block),
      esp32_minimum_free_size: :erlang.system_info(:esp32_minimum_free_size)
    }
  end
end
