%%
%% Copyright (c) dushin.net
%% All rights reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%

-module(httpd).

-export([start/2, start/3, start/4, start_link/2, start_link/3, start_link/4, stop/1]).
-export([init/1, handle_receive/3, handle_tcp_closed/2]).

-ifdef(TEST).
-export([maybe_parse_http_request/1, handle_request_state/3, get_request_state/1]).
-endif.

-behaviour(gen_tcp_server).
-include("httpd.hrl").

% -define(TRACE_ENABLED, true).
-include_lib("atomvm_httpd/include/trace.hrl").

-type method() :: get | post | put | delete.
-type content_type() :: string().
-type path() :: list(binary()).
-type query_params() :: #{
    binary() := binary()
}.
-type http_request() :: #{
    method := method(),
    path := path(),
    uri := string(),
    query_params := query_params(),
    headers := #{binary() := binary()},
    body := binary(),
    socket := term(),
    version := binary()
}.
-type handler_config() :: #{
    module := module(),
    module_config := term()
}.
-type config() :: [{path(), handler_config()}].
-type octet() :: 0..255.
-type address_v4() :: {octet(), octet(), octet(), octet()}.
-type address() :: any | loopback | address_v4().
-type portnum() :: 0..65536.

-export_type([method/0, path/0, http_request/0, query_params/0]).

%%
%% Handle an HTTP request.
%%
-callback handle_http_req(Method :: method(), PathSuffix :: path(), HttpRequest :: http_request(), HandlerConfig :: handler_config()) ->
    ok | {ok, {ContentType :: content_type(), Reply :: term()}} | {ok, Reply :: term()} |
    close | {close, {ContentType :: content_type(), Reply :: term()}} | {close, Reply :: term()} |
    not_found | bad_request | internal_server_error |
    term().

-record(state, {
    config,
    pending_request_map = #{},
    ws_socket_map = #{},
    pending_buffer_map = #{},
    pending_timer_map = #{},
    request_timeout = 30000
}).

%%
%% API
%%

