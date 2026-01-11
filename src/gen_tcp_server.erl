%%
%% Copyright (c) 2022 dushin.net
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

-module(gen_tcp_server).

-export([start/4, start/3, start_link/4, start_link/3, stop/1]).

-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%%
%% gen_tcp_server behavior
%%

-callback init(Args :: term()) ->
    {ok, State :: term()} | {stop, Reason :: term()}.

-callback handle_receive(Socket :: term(), Packet :: binary(), State :: term()) ->
    {reply, Packet :: iolist(), NewState :: term()} | {noreply, NewState :: term()} | {close, Packet :: iolist()} | close.

-callback handle_tcp_closed(Socket :: term(), State :: term()) -> ok.

% -define(TRACE_ENABLED, true).
-include_lib("atomvm_httpd/include/trace.hrl").

-record(state, {
    handler,
    handler_state
}).

-define(DEFAULT_BIND_OPTIONS, #{
    family => inet,
    addr => any
}).
-define(DEFAULT_SOCKET_OPTIONS, #{
    {socket, reuseaddr} => true
}).
%% Smaller chunks work better with lwIP's limited buffers
-define(MAX_SEND_CHUNK, 1460).  %% TCP MSS - fits in single packet without fragmentation

%%
%% API
%%

start(BindOptions, Handler, Args) ->
    start(BindOptions, ?DEFAULT_SOCKET_OPTIONS, Handler, Args).

start(BindOptions, SocketOptions, Handler, Args) ->
    gen_server:start(?MODULE, {maps:merge(?DEFAULT_BIND_OPTIONS, BindOptions), SocketOptions, Handler, Args}, []).

start_link(BindOptions, Handler, Args) ->
    start_link(BindOptions, ?DEFAULT_SOCKET_OPTIONS, Handler, Args).

start_link(BindOptions, SocketOptions, Handler, Args) ->
    gen_server:start_link(?MODULE, {maps:merge(?DEFAULT_BIND_OPTIONS, BindOptions), SocketOptions, Handler, Args}, []).

stop(Server) ->
    gen_server:stop(Server).

%%
%% gen_server implementation
%%

