defmodule HttpdUnitTest do
  use ExUnit.Case, async: true

  test "maybe_parse_http_request indicates more data when headers incomplete" do
    chunk = "GET / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n"
    assert {:more, ^chunk} = :httpd.maybe_parse_http_request(chunk)
  end

  test "maybe_parse_http_request parses complete request with body" do
    request = "POST /form HTTP/1.1\r\nHost: example.com\r\nContent-Length: 11\r\n\r\nhello=world"

    assert {:ok, http_request} = :httpd.maybe_parse_http_request(request)
    assert :post = Map.fetch!(http_request, :method)

    headers = Map.fetch!(http_request, :headers)
    assert <<"11">> = Map.fetch!(headers, <<"content-length">>)
    assert <<"hello=world">> = Map.fetch!(http_request, :body)
  end

  test "maybe_parse_http_request handles large header sets" do
    header_block = Enum.map_join(1..200, "", fn i -> "X-Test-#{i}: value#{i}\r\n" end)
    request = "GET /bulk HTTP/1.1\r\n" <> header_block <> "\r\n"

    assert {:ok, http_request} = :httpd.maybe_parse_http_request(request)
    headers = Map.fetch!(http_request, :headers)
    assert <<"value200">> = Map.fetch!(headers, <<"x-test-200">>)
  end

  test "handle_request_state stores partial body until complete" do
    socket = make_ref()
    http_request = %{headers: %{<<"content-length">> => <<"5">>}, body: <<"12">>}

    # Per-connection state record:
    # {state, socket, config, pending_request, buffer, ws, request_timeout}
    state = {:state, socket, [], :undefined, <<>>, :undefined, 30000}

    assert {:continue, result_state} = :httpd.handle_request_state(http_request, state)

    {:state, _socket, _config, pending_request, _buffer, _ws, _timeout} = result_state

    # The incomplete request should be retained as the connection's pending request.
    assert pending_request == http_request

    assert :wait_for_body = :httpd.get_request_state(http_request)
  end

  describe "query parameter decoding" do
    test "decodes %20 in query parameter values" do
      request = "GET /search?q=hello%20world HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, http_request} = :httpd.maybe_parse_http_request(request)
      assert %{<<"q">> => <<"hello world">>} = Map.fetch!(http_request, :query_params)
    end

    test "decodes %2f and %2F (upper- and lower-case hex) in query parameters" do
      request = "GET /files?p=a%2fb%2Fc HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, http_request} = :httpd.maybe_parse_http_request(request)
      assert %{<<"p">> => <<"a/b/c">>} = Map.fetch!(http_request, :query_params)
    end

    test "leaves malformed %zz escapes literal" do
      request = "GET /x?bad=%zz HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, http_request} = :httpd.maybe_parse_http_request(request)
      assert %{<<"bad">> => <<"%zz">>} = Map.fetch!(http_request, :query_params)
    end

    test "leaves a trailing % literal" do
      request = "GET /x?tail=% HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, http_request} = :httpd.maybe_parse_http_request(request)
      assert %{<<"tail">> => <<"%">>} = Map.fetch!(http_request, :query_params)
    end

    test "empty query string yields no params" do
      request = "GET /path? HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, http_request} = :httpd.maybe_parse_http_request(request)
      assert %{} == Map.fetch!(http_request, :query_params)
      assert [<<"path">>] = Map.fetch!(http_request, :path)
    end

    test "fast-path query params without % are parsed unchanged" do
      request = "GET /path?a=1&b=two HTTP/1.1\r\nHost: example.com\r\n\r\n"

      assert {:ok, http_request} = :httpd.maybe_parse_http_request(request)

      assert %{<<"a">> => <<"1">>, <<"b">> => <<"two">>} =
               Map.fetch!(http_request, :query_params)
    end
  end

  describe "bad content-length" do
    test "a non-numeric content-length is rejected" do
      request = %{headers: %{<<"content-length">> => <<"abc">>}, body: <<>>}

      assert_raise ArgumentError, fn -> :httpd.get_request_state(request) end
    end

    test "a negative content-length is rejected" do
      request = %{headers: %{<<"content-length">> => <<"-5">>}, body: <<>>}

      assert catch_throw(:httpd.get_request_state(request)) == :bad_content_length
    end
  end

  describe "httpd_file_handler.get_content_type/1" do
    test "resolves multi-dot filenames by the final suffix" do
      assert content_type("jquery-3.1.1-min.js") == "text/javascript"
      assert content_type("app.min.css") == "text/css"
    end

    test "falls back to octet-stream for a missing extension" do
      assert content_type("noext") == "application/octet-stream"
    end
  end

  defp content_type(filename) do
    filename
    |> :httpd_file_handler.get_content_type()
    |> to_string()
  end
end
