defmodule ElixirHttp.ApiHandler do
  @moduledoc """
  API handler for system info and memory endpoints.
  Implements the httpd_api_handler behavior.
  """

  @compile {:no_warn_undefined, :atomvm}

  @behaviour :httpd_api_handler

  @impl true
  def handle_api_request(:get, ["system_info"], _http_request, _args) do
    {:ok, get_system_info()}
  end

  def handle_api_request(:get, ["memory"], _http_request, _args) do
    {:ok, get_memory_data()}
  end

  def handle_api_request(method, path, _http_request, _args) do
    IO.puts("ERROR! Unsupported method #{inspect(method)} or path #{inspect(path)}")
    {:error, :not_found}
  end

  def get_memory_data do
    %{
      atom_count: :erlang.system_info(:atom_count),
      process_count: :erlang.system_info(:process_count),
      port_count: :erlang.system_info(:port_count),
      esp32_free_heap_size: :erlang.system_info(:esp32_free_heap_size),
      esp32_largest_free_block: :erlang.system_info(:esp32_largest_free_block),
      esp32_minimum_free_size: :erlang.system_info(:esp32_minimum_free_size)
    }
  end

  defp get_system_info do
    %{
      platform: :atomvm.platform(),
      system_architecture: to_binary(:erlang.system_info(:system_architecture)),
      atomvm_version: to_binary(:erlang.system_info(:atomvm_version)),
      word_size: :erlang.system_info(:wordsize),
      esp32_chip_info: get_esp32_chip_info(),
      esp_idf_version: to_binary(:erlang.system_info(:esp_idf_version))
    }
  end

  # Charlists (e.g. system_architecture) must become binaries so `json:encode`
  # emits JSON strings instead of arrays of integers.
  defp to_binary(value) when is_binary(value), do: value
  defp to_binary(value) when is_list(value), do: :erlang.list_to_binary(value)
  defp to_binary(value) when is_atom(value), do: :erlang.atom_to_binary(value, :utf8)
  defp to_binary(_value), do: "unknown"

  defp get_esp32_chip_info do
    case :erlang.system_info(:esp32_chip_info) do
      :undefined ->
        :null

      {_model, features, cores, revision} ->
        %{features: features, cores: cores, revision: revision, model: :null}

      info when is_map(info) ->
        info

      _ ->
        :null
    end
  end
end