-spec start(Port :: portnum(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start(Port, Config) ->
    start(any, Port, #{}, Config).

-spec start(Address :: address(), Port :: portnum(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start(Address, Port, Config) ->
    start(Address, Port, #{}, Config).

-spec start(Address :: address(), Port :: portnum(), SocketOptions :: map(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start(Address, Port, SocketOptions, Config) ->
    gen_tcp_server:start(#{addr => Address, port => Port}, SocketOptions, ?MODULE, Config).

-spec start_link(Port :: portnum(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start_link(Port, Config) ->
    start_link(any, Port, #{}, Config).

-spec start_link(Address :: address(), Port :: portnum(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start_link(Address, Port, Config) ->
    start_link(Address, Port, #{}, Config).

-spec start_link(Address :: address(), Port :: portnum(), SocketOptions :: map(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start_link(Address, Port, SocketOptions, Config) ->
    gen_tcp_server:start_link(#{addr => Address, port => Port}, SocketOptions, ?MODULE, Config).

stop(Httpd) ->
    gen_tcp_server:stop(Httpd).

%%
%% gen_tcp_server implementation
%%

%% @hidden
init(Config) ->
    {ok, #state{config = Config}}.

%% @hidden
handle_receive(Socket, Packet, State) ->
    try
        case maps:get(Socket, State#state.ws_socket_map, undefined) of
            undefined ->
                handle_http_request(Socket, Packet, State);
            WebSocket ->
                case httpd_ws_handler:handle_web_socket_message(WebSocket, Packet) of
                    ok ->
                        {noreply, State};
                    Error ->
                        {close, create_error(?INTERNAL_SERVER_ERROR, Error)}
                end
        end
    catch
        A:E:S ->
            io:format("Caught error: ~p:~p:~p~n", [A, E, S]),
            {close, create_error(?BAD_REQUEST, E)}
    end.

%% @private
handle_http_request(Socket, Packet, State) ->
    PendingRequestMap = State#state.pending_request_map,
    BufferMap = State#state.pending_buffer_map,
    PendingBuffer = maps:get(Socket, BufferMap, <<>>),
    AccumulatedPacket = <<PendingBuffer/binary, Packet/binary>>,
    case maps:get(Socket, PendingRequestMap, undefined) of
        undefined ->
            case maybe_parse_http_request(AccumulatedPacket) of
                {more, IncompletePacket} ->
                    NewBufferMap = BufferMap#{Socket => IncompletePacket},
                    {noreply, start_request_timer(Socket, State#state{pending_buffer_map = NewBufferMap})};
                {ok, HttpRequest} ->
                    CleanBufferMap = maps:remove(Socket, BufferMap),
                    CleanState = State#state{pending_buffer_map = CleanBufferMap},
                    % ?TRACE("HttpRequest: ~p~n", [HttpRequest]),
                    #{
                        method := Method,
                        headers := Headers
                    } = HttpRequest,
                    case Method of
                        undefined ->
                            {close, create_error(?NOT_ALLOWED, method_not_allowed)};
                        _ ->
                            case get_protocol(Method, Headers) of
                        http ->
                            case init_handler(HttpRequest, CleanState) of
                                {ok, {Handler, HandlerState, PathSuffix, HandlerConfig}} ->
                                    NewHttpRequest = HttpRequest#{
                                        handler => Handler,
                                        handler_state => HandlerState,
                                        path_suffix => PathSuffix,
                                        handler_config => HandlerConfig,
                                        socket => Socket
                                    },
                                    handle_request_state(Socket, NewHttpRequest, CleanState);
                                Error ->
                                    {close, create_error(?INTERNAL_SERVER_ERROR, Error)}
                            end;
                        ws ->
                            ?TRACE("Protocol is ws", []),
                            Headers = maps:get(headers, HttpRequest, #{}),
                            case get_ws_key(Headers) of
                                {ok, WebSocketKey} ->
                                    ReplyToken = get_reply_token(WebSocketKey),
                                    Config = CleanState#state.config,
                                    Path = maps:get(path, HttpRequest),
                                    case get_handler(Path, Config) of
                                        {ok, PathSuffix, EntryConfig} ->
                                            WsHandler = maps:get(handler, EntryConfig),
                                            ?TRACE("Got handler ~p", [WsHandler]),
                                            HandlerConfig = maps:get(handler_config, EntryConfig, #{}),
                                            case WsHandler:start(Socket, PathSuffix, HandlerConfig) of
                                                {ok, WebSocket} ->
                                                    ?TRACE("Started web socket handler: ~p", [WebSocket]),
                                                    NewWebSocketMap = maps:put(Socket, WebSocket, CleanState#state.ws_socket_map),
                                                    NewState = CleanState#state{ws_socket_map = NewWebSocketMap},
                                                    ReplyHeaders = #{"Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Accept" => ReplyToken},
                                                    Reply = create_reply(?SWITCHING_PROTOCOLS, ReplyHeaders, <<"">>),
                                                    ?TRACE("Sending web socket upgrade reply: ~p", [Reply]),
                                                    {reply, Reply, NewState};
                                                Error ->
                                                    ?TRACE("Web socket error: ~p", [Error]),
                                                    {close, create_error(?INTERNAL_SERVER_ERROR, {web_socket_error, Error})}
                                            end;
                                        Error ->
                                            {close, create_error(?INTERNAL_SERVER_ERROR, {web_socket_error, Error})}
                                    end;
                                error ->
                                    {close, create_error(?BAD_REQUEST, missing_websocket_key)}
                            end
                    end
                    end;
                {error, Reason} ->
                    {close, create_error(?BAD_REQUEST, Reason)}
            end;
        PendingHttpRequest ->
            ?TRACE("Packetlen: ~p", [erlang:byte_size(Packet)]),
            ExistingBody = maps:get(body, PendingHttpRequest, <<>>),
            NewBody = <<ExistingBody/binary, Packet/binary>>,
            CleanBufferMap = maps:remove(Socket, BufferMap),
            CleanState = State#state{pending_buffer_map = CleanBufferMap},
            handle_request_state(Socket, PendingHttpRequest#{body := NewBody}, CleanState)
    end.

%% @private
init_handler(HttpRequest, State) ->
    Config = State#state.config,
    Path = maps:get(path, HttpRequest),
    case get_handler(Path, Config) of
        {ok, PathSuffix, EntryConfig} ->
            Handler = maps:get(handler, EntryConfig),
            HandlerConfig = maps:get(handler_config, EntryConfig, #{}),

            case Handler:init_handler(PathSuffix, HandlerConfig) of
                {ok, HandlerState} ->
                    {ok, {Handler, HandlerState, PathSuffix, HandlerConfig}};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @private
handle_request_state(Socket, HttpRequest, State) ->
    PendingRequestMap = State#state.pending_request_map,
    case get_request_state(HttpRequest) of
        complete ->
            ?TRACE("Request complete.  Handling...", []),
            NewPendingRequestMap = maps:remove(Socket, PendingRequestMap),
            CleanState = stop_request_timer(Socket, State#state{pending_request_map = NewPendingRequestMap}),
            call_http_req_handler(Socket, HttpRequest, CleanState);
        expect_continue ->
            Headers = maps:get(headers, HttpRequest),
            NewHeaders = maps:remove(<<"expect">>, Headers),
            NewHttpRequest = HttpRequest#{headers := NewHeaders},
            Reply = create_reply(?CONTINUE, #{}, <<"">>),
            NewPendingRequestMap = PendingRequestMap#{Socket => NewHttpRequest},
            {reply, Reply, start_request_timer(Socket, State#state{pending_request_map = NewPendingRequestMap})};
        wait_for_body ->
            NewPendingRequestMap = PendingRequestMap#{Socket => HttpRequest},
            {noreply, start_request_timer(Socket, State#state{pending_request_map = NewPendingRequestMap})}
    end.

%% @private
get_request_state(HttpRequest) ->
    Headers = maps:get(headers, HttpRequest),
    case maps:get(<<"expect">>, Headers, undefined) of
        <<"100-continue">> ->
            ?TRACE("Expect: 100-continue", []),
            expect_continue;
        undefined ->
            case maps:get(<<"content-length">>, Headers, undefined) of
                undefined ->
                    ?TRACE("No content length; request complete", []),
                    complete;
                ContentLenBin when is_binary(ContentLenBin) ->
                    ContentLen = binary_to_integer(ContentLenBin),
                    ?TRACE("ContentLen: ~p", [ContentLen]),
                    Body = maps:get(body, HttpRequest, <<"">>),
                    BodyLen = erlang:byte_size(Body),
                    ?TRACE("BodyLen: ~p", [BodyLen]),
                    case BodyLen < ContentLen of
                        true ->
                            wait_for_body;
                        false ->
                            ?TRACE("Complete! BodyLen: ~p ContentLen: ~p", [BodyLen, ContentLen]),
                            complete
                    end
            end
    end.

%% @private
call_http_req_handler(Socket, HttpRequest, State) ->
    #{
        handler := Handler,
        handler_state := HandlerState
    } = HttpRequest,
    KeepAlive = is_keep_alive(HttpRequest),
    case Handler:handle_http_req(HttpRequest, HandlerState) of
        %% noreply
        {noreply, NewHandlerState} ->
            NewState = update_state(Socket, HttpRequest, NewHandlerState, State),
            {noreply, NewState};
        %% reply
        {reply, Reply, NewHandlerState} ->
            NewState = update_state(Socket, HttpRequest, NewHandlerState, State),
            {reply, create_reply(?OK, #{"Content-Type" => "application/octet-stream"}, Reply), NewState};
        {reply, ReplyHeaders, Reply, NewHandlerState} ->
            NewState = update_state(Socket, HttpRequest, NewHandlerState, State),
            {reply, create_reply(?OK, ReplyHeaders, Reply), NewState};
        %% close
        close ->
            case KeepAlive of
                true -> {reply, create_reply(?OK, #{"Content-Type" => "text/plain"}, <<"">>), State};
                false -> {close, State}
            end;
        {close, Reply} ->
            ReplyPacket = create_reply(?OK, #{"Content-Type" => "application/octet-stream"}, Reply),
            case KeepAlive of
                true -> {reply, ReplyPacket, State};
                false -> {close, ReplyPacket}
            end;
        {close, ReplyHeaders, Reply} ->
            ReplyPacket = create_reply(?OK, ReplyHeaders, Reply),
            case KeepAlive of
                true -> {reply, ReplyPacket, State};
                false -> {close, ReplyPacket}
            end;
        %% errors
        {error, not_found} ->
            {close, create_error(?NOT_FOUND, not_found)};
        {error, bad_request} ->
            {close, create_error(?BAD_REQUEST, bad_request)};
        {error, internal_server_error} ->
            {close, create_error(?INTERNAL_SERVER_ERROR, internal_server_error)};
        HandlerError ->
            {close, create_error(?INTERNAL_SERVER_ERROR, HandlerError)}
    end.

%% @private
is_keep_alive(HttpRequest) ->
    Headers = maps:get(headers, HttpRequest, #{}),
    maps:get(<<"connection">>, Headers, undefined) =:= <<"keep-alive">>.

%% @private
update_state(Socket, HttpRequest, HandlerState, State) ->
    NewHttpRequest = HttpRequest#{handler_state := HandlerState},
    PendingRequestMap = State#state.pending_request_map,
    NewPendingRequestMap = PendingRequestMap#{Socket => NewHttpRequest},
    State#state{pending_request_map = NewPendingRequestMap}.


%% @hidden
handle_tcp_closed(Socket, State) ->
    NewPendingRequestMap = maps:remove(Socket, State#state.pending_request_map),
    NewPendingBufferMap = maps:remove(Socket, State#state.pending_buffer_map),
    NewTimerMap = maps:remove(Socket, State#state.pending_timer_map),
    CleanState = State#state{
        pending_request_map = NewPendingRequestMap,
        pending_buffer_map = NewPendingBufferMap,
        pending_timer_map = NewTimerMap
    },
    case maps:get(Socket, CleanState#state.ws_socket_map, undefined) of
        undefined ->
            CleanState;
        WebSocket ->
            ok = httpd_ws_handler:stop(WebSocket),
            NewWebSocketMap = maps:remove(Socket, CleanState#state.ws_socket_map),
            CleanState#state{ws_socket_map = NewWebSocketMap}
    end.

%%
%% Internal functions
%%

%% @private
get_ws_key(#{<<"sec-websocket-key">> := Key}) ->
    {ok, Key};
get_ws_key(_) ->
    error.

%% @private
get_reply_token(WebSocketKey) ->
    MagicKey = <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>,
    PreImage = <<WebSocketKey/binary, MagicKey/binary>>,
    ReplyToken = base64:encode(crypto:hash(sha, PreImage)),
    ?TRACE("ReplyToken: ~p", [ReplyToken]),
    ReplyToken.

%% @private
parse_http_request(HeadingList, Body) ->
    {Heading, _HeadingRest} = parse_heading(HeadingList, start, [], #{}),
    {Headers, _} = parse_header(_HeadingRest, #{}),
    maps:merge(
        Heading,
        #{
            headers => Headers,
            body => Body
        }
    ).

maybe_parse_http_request(Packet) when is_binary(Packet) ->
    case find_header_delimiter(Packet) of
        nomatch ->
            {more, Packet};
        {Pos, Len} ->
            try
                HeaderEnd = Pos + Len,
                <<HeadingPart:HeaderEnd/binary, Body/binary>> = Packet,
                {ok, parse_http_request(binary_to_list(HeadingPart), Body)}
            catch
                throw:Reason ->
                    {error, Reason};
                error:Reason ->
                    {error, Reason}
            end
    end.

find_header_delimiter(Packet) ->
    case binary:match(Packet, <<"\r\n\r\n">>) of
        nomatch ->
            binary:match(Packet, <<"\n\n">>);
        Match ->
            Match
    end.

%% @private
parse_heading([$\s|Rest], start, Tmp, Accum) ->
    parse_heading(Rest, start, Tmp, Accum);
parse_heading(Packet, start, Tmp, Accum) ->
    parse_heading(Packet, in_method, Tmp, Accum);
parse_heading([$\s|Rest], in_method, Tmp, Accum) ->
    Method = method_to_atom(string:to_upper(lists:reverse(Tmp))),
    parse_heading(Rest, wait_uri, [], Accum#{method => Method});
parse_heading([C|Rest], in_method, Tmp, Accum) ->
    parse_heading(Rest, in_method, [C|Tmp], Accum);
%% wait_uri state
parse_heading([$\s|Rest], wait_uri, Tmp, Accum) ->
    parse_heading(Rest, wait_uri, Tmp, Accum);
parse_heading(Packet, wait_uri, Tmp, Accum) ->
    parse_heading(Packet, in_uri, Tmp, Accum);
%% in_uri state
parse_heading([$\s|Rest], in_uri, Tmp, Accum) ->
    Uri = lists:reverse(Tmp),
    {Path, QueryParams} = normalize_uri(Uri),
    parse_heading(Rest, wait_version, [], Accum#{uri => Uri, path => Path, query_params => QueryParams});
parse_heading([C|Rest], in_uri, Tmp, Accum) ->
    parse_heading(Rest, in_uri, [C|Tmp], Accum);
%% wait_version state
parse_heading([$\s|Rest], wait_version, Tmp, Accum) ->
    parse_heading(Rest, wait_version, Tmp, Accum);
parse_heading(Packet, wait_version, Tmp, Accum) ->
    parse_heading(Packet, in_version, Tmp, Accum);
%% in_version state
parse_heading([$\n|Rest], in_version, Tmp, Accum) ->
    RawVersion = lists:reverse(Tmp),
    Version = case RawVersion of
        [$\r | Clean] -> list_to_binary(Clean);
        _ -> list_to_binary(RawVersion)
    end,
    {Accum#{version => Version}, Rest};
parse_heading([C|Rest], in_version, Tmp, Accum) ->
    parse_heading(Rest, in_version, [C|Tmp], Accum);
%% error state
parse_heading(_Packet, _State, _Tmp, _Accum) ->
    throw(bad_heading).

%% @private
parse_header([$\r, $\n | Rest], Accum) ->
    {Accum, Rest};
parse_header([$\n | Rest], Accum) ->
    {Accum, Rest};
parse_header(Packet, Accum) ->
    {Line, Rest} = parse_line(Packet, []),
    {Key, Value} = split_header(Line),
    parse_header(Rest, Accum#{Key => Value}).

parse_line([$\r, $\n | Rest], Accum) ->
    {lists:reverse(Accum), Rest};
parse_line([$\n | Rest], Accum) ->
    {lists:reverse(Accum), Rest};
parse_line([C | Rest], Accum) ->
    parse_line(Rest, [C | Accum]);
parse_line(_Packet, _Accum) ->
    throw(bad_line).

%% @private
split_header(Header) ->
    case string:split(Header, ":") of
        [Key, Value] ->
            {list_to_binary(string:to_lower(string:trim(Key))), list_to_binary(string:trim(Value))};
        _ ->
            throw(bad_header)
    end.

normalize_uri(Uri) ->
    case string:split(Uri, "?", leading) of
        [Uri] ->
            {tokenize_path(Uri), #{}};
        [Path, QueryParamString] ->
            {tokenize_path(Path), parse_query_params(QueryParamString)}
    end.

tokenize_path(Path) ->
    Components = string:split(Path, "/", all),
    [list_to_binary(C) || C <- Components, C =/= []].

%% @private
parse_query_params(QueryParamString) ->
    NVPairsStrings = string:split(QueryParamString, "&", all),
    maps:from_list([parse_query_param(NVPairString) || NVPairString <- NVPairsStrings]).

parse_query_param(NVPairString) ->
    case string:split(NVPairString, "=") of
        [Key] ->
            {list_to_binary(Key), <<"">>};
        [Key, Value] ->
            {list_to_binary(Key), url_decode(Value, [])}
    end.

% from https://docs.microfocus.com/OMi/10.62/Content/OMi/ExtGuide/ExtApps/URL_encoding.htm
url_decode([], Accum) ->
    lists:reverse(Accum);
url_decode([$%, $2, $0 | Rest], Accum) ->
    url_decode(Rest, [$\s | Accum]);
url_decode([$%, $3, $C | Rest], Accum) ->
    url_decode(Rest, [$< | Accum]);
url_decode([$%, $3, $E | Rest], Accum) ->
    url_decode(Rest, [$> | Accum]);
url_decode([$%, $2, $3 | Rest], Accum) ->
    url_decode(Rest, [$# | Accum]);
url_decode([$%, $2, $5 | Rest], Accum) ->
    url_decode(Rest, [$% | Accum]);
url_decode([$%, $2, $B | Rest], Accum) ->
    url_decode(Rest, [$+ | Accum]);
url_decode([$%, $7, $B | Rest], Accum) ->
    url_decode(Rest, [${ | Accum]);
url_decode([$%, $7, $D | Rest], Accum) ->
    url_decode(Rest, [$} | Accum]);
url_decode([$%, $7, $C | Rest], Accum) ->
    url_decode(Rest, [$| | Accum]);
url_decode([$%, $5, $C | Rest], Accum) ->
    url_decode(Rest, [$\\ | Accum]);
url_decode([$%, $5, $E | Rest], Accum) ->
    url_decode(Rest, [$^ | Accum]);
url_decode([$%, $7, $E | Rest], Accum) ->
    url_decode(Rest, [$~ | Accum]);
url_decode([$%, $5, $B | Rest], Accum) ->
    url_decode(Rest, [$[ | Accum]);
url_decode([$%, $5, $D | Rest], Accum) ->
    url_decode(Rest, [$] | Accum]);
url_decode([$%, $6, $0 | Rest], Accum) ->
    url_decode(Rest, [$` | Accum]);
url_decode([$%, $3, $B | Rest], Accum) ->
    url_decode(Rest, [$; | Accum]);
url_decode([$%, $2, $F | Rest], Accum) ->
    url_decode(Rest, [$/ | Accum]);
url_decode([$%, $3, $F | Rest], Accum) ->
    url_decode(Rest, [$? | Accum]);
url_decode([$%, $3, $A | Rest], Accum) ->
    url_decode(Rest, [$: | Accum]);
url_decode([$%, $4, $0 | Rest], Accum) ->
    url_decode(Rest, [$@ | Accum]);
url_decode([$%, $3, $D | Rest], Accum) ->
    url_decode(Rest, [$= | Accum]);
url_decode([$%, $2, $6 | Rest], Accum) ->
    url_decode(Rest, [$& | Accum]);
url_decode([$%, $2, $4 | Rest], Accum) ->
    url_decode(Rest, [$$ | Accum]);
url_decode([$%, $2, $1 | Rest], Accum) ->
    url_decode(Rest, [$! | Accum]);
url_decode([H | Rest], Accum) ->
    url_decode(Rest, [H | Accum]).

get_handler(_Path, []) ->
    {error, no_handler};
get_handler(Path, [{PathPrefix, Config} | Rest]) ->
    case path_prefix(PathPrefix, Path) of
        {true, PathSuffix} ->
            {ok, PathSuffix, Config};
        _ ->
            get_handler(Path, Rest)
    end.

%% @private
path_prefix([], Path) ->
    {true, Path};
path_prefix([C|R1], [C|R2]) ->
    path_prefix(R1, R2);
path_prefix(_Prefix, _Path) ->
    false.

%% @private
str(Str, Substring) ->
    str(Str, Substring, 1).

%% @private
str([], _, _I) ->
    0;
str([_H|T] = Str, Substring, I) ->
    case starts_with(Str, Substring) of
        true ->
            I;
        _ ->
            str(T, Substring, I + 1)
    end.

starts_with([], []) ->
    true;
starts_with([H|T1], [H|T2]) ->
    starts_with(T1, T2);
starts_with([_H1|_], [_H2|_]) ->
    false.



%% @private
get_protocol(get, #{<<"upgrade">> := <<"websocket">>, <<"connection">> := Upgrade, <<"sec-websocket-key">> := _, <<"sec-websocket-version">> := <<"13">>} = _Headers) ->
    case str(string:to_upper(binary_to_list(Upgrade)), "UPGRADE") of
        0 ->
            http;
        _ ->
            ws
    end;
get_protocol(_, _) ->
    http.


%% @private
create_error(StatusCode, Error) ->
    ErrorString = io_lib:format("Error: ~p", [Error]),
    io:format("error in httpd. StatusCode=~p  Error=~p~n", [StatusCode, Error]),
    create_reply(StatusCode, "text/html", ErrorString).

%% @private
create_reply(StatusCode, ContentType, Reply) when is_list(ContentType) orelse is_binary(ContentType) ->
    create_reply(StatusCode, #{"Content-Type" => ContentType}, Reply);
create_reply(StatusCode, Headers, Reply) when is_map(Headers) ->
    ReplyLen = erlang:iolist_size(Reply),
    HeadersWithLen = ensure_content_length(Headers, ReplyLen),
    [
        <<"HTTP/1.1 ">>, erlang:integer_to_binary(StatusCode), <<" ">>, moniker(StatusCode),
        <<"\r\n">>,
        io_lib:format("Server: atomvm-~s\r\n", [get_version_str(get_atomvm_version())]),
        to_headers_list(HeadersWithLen),
        <<"\r\n">>,
        Reply
    ].

%% @private
ensure_content_length(Headers, ReplyLen) ->
    LenBin = erlang:integer_to_binary(ReplyLen),
    CleanHeaders = maps:remove(<<"content-length">>, Headers),
    CleanHeaders#{<<"content-length">> => LenBin}.

%% @private
maybe_binary_to_string(Bin) when is_binary(Bin) ->
    erlang:binary_to_list(Bin);
maybe_binary_to_string(Other) ->
    Other.

%% @private
to_headers_list(Headers) ->
    [io_lib:format("~s: ~s\r\n", [maybe_binary_to_string(Key), maybe_binary_to_string(Value)]) || {Key, Value} <- maps:to_list(Headers)].


%% @private
get_version_str(Version) when is_binary(Version) ->
    binary_to_list(Version);
get_version_str(_) ->
    "unknown".

get_atomvm_version() ->
    case catch erlang:system_info(atomvm_version) of
        {'EXIT', _} ->
            undefined;
        Version ->
            Version
    end.

%% @private
moniker(?OK) ->
    <<"OK">>;
moniker(?INTERNAL_SERVER_ERROR) ->
    <<"INTERNAL_SERVER_ERROR">>;
moniker(?BAD_REQUEST) ->
    <<"BAD_REQUEST">>;
moniker(?NOT_FOUND) ->
    <<"NOT_FOUND">>;
moniker(?NOT_ALLOWED) ->
    <<"METHOD_NOT_ALLOWED">>;
moniker(?CONTINUE) ->
    <<"Continue">>;
moniker(?SWITCHING_PROTOCOLS) ->
    <<"Switching Protocols">>;
moniker(_) ->
    <<"undefined">>.

%% @private
method_to_atom("GET") ->
    get;
method_to_atom("PUT") ->
    put;
method_to_atom("POST") ->
    post;
method_to_atom("DELETE") ->
    delete;
method_to_atom(_) ->
    undefined.

%% @private
start_request_timer(Socket, State) ->
    Timeout = State#state.request_timeout,
    TimerRef = erlang:send_after(Timeout, self(), {request_timeout, Socket}),
    TimerMap = State#state.pending_timer_map,
    State#state{pending_timer_map = TimerMap#{Socket => TimerRef}}.

%% @private
stop_request_timer(Socket, State) ->
    NewTimerMap = maps:remove(Socket, State#state.pending_timer_map),
    State#state{pending_timer_map = NewTimerMap}.
