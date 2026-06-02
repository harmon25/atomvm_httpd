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
    state = {:state, [], %{}, %{}, %{}, %{}, 30000}

    assert {:noreply, result_state} = :httpd.handle_request_state(socket, http_request, state)

    # Destructure the result state tuple: {state, config, pending_request_map,
    # ws_socket_map, pending_buffer_map, pending_timer_map, request_timeout}
    {:state, _config, pending_request_map, _ws, _buf, pending_timer_map, _timeout} = result_state

    # Partial request should be stored in the pending map
    assert %{^socket => ^http_request} = pending_request_map

    # A request timer should have been started for the socket.
    # The entry is {TimerRef, Tag} — both are opaque references.
    timer_entry = Map.get(pending_timer_map, socket)
    assert is_tuple(timer_entry) and tuple_size(timer_entry) == 2,
           "expected a {timer_ref, tag} tuple in pending_timer_map for the socket"
    {t_ref, t_tag} = timer_entry
    assert is_reference(t_ref)
    assert is_reference(t_tag)

    assert :wait_for_body = :httpd.get_request_state(http_request)
  end
end