%% @hidden
init({BindOptions, SocketOptions, Handler, Args}) ->
    Self = self(),
    case socket:open(inet, stream, tcp) of
        {ok, Socket} ->
            ok = set_socket_options(Socket, SocketOptions),
            case socket:bind(Socket, BindOptions) of
                ok ->
                    case socket:listen(Socket) of
                        ok ->
                            spawn(fun() -> accept(Self, Socket) end),
                            case Handler:init(Args) of
                                {ok, HandlerState} ->
                                    {ok, #state{handler = Handler, handler_state = HandlerState}};
                                HandlerError ->
                                    try_close(Socket),
                                    {stop, {handler_error, HandlerError}}
                            end;
                        ListenError ->
                            try_close(Socket),
                            {stop, {listen_error, ListenError}}
                        end;
                BindError ->
                    try_close(Socket),
                    {stop, {bind_error, BindError}}
            end;
        OpenError ->
            {stop, {open_error, OpenError}}
    end;
init({Socket, Handler, Args}) ->
    Self = self(),
    case Handler:init(Args) of
        {ok, HandlerState} ->
            spawn(fun() -> loop(Self, Socket) end),
            {ok, #state{handler = Handler, handler_state = HandlerState}};
        HandlerError ->
            {stop, {handler_error, HandlerError}}
    end.

%% @hidden
handle_call(_From, _Request, State) ->
    {noreply, State}.

%% @hidden
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @hidden
handle_info({tcp_closed, Socket}, State) ->
    ?TRACE("TCP Socket closed ~p", [Socket]),
    #state{handler=Handler, handler_state=HandlerState} = State,
    NewHandlerState = Handler:handle_tcp_closed(Socket, HandlerState),
    {noreply, State#state{handler_state=NewHandlerState}};
handle_info({tcp, Socket, Packet}, State) ->
    #state{handler=Handler, handler_state=HandlerState} = State,
    ?TRACE("received packet: len(~p) from ~p", [erlang:byte_size(Packet), socket:peername(Socket)]),
    case Handler:handle_receive(Socket, Packet, HandlerState) of
        {reply, ResponsePacket, ResponseState} ->
            ?TRACE("Sending reply to endpoint ~p", [socket:peername(Socket)]),
            case try_send(Socket, ResponsePacket) of
                ok ->
                    {noreply, State#state{handler_state=ResponseState}};
                {error, _} ->
                    {noreply, State#state{handler_state=ResponseState}}
            end;
        {noreply, ResponseState} ->
            ?TRACE("no reply", []),
            {noreply, State#state{handler_state=ResponseState}};
        {close, ResponsePacket} ->
            ?TRACE("Sending reply to endpoint ~p and closing socket: ~p", [socket:peername(Socket), Socket]),
            case try_send(Socket, ResponsePacket) of
                ok ->
                    graceful_close(Socket);
                {error, _} ->
                    try_close(Socket)
            end,
            {noreply, State};
        close  ->
            ?TRACE("Closing socket ~p", [Socket]),
            try_close(Socket),
            {noreply, State};
        _SomethingElse ->
            ?TRACE("Unexpected response from handler ~p: ~p", [Handler, _SomethingElse]),
            try_close(Socket),
            {noreply, State}
    end;
handle_info(Info, State) ->
    io:format("Received spurious info msg: ~p~n", [Info]),
    {noreply, State}.

%% @hidden
terminate(_Reason, _State) ->
    ok.

%%
%% internal functions
%%

%% @private
try_send(Socket, Packet) when is_binary(Packet) ->
    ?TRACE(
        "Trying to send binary packet data to socket ~p.  Packet (or len): ~p", [
        Socket, case byte_size(Packet) < 32 of true -> Packet; _ -> byte_size(Packet) end
    ]),
    try_send_binary(Socket, Packet);
try_send(Socket, Byte) when is_integer(Byte) ->
    %% Handles bytes (0-255) in iolists. Unicode must be pre-encoded to UTF-8.
    ?TRACE("Sending byte ~p as ~p", [Byte, <<Byte:8>>]),
    try_send_binary(Socket, <<Byte:8>>);
try_send(Socket, List) when is_list(List) ->
    case is_string(List) of
        true ->
            %% It's a string (list of integers), convert to binary
            try_send_binary(Socket, list_to_binary(List));
        false ->
            %% It's an iolist, send each element
            try_send_iolist(Socket, List)
    end.

try_send_iolist(_Socket, []) ->
    ok;
try_send_iolist(Socket, [H | T]) ->
    case try_send(Socket, H) of
        ok ->
            try_send_iolist(Socket, T);
        {error, _Reason} = Error ->
            Error
    end.

try_send_binary(_Socket, <<>>) ->
    ok;
try_send_binary(Socket, Packet) when is_binary(Packet) ->
    TotalSize = byte_size(Packet),
    ChunkSize = erlang:min(TotalSize, ?MAX_SEND_CHUNK),
    <<Chunk:ChunkSize/binary, Rest/binary>> = Packet,
    case socket:send(Socket, Chunk) of
        ok ->
            try_send_binary(Socket, Rest);
        {ok, Remaining} ->
            %% Partial send - send remaining then continue with rest
            case try_send_binary(Socket, Remaining) of
                ok -> try_send_binary(Socket, Rest);
                Error -> Error
            end;
        {error, eagain} ->
            %% Socket buffer full, brief pause and retry
            receive after 5 -> ok end,
            try_send_binary(Socket, Packet);
        {error, ewouldblock} ->
            receive after 5 -> ok end,
            try_send_binary(Socket, Packet);
        {error, timeout} ->
            receive after 5 -> ok end,
            try_send_binary(Socket, Packet);
        {error, closed} ->
            {error, closed};
        {error, ebadf} ->
            {error, ebadf};
        {error, Reason} ->
            {error, Reason}
    end.

is_string([]) ->
    true;
is_string([H | T]) when is_integer(H) ->
    is_string(T);
is_string(_) ->
    false.

%% @private
try_close(Socket) ->
    case socket:close(Socket) of
        ok ->
            ok;
        Error ->
            io:format("Close failed due to error ~p~n", [Error])
    end.

%% @private
graceful_close(_Socket) ->
    %% Don't close the socket ourselves - let the client close it
    %% after receiving all data. The Connection: close header tells
    %% the client to close, and we'll clean up when we get tcp_closed.
    ok.

%% @private
set_socket_options(Socket, SocketOptions) ->
    maps:fold(
        fun(Option, Value, Accum) ->
            ok = socket:setopt(Socket, Option, Value),
            Accum
        end,
        ok,
        SocketOptions
    ).

%% @private
accept(ControllingProcess, ListenSocket) ->
    ?TRACE("pid ~p Waiting for connection on ~p ...", [self(), socket:sockname(ListenSocket)]),
    case socket:accept(ListenSocket) of
        {ok, Connection} ->
            ?TRACE("Accepted connection from ~p", [socket:peername(Connection)]),
            spawn(fun() -> accept(ControllingProcess, ListenSocket) end),
            loop(ControllingProcess, Connection);
        _Error ->
            ?TRACE("Error accepting connection: ~p", [_Error]),
            timer:sleep(100),
            accept(ControllingProcess, ListenSocket)
    end.


%% @private
loop(ControllingProcess, Connection) ->
    case socket:recv(Connection) of
        {ok, Data} ->
            ?TRACE("Received data ~p on connection ~p", [Data, Connection]),
            ControllingProcess ! {tcp, Connection, Data},
            loop(ControllingProcess, Connection);
        {error, closed} ->
            ControllingProcess ! {tcp_closed, Connection},
            ok;
        {error, _Reason} ->
            %% Don't close the socket here! The handler may still be sending.
            %% Just notify the controlling process and let it handle cleanup.
            ControllingProcess ! {tcp_closed, Connection},
            ok
    end.
