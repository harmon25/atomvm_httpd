%%
%% Copyright (c) 2024 atomvm_httpd contributors
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

%% @doc Per-connection-process TCP server.
%%
%% Unlike `gen_tcp_server', which serializes all parsing, dispatch and sending
%% through a single gen_server, `tcp_server' gives every accepted connection its
%% own worker process.  A worker owns its socket for the connection's entire
%% lifecycle: it calls `recv', dispatches to the protocol callback module, and
%% performs the (potentially blocking, chunked) `send' itself.  Connections are
%% therefore fully independent — a large/slow response on one connection never
%% blocks another.
%%
%% Process layout:
%% ```
%%   tcp_server (listener gen_server)
%%     |-- acceptor process              (pure socket:accept loop, linked)
%%     `-- connection worker processes   (one per socket, monitored)
%% '''
%%
%% The listener owns the listen socket and tracks/monitors workers.  The
%% acceptor never runs protocol code, so protocol crashes can never take down
%% the accept loop.
-module(tcp_server).

-export([start/3, start/4, start_link/3, start_link/4, stop/1, send/2, send/3]).

-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%%
%% tcp_server behavior
%%

%% Invoked in the worker process when a connection is established, before any
%% data is received.  Return {error, Reason} to refuse the connection.
-callback init(Socket :: term(), Args :: term()) ->
    {ok, State :: term()} | {error, Reason :: term()}.

%% Invoked when data is received on the connection.
-callback handle_data(Data :: binary(), State :: term()) ->
    {send, Response :: iodata(), NewState :: term()}
    | {send_close, Response :: iodata()}
    | {continue, NewState :: term()}
    | {close, NewState :: term()}
    | {error, Reason :: term()}.

%% Optional: invoked for out-of-band messages delivered to the worker process.
-callback handle_info(Msg :: term(), State :: term()) ->
    {ok, NewState :: term()}
    | {send, Response :: iodata(), NewState :: term()}
    | {close, NewState :: term()}.

%% Invoked when the connection is closing (peer close, error, or protocol close).
-callback handle_close(Reason :: term(), State :: term()) -> ok.

%% Optional: invoked when a blocking recv reaches the configured recv_timeout
%% with no data.  Lets a protocol enforce idle/request timeouts.  If not
%% exported, recv timeouts are transparent (the worker simply keeps waiting).
-callback handle_timeout(State :: term()) ->
    {continue, NewState :: term()}
    | {close, NewState :: term()}.

-optional_callbacks([handle_info/2, handle_timeout/1]).

% -define(TRACE_ENABLED, true).
-include_lib("atomvm_httpd/include/trace.hrl").

-define(DEFAULT_BIND_OPTIONS, #{
    family => inet,
    addr => any
}).
-define(DEFAULT_SOCKET_OPTIONS, #{
    {socket, reuseaddr} => true
}).
%% Default send-chunk size.  Matches gen_tcp_server: a comfortable fit within
%% the ESP32 lwIP send buffer.
-define(DEFAULT_SEND_CHUNK, 4096).
%% Application-level keys (chunk_size, max_connections, recv_timeout) ride in
%% the SocketOptions map but must never reach socket:setopt/3.  They are
%% stripped with nested maps:remove/2 in init/1 — AtomVM's maps module does not
%% implement maps:without/2.

-record(listener_state, {
    listen_socket,
    protocol,
    protocol_args,
    chunk_size = ?DEFAULT_SEND_CHUNK,
    recv_timeout = infinity,
    max_connections = 0,
    %% #{WorkerPid => MonitorRef}
    connections = #{}
}).

%%
%% API
%%

start(BindOptions, Protocol, Args) ->
    start(BindOptions, ?DEFAULT_SOCKET_OPTIONS, Protocol, Args).

start(BindOptions, SocketOptions, Protocol, Args) ->
    gen_server:start(
        ?MODULE,
        {maps:merge(?DEFAULT_BIND_OPTIONS, BindOptions), SocketOptions, Protocol, Args},
        []
    ).

start_link(BindOptions, Protocol, Args) ->
    start_link(BindOptions, ?DEFAULT_SOCKET_OPTIONS, Protocol, Args).

start_link(BindOptions, SocketOptions, Protocol, Args) ->
    gen_server:start_link(
        ?MODULE,
        {maps:merge(?DEFAULT_BIND_OPTIONS, BindOptions), SocketOptions, Protocol, Args},
        []
    ).

stop(Server) ->
    gen_server:stop(Server).

%% @doc Chunked send helper using the default chunk size.  Convenient for
%% out-of-band senders (e.g. the WebSocket handler) that do not track the
%% server's configured chunk size.  Returns ok | {error, Reason}.
send(Socket, Data) ->
    do_send(Socket, Data, ?DEFAULT_SEND_CHUNK).

%% @doc Chunked send helper for protocol modules.  Runs in the calling (worker)
%% process, so blocking is fine.  Returns ok | {error, Reason}.
send(Socket, Data, ChunkSize) ->
    do_send(Socket, Data, ChunkSize).

%%
%% gen_server (listener) implementation
%%

%% @hidden
init({BindOptions, SocketOptions, Protocol, Args}) ->
    process_flag(trap_exit, true),
    MaxConnections = maps:get(max_connections, SocketOptions, 0),
    ChunkSize = maps:get(chunk_size, SocketOptions, ?DEFAULT_SEND_CHUNK),
    RecvTimeout = maps:get(recv_timeout, SocketOptions, infinity),
    %% Strip application-level keys before socket:setopt/3 so the AtomVM setopt
    %% allow-list is never violated (would crash the server).  Nested
    %% maps:remove/2 — maps:without/2 is not available on AtomVM.
    CleanSocketOptions =
        maps:remove(
            recv_timeout,
            maps:remove(chunk_size, maps:remove(max_connections, SocketOptions))
        ),
    case socket:open(inet, stream, tcp) of
        {ok, ListenSocket} ->
            ok = set_socket_options(ListenSocket, CleanSocketOptions),
            case socket:bind(ListenSocket, BindOptions) of
                ok ->
                    case socket:listen(ListenSocket) of
                        ok ->
                            Self = self(),
                            spawn_link(fun() -> accept_loop(Self, ListenSocket) end),
                            {ok, #listener_state{
                                listen_socket = ListenSocket,
                                protocol = Protocol,
                                protocol_args = Args,
                                chunk_size = ChunkSize,
                                recv_timeout = RecvTimeout,
                                max_connections = MaxConnections
                            }};
                        ListenError ->
                            try_close(ListenSocket),
                            {stop, {listen_error, ListenError}}
                    end;
                BindError ->
                    try_close(ListenSocket),
                    {stop, {bind_error, BindError}}
            end;
        OpenError ->
            {stop, {open_error, OpenError}}
    end.

%% @hidden
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%% @hidden
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @hidden
handle_info({accepted, Socket}, State) ->
    #listener_state{
        connections = Conns,
        max_connections = MaxConns,
        protocol = Protocol,
        protocol_args = Args,
        chunk_size = ChunkSize,
        recv_timeout = RecvTimeout
    } = State,
    case MaxConns > 0 andalso map_size(Conns) >= MaxConns of
        true ->
            ?TRACE("Connection limit reached (~p), rejecting at accept", [MaxConns]),
            try_close(Socket),
            {noreply, State};
        false ->
            {Pid, Ref} = spawn_monitor(fun() ->
                worker_init(Socket, Protocol, Args, ChunkSize, RecvTimeout)
            end),
            ?TRACE("Tracking new connection worker ~p (~p/~p)", [
                Pid, map_size(Conns) + 1, MaxConns
            ]),
            {noreply, State#listener_state{connections = Conns#{Pid => Ref}}}
    end;
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    #listener_state{connections = Conns} = State,
    ?TRACE("Worker ~p down: ~p", [Pid, _Reason]),
    {noreply, State#listener_state{connections = maps:remove(Pid, Conns)}};
handle_info({'EXIT', _Pid, _Reason}, State) ->
    %% Acceptor (linked) exited.  Respawn it so the accept loop survives
    %% transient errors.  If the listen socket is gone this will keep failing,
    %% but socket:accept errors are handled with a backoff inside accept_loop.
    ?TRACE("Linked process ~p exited: ~p; respawning acceptor", [_Pid, _Reason]),
    #listener_state{listen_socket = ListenSocket} = State,
    Self = self(),
    spawn_link(fun() -> accept_loop(Self, ListenSocket) end),
    {noreply, State};
handle_info(_Info, State) ->
    ?TRACE("Unexpected listener info: ~p", [_Info]),
    {noreply, State}.

%% @hidden
terminate(_Reason, State) ->
    #listener_state{listen_socket = ListenSocket, connections = Conns} = State,
    %% Kill workers so their sockets are released (AtomVM socket_dtor / OTP
    %% resource GC closes them on process death).
    maps:foreach(
        fun(Pid, _Ref) -> exit(Pid, shutdown) end,
        Conns
    ),
    try_close(ListenSocket),
    ok.

%%
%% Acceptor process
%%

%% @private
%% Pure accept loop.  Never runs protocol code, so it cannot be taken down by a
%% protocol crash.  Forwards each accepted socket to the listener, which spawns
%% and monitors the worker.
accept_loop(Listener, ListenSocket) ->
    case socket:accept(ListenSocket) of
        {ok, Connection} ->
            ?TRACE("Accepted connection ~p", [Connection]),
            Listener ! {accepted, Connection},
            accept_loop(Listener, ListenSocket);
        _Error ->
            ?TRACE("Error accepting connection: ~p", [_Error]),
            timer:sleep(100),
            accept_loop(Listener, ListenSocket)
    end.

%%
%% Connection worker process
%%

%% @private
worker_init(Socket, Protocol, Args, ChunkSize, RecvTimeout) ->
    case Protocol:init(Socket, Args) of
        {ok, State} ->
            worker_loop(Socket, Protocol, State, ChunkSize, RecvTimeout);
        {error, _Reason} ->
            ?TRACE("Protocol init refused connection: ~p", [_Reason]),
            try_close(Socket)
    end.

%% @private
worker_loop(Socket, Protocol, State, ChunkSize, RecvTimeout) ->
    case drain_messages(Protocol, State) of
        {ok, NewState} ->
            case socket:recv(Socket, 0, RecvTimeout) of
                {ok, Data} ->
                    handle_protocol_result(
                        Protocol:handle_data(Data, NewState),
                        Socket, Protocol, ChunkSize, RecvTimeout
                    );
                {error, timeout} ->
                    %% Idle recv timeout: let the protocol decide (if it cares),
                    %% otherwise loop back to re-check messages and keep waiting.
                    case call_handle_timeout(Protocol, NewState) of
                        {continue, TState} ->
                            worker_loop(Socket, Protocol, TState, ChunkSize, RecvTimeout);
                        {close, TState} ->
                            Protocol:handle_close(timeout, TState),
                            try_close(Socket)
                    end;
                {error, closed} ->
                    ?TRACE("Peer closed connection ~p", [Socket]),
                    Protocol:handle_close(closed, NewState);
                {error, Reason} ->
                    ?TRACE("recv error ~p on ~p", [Reason, Socket]),
                    Protocol:handle_close(Reason, NewState),
                    try_close(Socket)
            end;
        {send, Response, NewState} ->
            case do_send(Socket, Response, ChunkSize) of
                ok ->
                    worker_loop(Socket, Protocol, NewState, ChunkSize, RecvTimeout);
                {error, Reason} ->
                    Protocol:handle_close(Reason, NewState),
                    try_close(Socket)
            end;
        {close, NewState} ->
            Protocol:handle_close(normal, NewState),
            try_close(Socket)
    end.

%% @private
handle_protocol_result(Result, Socket, Protocol, ChunkSize, RecvTimeout) ->
    case Result of
        {send, Response, NewState} ->
            case do_send(Socket, Response, ChunkSize) of
                ok ->
                    worker_loop(Socket, Protocol, NewState, ChunkSize, RecvTimeout);
                {error, Reason} ->
                    Protocol:handle_close(Reason, NewState),
                    try_close(Socket)
            end;
        {send_close, Response} ->
            _ = do_send(Socket, Response, ChunkSize),
            try_close(Socket);
        {continue, NewState} ->
            worker_loop(Socket, Protocol, NewState, ChunkSize, RecvTimeout);
        {close, NewState} ->
            Protocol:handle_close(normal, NewState),
            try_close(Socket);
        {error, _Reason} ->
            ?TRACE("Protocol handle_data error: ~p", [_Reason]),
            try_close(Socket)
    end.

%% @private
%% Drain any pending messages in the worker mailbox before blocking on recv.
drain_messages(Protocol, State) ->
    receive
        {tcp_server, close} ->
            {close, State};
        Msg ->
            case call_handle_info(Protocol, Msg, State) of
                {ok, NewState} -> drain_messages(Protocol, NewState);
                {send, Response, NewState} -> {send, Response, NewState};
                {close, NewState} -> {close, NewState}
            end
    after 0 ->
        {ok, State}
    end.

%% @private
call_handle_timeout(Protocol, State) ->
    case erlang:function_exported(Protocol, handle_timeout, 1) of
        true -> Protocol:handle_timeout(State);
        false -> {continue, State}
    end.

%% @private
call_handle_info(Protocol, Msg, State) ->
    case erlang:function_exported(Protocol, handle_info, 2) of
        true ->
            Protocol:handle_info(Msg, State);
        false ->
            ?TRACE("Discarding message (no handle_info/2): ~p", [Msg]),
            {ok, State}
    end.

%%
%% internal functions
%%

%% @private
%% Max retries for a chunk that fails with a (transient) send error before
%% giving up.  On ESP32/lwIP a socket:send that overruns the small TCP send
%% buffer (a few KB, ~4 × TCP_MSS) surfaces as transient backpressure:
%% `tcp_write' returns `ERR_MEM', which AtomVM maps to `{error, eagain}'.
%% (Older AtomVM builds without that mapping reported the same condition as
%% `{error, closed}', so both reasons are retried for version compatibility.)
%% Empirically a single 64KB response truncated ~65% of the time without retry,
%% and 0% with it.  Each retry backs off ~10ms, so a genuinely-dead connection
%% stalls at most ~MAX_SEND_RETRIES * 10ms before we abandon it.
-define(MAX_SEND_RETRIES, 50).

%% Send error reasons treated as transient backpressure (retry with backoff)
%% rather than fatal.  `eagain' is the AtomVM lwIP/BSD backpressure signal;
%% `closed' is retained for older AtomVM builds that reported backpressure as a
%% (spurious) close.
-define(IS_TRANSIENT_SEND_ERROR(Reason), (Reason =:= eagain orelse Reason =:= closed)).

do_send(Socket, Packet, ChunkSize) ->
    do_send(Socket, Packet, ChunkSize, 0).

do_send(_Socket, <<>>, _ChunkSize, _Retries) ->
    ok;
do_send(Socket, Packet, ChunkSize, Retries) when is_list(Packet) ->
    do_send(Socket, erlang:iolist_to_binary(Packet), ChunkSize, Retries);
do_send(Socket, Packet, ChunkSize, Retries) when is_binary(Packet) ->
    TotalSize = byte_size(Packet),
    Chunk = erlang:min(TotalSize, ChunkSize),
    <<ToSend:Chunk/binary, Rest/binary>> = Packet,
    case socket:send(Socket, ToSend) of
        ok ->
            %% Whole chunk accepted.  Yield before the next chunk so we don't
            %% monopolise the scheduler on large responses.
            case byte_size(Rest) > 0 of
                true -> receive after 0 -> ok end;
                false -> ok
            end,
            do_send(Socket, Rest, ChunkSize, 0);
        {ok, Unsent} ->
            %% Partial send (BSD-style): only some of ToSend went out.  Forward
            %% progress is made when fewer bytes are unsent than we attempted;
            %% reset the retry budget in that case.  If *no* bytes went out
            %% (Unsent == ToSend), treat it as backpressure so a stuck socket
            %% cannot loop forever.
            UnsentSize = byte_size(Unsent),
            Remainder = <<Unsent/binary, Rest/binary>>,
            case UnsentSize < Chunk of
                true ->
                    ?TRACE("Partial send: unsent=~p of chunk=~p", [UnsentSize, Chunk]),
                    receive after 10 -> ok end,
                    do_send(Socket, Remainder, ChunkSize, 0);
                false ->
                    ?TRACE("Partial send made no progress (~p bytes)", [UnsentSize]),
                    retry_send(Socket, Remainder, ChunkSize, Retries, no_progress, TotalSize)
            end;
        {error, Reason} when ?IS_TRANSIENT_SEND_ERROR(Reason) ->
            %% Transient send-buffer backpressure (lwIP ERR_MEM -> eagain; or a
            %% spurious closed on older AtomVM).  Retry with a short backoff and
            %% only abandon the response once the bounded retry budget is spent.
            retry_send(Socket, Packet, ChunkSize, Retries, Reason, TotalSize);
        {error, Reason} ->
            %% Genuine, non-transient failure (e.g. the peer really closed on a
            %% patched AtomVM, or an invalid-argument error).  Give up now.
            ?TRACE("Send failed permanently: ~p (remaining ~p)", [Reason, TotalSize]),
            {error, Reason}
    end.

%% @private
retry_send(_Socket, _Packet, _ChunkSize, Retries, Reason, _TotalSize)
        when Retries >= ?MAX_SEND_RETRIES ->
    ?TRACE("Send giving up after ~p retries: ~p (remaining ~p)", [Retries, Reason, _TotalSize]),
    {error, Reason};
retry_send(Socket, Packet, ChunkSize, Retries, _Reason, _TotalSize) ->
    ?TRACE("Send error ~p; retry ~p (remaining ~p)", [_Reason, Retries, _TotalSize]),
    receive after 10 -> ok end,
    do_send(Socket, Packet, ChunkSize, Retries + 1).

%% @private
try_close(Socket) ->
    case socket:close(Socket) of
        ok ->
            ok;
        _Error ->
            ?TRACE("Close failed due to error ~p", [_Error]),
            ok
    end.

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
