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

-export([start/2, start/3, start/4, start/5, start_link/2, start_link/3, start_link/4, start_link/5, stop/1]).
-export([init/2, handle_data/2, handle_close/2, handle_timeout/1]).

-ifdef(TEST).
-export([maybe_parse_http_request/1, handle_request_state/2, get_request_state/1]).
-endif.

-behaviour(tcp_server).
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

%% Per-connection state.  Each connection runs in its own tcp_server worker
%% process, so there is no socket-keyed bookkeeping: every field is for THIS
%% connection only.
-record(state, {
    socket,
    config,
    %% Partially-accumulated HttpRequest awaiting more body bytes, or undefined.
    pending_request = undefined,
    %% Buffered header bytes not yet forming a complete request line+headers.
    buffer = <<>>,
    %% WebSocket handler gen_server pid once upgraded, or undefined.
    ws = undefined,
    request_timeout = 30000
}).

%%
%% API
%%

-type options() :: #{
    request_timeout => pos_integer()
}.

-spec start(Port :: portnum(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start(Port, Config) ->
    start(any, Port, #{}, #{}, Config).

-spec start(Address :: address(), Port :: portnum(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start(Address, Port, Config) ->
    start(Address, Port, #{}, #{}, Config).

-spec start(Address :: address(), Port :: portnum(), SocketOptions :: map(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start(Address, Port, SocketOptions, Config) ->
    start(Address, Port, SocketOptions, #{}, Config).

-spec start(Address :: address(), Port :: portnum(), SocketOptions :: map(), Options :: options(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start(Address, Port, SocketOptions, Options, Config) ->
    tcp_server:start(#{addr => Address, port => Port}, with_recv_timeout(SocketOptions, Options), ?MODULE, {Options, Config}).

-spec start_link(Port :: portnum(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start_link(Port, Config) ->
    start_link(any, Port, #{}, #{}, Config).

-spec start_link(Address :: address(), Port :: portnum(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start_link(Address, Port, Config) ->
    start_link(Address, Port, #{}, #{}, Config).

-spec start_link(Address :: address(), Port :: portnum(), SocketOptions :: map(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start_link(Address, Port, SocketOptions, Config) ->
    start_link(Address, Port, SocketOptions, #{}, Config).

-spec start_link(Address :: address(), Port :: portnum(), SocketOptions :: map(), Options :: options(), Config :: config()) -> {ok, HTTPD :: pid()} | {error, Reason :: term()}.
start_link(Address, Port, SocketOptions, Options, Config) ->
    tcp_server:start_link(#{addr => Address, port => Port}, with_recv_timeout(SocketOptions, Options), ?MODULE, {Options, Config}).

stop(Httpd) ->
    tcp_server:stop(Httpd).

%% @private
%% The request timeout is enforced by tcp_server's recv timeout: inject it as
%% the `recv_timeout' socket option so a stalled (partial) request wakes the
%% worker via handle_timeout/1.
with_recv_timeout(SocketOptions, Options) ->
    Timeout = maps:get(request_timeout, Options, 30000),
    SocketOptions#{recv_timeout => Timeout}.

%%
%% tcp_server implementation
%%

%% @hidden
init(Socket, {Options, Config}) ->
    Timeout = maps:get(request_timeout, Options, 30000),
    {ok, #state{socket = Socket, config = Config, request_timeout = Timeout}};
init(Socket, Config) ->
    %% Backwards-compatible: called with just Config (no Options).
    {ok, #state{socket = Socket, config = Config}}.

%% @hidden
handle_data(Packet, #state{ws = undefined} = State) ->
    try
        handle_http_request(Packet, State)
    catch
        _A:E:_S ->
            ?TRACE("Caught error: ~p:~p:~p", [_A, E, _S]),
            {send_close, create_error(?BAD_REQUEST, E)}
    end;
handle_data(Packet, #state{ws = WebSocket} = State) ->
    case httpd_ws_handler:handle_web_socket_message(WebSocket, Packet) of
        ok ->
            {continue, State};
        Error ->
            {send_close, create_error(?INTERNAL_SERVER_ERROR, Error)}
    end.

%% @private
handle_http_request(Packet, State) ->
    PendingBuffer = State#state.buffer,
    AccumulatedPacket = <<PendingBuffer/binary, Packet/binary>>,
    case State#state.pending_request of
        undefined ->
            case maybe_parse_http_request(AccumulatedPacket) of
                {more, IncompletePacket} ->
                    {continue, State#state{buffer = IncompletePacket}};
                {ok, ParsedRequest} ->
                    %% Any bytes after this request's declared body belong to a
                    %% pipelined request; keep them in the connection buffer
                    %% instead of mis-attributing them to this request's body.
                    {HttpRequest, Extra} = extract_pipelined_bytes(ParsedRequest),
                    CleanState = State#state{buffer = Extra},
                    #{
                        method := Method,
                        headers := Headers
                    } = HttpRequest,
                    case Method of
                        undefined ->
                            {send_close, create_error(?NOT_ALLOWED, method_not_allowed)};
                        _ ->
                            case get_protocol(Method, Headers) of
                                http ->
                                    handle_http_protocol(HttpRequest, CleanState);
                                ws ->
                                    handle_ws_upgrade(HttpRequest, CleanState)
                            end
                    end;
                {error, Reason} ->
                    {send_close, create_error(?BAD_REQUEST, Reason)}
            end;
        PendingHttpRequest ->
            ?TRACE("Packetlen: ~p", [erlang:byte_size(Packet)]),
            accumulate_pending_body(PendingHttpRequest, Packet, State)
    end.

%% @private
%% Accumulate body bytes for an in-flight request without re-concatenating the
%% whole body on every TCP segment (which is O(N^2) in the number of segments).
%% Chunks are kept in reverse order plus a running length, and flattened exactly
%% once when the declared Content-Length has been reached.
accumulate_pending_body(PendingHttpRequest, Packet, State) ->
    ExistingBody = maps:get(body, PendingHttpRequest, <<>>),
    Chunks = maps:get(body_chunks, PendingHttpRequest, [ExistingBody]),
    BodyLen = maps:get(body_len, PendingHttpRequest, erlang:byte_size(ExistingBody)),
    NewChunks = [Packet | Chunks],
    NewBodyLen = BodyLen + erlang:byte_size(Packet),
    case content_length(PendingHttpRequest) of
        undefined ->
            %% No declared length: the request was already complete, so the
            %% accumulated bytes are the body.
            Body = erlang:iolist_to_binary(lists:reverse(NewChunks)),
            handle_request_state(
                PendingHttpRequest#{body := Body, body_chunks => [], body_len => NewBodyLen},
                State#state{buffer = <<>>}
            );
        ContentLen when NewBodyLen < ContentLen ->
            {continue, State#state{
                pending_request = PendingHttpRequest#{
                    body := <<>>,
                    body_chunks => NewChunks,
                    body_len => NewBodyLen
                },
                buffer = <<>>
            }};
        ContentLen ->
            AllBytes = erlang:iolist_to_binary(lists:reverse(NewChunks)),
            {Body, Extra} = split_body(AllBytes, ContentLen),
            handle_request_state(
                PendingHttpRequest#{
                    body := Body,
                    body_chunks => [],
                    body_len => erlang:byte_size(Body)
                },
                State#state{buffer = Extra}
            )
    end.

%% @private
%% Slice the exact request body out of the accumulated bytes, preserving any
%% extra (pipelined) bytes so they can be parsed as the next request.
split_body(AllBytes, ContentLen) ->
    case erlang:byte_size(AllBytes) > ContentLen of
        true ->
            <<ExactBody:ContentLen/binary, Extra/binary>> = AllBytes,
            {ExactBody, Extra};
        false ->
            {AllBytes, <<>>}
    end.

%% @private
extract_pipelined_bytes(HttpRequest) ->
    Body = maps:get(body, HttpRequest, <<>>),
    case content_length(HttpRequest) of
        undefined ->
            case Body of
                <<>> -> {HttpRequest, <<>>};
                _ -> {HttpRequest#{body := <<>>}, Body}
            end;
        ContentLen when ContentLen >= 0 ->
            case erlang:byte_size(Body) > ContentLen of
                true ->
                    {ExactBody, Extra} = split_body(Body, ContentLen),
                    {HttpRequest#{body := ExactBody}, Extra};
                false ->
                    {HttpRequest, <<>>}
            end;
        _ ->
            {HttpRequest, <<>>}
    end.

%% @private
content_length(HttpRequest) ->
    Headers = maps:get(headers, HttpRequest, #{}),
    case maps:get(<<"content-length">>, Headers, undefined) of
        undefined -> undefined;
        ContentLenBin when is_binary(ContentLenBin) -> binary_to_integer(ContentLenBin);
        ContentLen when is_integer(ContentLen) -> ContentLen
    end.

%% @private
handle_http_protocol(HttpRequest, State) ->
    case init_handler(HttpRequest, State) of
        {ok, {Handler, HandlerState, PathSuffix, HandlerConfig}} ->
            NewHttpRequest = HttpRequest#{
                handler => Handler,
                handler_state => HandlerState,
                path_suffix => PathSuffix,
                handler_config => HandlerConfig,
                socket => State#state.socket
            },
            handle_request_state(NewHttpRequest, State);
        Error ->
            {send_close, create_error(?INTERNAL_SERVER_ERROR, Error)}
    end.

%% @private
handle_ws_upgrade(HttpRequest, State) ->
    ?TRACE("Protocol is ws", []),
    Headers = maps:get(headers, HttpRequest, #{}),
    case get_ws_key(Headers) of
        {ok, WebSocketKey} ->
            ReplyToken = get_reply_token(WebSocketKey),
            Config = State#state.config,
            Path = maps:get(path, HttpRequest),
            case get_handler(Path, Config) of
                {ok, PathSuffix, EntryConfig} ->
                    WsHandler = maps:get(handler, EntryConfig),
                    ?TRACE("Got handler ~p", [WsHandler]),
                    HandlerConfig = maps:get(handler_config, EntryConfig, #{}),
                    case WsHandler:start(State#state.socket, PathSuffix, HandlerConfig) of
                        {ok, WebSocket} ->
                            ?TRACE("Started web socket handler: ~p", [WebSocket]),
                            NewState = State#state{ws = WebSocket},
                            ReplyHeaders = #{"Upgrade" => "websocket", "Connection" => "Upgrade", "Sec-WebSocket-Accept" => ReplyToken},
                            Reply = create_reply(?SWITCHING_PROTOCOLS, ReplyHeaders, <<"">>),
                            ?TRACE("Sending web socket upgrade reply: ~p", [Reply]),
                            {send, Reply, NewState};
                        Error ->
                            ?TRACE("Web socket error: ~p", [Error]),
                            {send_close, create_error(?INTERNAL_SERVER_ERROR, {web_socket_error, Error})}
                    end;
                Error ->
                    {send_close, create_error(?INTERNAL_SERVER_ERROR, {web_socket_error, Error})}
            end;
        error ->
            {send_close, create_error(?BAD_REQUEST, missing_websocket_key)}
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
handle_request_state(HttpRequest, State) ->
    case get_request_state(HttpRequest) of
        complete ->
            ?TRACE("Request complete.  Handling...", []),
            call_http_req_handler(HttpRequest, State#state{pending_request = undefined});
        expect_continue ->
            Headers = maps:get(headers, HttpRequest),
            NewHeaders = maps:remove(<<"expect">>, Headers),
            NewHttpRequest = HttpRequest#{headers := NewHeaders},
            Reply = create_reply(?CONTINUE, #{}, <<"">>),
            {send, Reply, State#state{pending_request = NewHttpRequest}};
        wait_for_body ->
            {continue, State#state{pending_request = HttpRequest}}
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
                    ContentLen = request_content_length(ContentLenBin),
                    BodyLen = request_body_len(HttpRequest),
                    ?TRACE("ContentLen: ~p BodyLen: ~p", [ContentLen, BodyLen]),
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
%% A Content-Length must be a non-negative integer; anything else is a bad
%% request (the caller turns the throw/error into a 400 response).
request_content_length(ContentLenBin) ->
    case binary_to_integer(ContentLenBin) of
        ContentLen when ContentLen >= 0 ->
            ContentLen;
        _ ->
            throw(bad_content_length)
    end.

%% @private
%% Prefer the running body length tracked while accumulating chunks; fall back
%% to the body binary for requests supplied directly (e.g. by callers/tests).
request_body_len(#{body_len := BodyLen}) when is_integer(BodyLen) ->
    BodyLen;
request_body_len(HttpRequest) ->
    erlang:byte_size(maps:get(body, HttpRequest, <<>>)).

%% @private
call_http_req_handler(HttpRequest, State) ->
    #{
        handler := Handler,
        handler_state := HandlerState
    } = HttpRequest,
    case Handler:handle_http_req(HttpRequest, HandlerState) of
        %% noreply — handler wants more body data for THIS request; keep it
        %% pending (with the updated handler_state) so the next packet is
        %% appended to its body rather than parsed as a fresh request.
        {noreply, NewHandlerState} ->
            {continue, State#state{pending_request = HttpRequest#{handler_state := NewHandlerState}}};
        %% reply — send the response, then keep the connection open only if the
        %% client asked for it (HTTP/1.1 default; HTTP/1.0 needs an explicit
        %% Connection: keep-alive, and Connection: close always wins).
        {reply, Reply, _NewHandlerState} ->
            send_reply(
                ?OK,
                #{"Content-Type" => "application/octet-stream"},
                Reply,
                HttpRequest,
                State
            );
        {reply, ReplyHeaders, Reply, _NewHandlerState} ->
            send_reply(?OK, ReplyHeaders, Reply, HttpRequest, State);
        %% close — handler explicitly requests connection close; always honour it
        %% regardless of the client's keep-alive preference, preserving the documented
        %% httpd_handler contract that {close, ...} means "send response, close connection".
        close ->
            {close, State};
        {close, Reply} ->
            {send_close, create_reply(?OK, #{"Content-Type" => "application/octet-stream"}, Reply)};
        {close, ReplyHeaders, Reply} ->
            {send_close, create_reply(?OK, ReplyHeaders, Reply)};
        %% errors
        {error, not_found} ->
            {send_close, create_error(?NOT_FOUND, not_found)};
        {error, bad_request} ->
            {send_close, create_error(?BAD_REQUEST, bad_request)};
        {error, internal_server_error} ->
            {send_close, create_error(?INTERNAL_SERVER_ERROR, internal_server_error)};
        HandlerError ->
            {send_close, create_error(?INTERNAL_SERVER_ERROR, HandlerError)}
    end.

%% @private
send_reply(StatusCode, Headers, Reply, HttpRequest, State) ->
    Response = create_reply(StatusCode, Headers, Reply),
    NewState = State#state{pending_request = undefined},
    case is_keep_alive(HttpRequest) of
        true ->
            {send, Response, NewState};
        false ->
            {send_close, Response}
    end.

%% @private
%% HTTP/1.1 connections are persistent unless the client sends
%% `Connection: close'; HTTP/1.0 connections are closed unless the client sends
%% `Connection: keep-alive'.  Header values are matched case-insensitively.
is_keep_alive(HttpRequest) ->
    Headers = maps:get(headers, HttpRequest, #{}),
    Version = maps:get(version, HttpRequest, <<"HTTP/1.0">>),
    Connection = ascii_lower_bin(maps:get(<<"connection">>, Headers, <<>>)),
    case Version of
        <<"HTTP/1.1">> ->
            binary:match(Connection, <<"close">>) =:= nomatch;
        _ ->
            binary:match(Connection, <<"keep-alive">>) =/= nomatch
    end.

%% @hidden
handle_close(_Reason, #state{ws = undefined}) ->
    ok;
handle_close(_Reason, #state{ws = WebSocket}) ->
    %% Stop the WebSocket handler gen_server; it may already be gone if it
    %% closed the socket itself, so guard against a noproc exit.
    catch httpd_ws_handler:stop(WebSocket),
    ok.

%% @hidden
%% Invoked by tcp_server when a blocking recv hits the request_timeout with no
%% data.  If a request is in flight (partial headers buffered, or a body still
%% being received) the client has stalled — close.  Otherwise the connection is
%% simply idle (e.g. keep-alive between requests, or an established WebSocket) —
%% keep waiting.
handle_timeout(#state{pending_request = undefined, buffer = <<>>} = State) ->
    {continue, State};
handle_timeout(State) ->
    ?TRACE("Request timeout — closing stalled connection", []),
    {close, State}.

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
%% Parse a complete request head (the bytes before the blank line) together
%% with the body bytes that followed it.  Parsing happens directly on binaries:
%% the header block is never converted wholesale to a charlist.
parse_http_request(HeaderBlock, Body) ->
    {RequestLine, HeaderLines} =
        case binary:split(HeaderBlock, <<"\n">>, [global]) of
            [FirstLine | Rest] ->
                {strip_cr(FirstLine), Rest};
            [] ->
                throw(bad_heading)
        end,
    Heading = parse_request_line(RequestLine),
    Headers = parse_header_lines(HeaderLines, #{}),
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
                <<HeaderBlock:Pos/binary, _Delimiter:Len/binary, Body/binary>> = Packet,
                {ok, parse_http_request(HeaderBlock, Body)}
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
%% `Method SP Uri SP Version'.  Multiple and/or leading spaces are tolerated.
parse_request_line(<<>>) ->
    throw(bad_heading);
parse_request_line(Line) ->
    Tokens = [Token || Token <- binary:split(Line, <<" ">>, [global]), Token =/= <<>>],
    case Tokens of
        [MethodBin, UriBin, VersionBin] ->
            {Path, QueryParams} = normalize_uri(UriBin),
            #{
                method => method_to_atom(MethodBin),
                uri => binary_to_list(UriBin),
                path => Path,
                query_params => QueryParams,
                version => VersionBin
            };
        _ ->
            throw(bad_heading)
    end.

%% @private
parse_header_lines([], Accum) ->
    Accum;
parse_header_lines([Line | Rest], Accum) ->
    case strip_cr(Line) of
        <<>> ->
            parse_header_lines(Rest, Accum);
        CleanLine ->
            parse_header_lines(Rest, put_header(CleanLine, Accum))
    end.

%% @private
put_header(Line, Accum) ->
    case binary:split(Line, <<":">>) of
        [KeyBin, ValueBin] ->
            Key = ascii_lower_bin(trim_ascii(KeyBin)),
            Accum#{Key => trim_ascii(ValueBin)};
        _ ->
            throw(bad_header)
    end.

%% @private
normalize_uri(UriBin) ->
    case binary:split(UriBin, <<"?">>) of
        [PathBin] ->
            {tokenize_path(PathBin), #{}};
        [PathBin, QueryParamBin] ->
            {tokenize_path(PathBin), parse_query_params(QueryParamBin)}
    end.

%% @private
tokenize_path(PathBin) ->
    [Component || Component <- binary:split(PathBin, <<"/">>, [global]), Component =/= <<>>].

%% @private
parse_query_params(<<>>) ->
    #{};
parse_query_params(QueryParamBin) ->
    maps:from_list([
        parse_query_param(NVPairBin)
     || NVPairBin <- binary:split(QueryParamBin, <<"&">>, [global]), NVPairBin =/= <<>>
    ]).

%% @private
parse_query_param(NVPairBin) ->
    case binary:split(NVPairBin, <<"=">>) of
        [KeyBin] ->
            {KeyBin, <<>>};
        [KeyBin, ValueBin] ->
            {KeyBin, url_decode(ValueBin)}
    end.

%% @private
%% General-purpose %HH decoder working directly on binaries.  Fast path: a value
%% containing no '%' is returned unchanged (zero allocation).  Malformed escapes
%% (e.g. "%zz" or a trailing "%") are preserved literally.
url_decode(ValueBin) ->
    case binary:match(ValueBin, <<"%">>) of
        nomatch ->
            ValueBin;
        _ ->
            list_to_binary(url_decode(ValueBin, []))
    end.

%% @private
url_decode(<<>>, Accum) ->
    lists:reverse(Accum);
url_decode(<<$%, High, Low, Rest/binary>>, Accum) ->
    case hex_value(High, Low) of
        error ->
            %% Not a valid escape: keep the '%' and re-scan the rest literally.
            url_decode(<<High, Low, Rest/binary>>, [$% | Accum]);
        Byte ->
            url_decode(Rest, [Byte | Accum])
    end;
url_decode(<<Byte, Rest/binary>>, Accum) ->
    url_decode(Rest, [Byte | Accum]).

%% @private
hex_value(High, Low) ->
    case {hex_digit(High), hex_digit(Low)} of
        {error, _} ->
            error;
        {_, error} ->
            error;
        {HighVal, LowVal} ->
            HighVal * 16 + LowVal
    end.

%% @private
hex_digit(Char) when Char >= $0, Char =< $9 -> Char - $0;
hex_digit(Char) when Char >= $A, Char =< $F -> Char - $A + 10;
hex_digit(Char) when Char >= $a, Char =< $f -> Char - $a + 10;
hex_digit(_Char) -> error.

%% @private
%% Strip a single trailing CR (CRLF line endings) from a binary line.
strip_cr(<<>>) ->
    <<>>;
strip_cr(Bin) ->
    Size = erlang:byte_size(Bin),
    case binary:at(Bin, Size - 1) of
        $\r ->
            binary:part(Bin, 0, Size - 1);
        _ ->
            Bin
    end.

%% @private
%% Trim leading/trailing ASCII spaces and tabs on a binary.
trim_ascii(Bin) ->
    Size = erlang:byte_size(Bin),
    Start = skip_leading_space(Bin, 0, Size),
    End = skip_trailing_space(Bin, Size, Start),
    binary:part(Bin, Start, End - Start).

%% @private
skip_leading_space(Bin, Pos, Size) when Pos < Size ->
    case binary:at(Bin, Pos) of
        Char when Char =:= $\s; Char =:= $\t ->
            skip_leading_space(Bin, Pos + 1, Size);
        _ ->
            Pos
    end;
skip_leading_space(_Bin, Pos, _Size) ->
    Pos.

%% @private
skip_trailing_space(_Bin, End, Start) when End =< Start ->
    End;
skip_trailing_space(Bin, End, Start) ->
    case binary:at(Bin, End - 1) of
        Char when Char =:= $\s; Char =:= $\t ->
            skip_trailing_space(Bin, End - 1, Start);
        _ ->
            End
    end.

%% @private
%% ASCII-lowercase a binary, returning it unchanged (no allocation) when it is
%% already lowercase — the common case for header names.
ascii_lower_bin(Bin) ->
    case has_upper(Bin) of
        false ->
            Bin;
        true ->
            <<<<(lower_char(Char))>> || <<Char>> <= Bin>>
    end.

%% @private
has_upper(<<Char, _Rest/binary>>) when Char >= $A, Char =< $Z ->
    true;
has_upper(<<_Char, Rest/binary>>) ->
    has_upper(Rest);
has_upper(<<>>) ->
    false.

%% @private
lower_char(Char) when Char >= $A, Char =< $Z ->
    Char + 32;
lower_char(Char) ->
    Char.

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
%% Detect a WebSocket upgrade.  The `Upgrade' and `Connection' header values
%% may be comma-separated token lists (e.g. `Connection: keep-alive, Upgrade'),
%% so both are matched case-insensitively as substrings instead of requiring an
%% exact value.
get_protocol(
    get,
    #{
        <<"upgrade">> := UpgradeVal,
        <<"connection">> := ConnectionHeader,
        <<"sec-websocket-key">> := _,
        <<"sec-websocket-version">> := <<"13">>
    }
) ->
    case ascii_lower_bin(UpgradeVal) of
        <<"websocket">> ->
            case binary:match(ascii_lower_bin(ConnectionHeader), <<"upgrade">>) of
                nomatch ->
                    http;
                _ ->
                    ws
            end;
        _ ->
            http
    end;
get_protocol(_, _) ->
    http.

%% @private
create_error(StatusCode, Error) ->
    ?TRACE("error in httpd. StatusCode=~p  Error=~p", [StatusCode, Error]),
    ErrorString = io_lib:format("Error: ~p", [Error]),
    create_reply(StatusCode, "text/html", ErrorString).

%% @private
create_reply(StatusCode, ContentType, Reply) when is_list(ContentType) orelse is_binary(ContentType) ->
    create_reply(StatusCode, #{"Content-Type" => ContentType}, Reply);
create_reply(StatusCode, Headers, Reply) when is_map(Headers) ->
    ReplyLen = erlang:iolist_size(Reply),
    %% Normalize all header keys to lowercase binary before computing
    %% Content-Length so that ensure_content_length/2 can reliably strip any
    %% pre-existing content-length variant (e.g. "Content-Length", <<"Content-Length">>)
    %% and avoid emitting duplicate headers.
    NormalizedHeaders = normalize_headers(Headers),
    HeadersWithLen = ensure_content_length(NormalizedHeaders, ReplyLen),
    [
        <<"HTTP/1.1 ">>, erlang:integer_to_binary(StatusCode), <<" ">>, moniker(StatusCode),
        <<"\r\n">>,
        <<"Server: atomvm-", (get_version_bin())/binary, "\r\n">>,
        to_headers_list(HeadersWithLen),
        <<"\r\n">>,
        Reply
    ].

%% @private
%% Rewrite every key in a response-header map to a lowercase binary so that
%% ensure_content_length/2 and to_headers_list/1 always operate on a uniform
%% representation regardless of whether the caller used strings, binaries, or
%% mixed-case atoms.
normalize_headers(Headers) ->
    maps:fold(
        fun(Key, Value, Acc) ->
            NormKey = normalize_header_key(Key),
            Acc#{NormKey => Value}
        end,
        #{},
        Headers
    ).

normalize_header_key(Key) when is_binary(Key) ->
    %% Fast path: already-lowercase binary keys need no copying.
    ascii_lower_bin(Key);
normalize_header_key(Key) when is_list(Key) ->
    ascii_lower_bin(list_to_binary(Key));
normalize_header_key(Key) when is_atom(Key) ->
    ascii_lower_bin(atom_to_binary(Key, utf8)).

%% @private
ensure_content_length(Headers, ReplyLen) ->
    LenBin = erlang:integer_to_binary(ReplyLen),
    %% After normalize_headers/1 the key is always <<"content-length">>.
    CleanHeaders = maps:remove(<<"content-length">>, Headers),
    CleanHeaders#{<<"content-length">> => LenBin}.

%% @private
%% Render response headers as binary iodata: [<<"key: value\r\n">>].  Values
%% are converted in place (no charlist round-trip for binaries).
to_headers_list(Headers) ->
    [
        [KeyBin, <<": ">>, value_to_iodata(Value), <<"\r\n">>]
     || {KeyBin, Value} <- maps:to_list(Headers)
    ].

%% @private
value_to_iodata(Value) when is_binary(Value) ->
    Value;
value_to_iodata(Value) when is_list(Value) ->
    Value;
value_to_iodata(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
value_to_iodata(Value) when is_integer(Value) ->
    erlang:integer_to_binary(Value);
value_to_iodata(Value) ->
    erlang:iolist_to_binary(io_lib:format("~p", [Value])).

%% @private
get_version_bin() ->
    case get_atomvm_version() of
        Version when is_binary(Version) ->
            Version;
        Version when is_list(Version) ->
            list_to_binary(Version);
        _ ->
            <<"unknown">>
    end.

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
method_to_atom(MethodBin) ->
    case ascii_lower_bin(MethodBin) of
        <<"get">> ->
            get;
        <<"put">> ->
            put;
        <<"post">> ->
            post;
        <<"delete">> ->
            delete;
        _ ->
            undefined
    end.


