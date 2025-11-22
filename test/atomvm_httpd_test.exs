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
    assert <<"11">> = Map.fetch!(headers, <<"Content-Length">>)
    assert <<"hello=world">> = Map.fetch!(http_request, :body)
  end

  test "maybe_parse_http_request handles large header sets" do
    header_block = Enum.map_join(1..200, "", fn i -> "X-Test-#{i}: value#{i}\r\n" end)
    request = "GET /bulk HTTP/1.1\r\n" <> header_block <> "\r\n"

    assert {:ok, http_request} = :httpd.maybe_parse_http_request(request)
    headers = Map.fetch!(http_request, :headers)
    assert <<"value200">> = Map.fetch!(headers, <<"X-Test-200">>)
  end

  test "handle_request_state stores partial body until complete" do
    socket = make_ref()
    http_request = %{headers: %{<<"Content-Length">> => <<"5">>}, body: <<"12">>}
    state = {:state, [], %{}, %{}, %{}}

    assert {:noreply, {:state, [], %{^socket => ^http_request}, %{}, %{}}} =
             :httpd.handle_request_state(socket, http_request, state)

    assert :wait_for_body = :httpd.get_request_state(http_request)
  end
end
