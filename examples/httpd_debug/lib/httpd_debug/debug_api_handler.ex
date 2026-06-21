defmodule HttpdDebug.DebugApiHandler do
  @moduledoc """
  Debug/test API endpoints for stress-testing atomvm_httpd.

  Provides endpoints to test various request/response sizes and patterns.
  """

  @behaviour :httpd_api_handler

  def handle_api_request(:get, [<<"ping">>], _http_request, _args) do
    heap_before = get_heap_info()
    log_request(:get, "/api/ping", 0, heap_before)

    {:ok, %{status: "ok", heap: heap_before}}
  end

  def handle_api_request(:post, [<<"echo">>], http_request, _args) do
    body = Map.get(http_request, :body, <<>>)
    body_size = byte_size(body)
    heap_before = get_heap_info()

    log_request(:post, "/api/echo", body_size, heap_before)

    # Return size info without echoing full body (could be huge)
    # Use binary pattern match instead of String.slice (not available on AtomVM)
    preview = body_preview(body, body_size)

    {:ok,
     %{
       status: "ok",
       received_bytes: body_size,
       body_preview: preview,
       heap: heap_before
     }}
  end

  def handle_api_request(:get, [<<"generate">>], http_request, _args) do
    query_params = Map.get(http_request, :query_params, %{})
    size = parse_size(query_params)
    heap_before = get_heap_info()

    log_request(:get, "/api/generate?size=#{size}", 0, heap_before)

    # Generate N bytes of data using binary:copy (available on AtomVM)
    data = :binary.copy(<<"A">>, size)

    {:ok,
     %{
       status: "ok",
       size: size,
       data: data,
       heap: heap_before
     }}
  end

  def handle_api_request(:get, [<<"memory">>], _http_request, _args) do
    heap_info = get_heap_info()
    log_request(:get, "/api/memory", 0, heap_info)

    {:ok,
     %{
       free_heap: heap_info.free_heap,
       largest_block: heap_info.largest_block,
       min_free: heap_info.min_free
     }}
  end

  def handle_api_request(method, path, _http_request, _args) do
    IO.puts("DebugApiHandler: Unsupported #{method} #{inspect(path)}")
    :not_found
  end

  defp parse_size(query_params) do
    case Map.get(query_params, <<"size">>) do
      nil ->
        1024

      size_str when is_binary(size_str) ->
        try do
          size = :erlang.binary_to_integer(size_str)
          if size > 0, do: min(size, 1_048_576), else: 1024
        rescue
          _ -> 1024
        end

      size when is_integer(size) ->
        min(size, 1_048_576)

      _ ->
        1024
    end
  end

  # Return a safe JSON-encodable preview of the body.
  # Binary data may contain non-UTF-8 bytes which json:encode rejects,
  # so we return a hex-encoded version for non-text content.
  defp body_preview(body, size) do
    preview = if size <= 100 do
      body
    else
      <<p::binary-size(100), _rest::binary>> = body
      p
    end
    # Check if all bytes are printable ASCII (safe for JSON)
    if printable_ascii?(preview, 0, byte_size(preview)) do
      preview
    else
      # Return byte count only — avoid encoding raw bytes as JSON string
      size_str = :erlang.integer_to_binary(size)
      <<"(binary: ", size_str::binary, " bytes)">>
    end
  end

  defp printable_ascii?(_bin, pos, len) when pos >= len, do: true
  defp printable_ascii?(bin, pos, len) do
    <<_::binary-size(pos), byte, _::binary>> = bin
    if byte >= 32 and byte <= 126 do
      printable_ascii?(bin, pos + 1, len)
    else
      false
    end
  end

  defp get_heap_info do
    %{
      free_heap: :erlang.system_info(:esp32_free_heap_size),
      largest_block: :erlang.system_info(:esp32_largest_free_block),
      min_free: :erlang.system_info(:esp32_minimum_free_size)
    }
  end

  defp log_request(method, path, body_size, heap) do
    IO.puts(
      "DebugApi: #{method} #{path} | body=#{body_size}B | heap=#{heap.free_heap}B free"
    )
  end
end
