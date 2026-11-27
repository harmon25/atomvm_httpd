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

-export([start/3, start/4, start_link/3, start_link/4, stop/1, send/3, send/4]).

-ifdef(TEST).
-export([next_chunk/2]).
-endif.

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
%% Default timeout for a single socket:send/3 call.  AtomVM release-0.7 supports
%% socket:send/3 and blocks until the data is buffered (or the timeout fires),
%% which is far more reliable than tight retry loops against a small lwIP send
%% buffer.  `infinity' is accepted as well.
-define(DEFAULT_SEND_TIMEOUT, 5000).
%% Bound the temporary list used to coalesce small iodata leaves.  A byte limit
%% alone is not enough: a JSON response can contain thousands of one-byte
%% punctuation elements, each of which occupies a cons cell.
-define(MAX_CHUNK_ENTRIES, 64).
%% When next_chunk/2 is limited by MAX_CHUNK_ENTRIES (rather than by the byte
%% budget) the resulting chunk can be tiny (e.g. 64 one-byte leaves).  We
%% coalesce up to this many following mini-chunks into a single binary before
%% sending so headers + small JSON bodies are not fragmented into 64-byte TCP
%% segments.
-define(MAX_COALESCE_CHUNKS, 16).
%% Application-level keys (chunk_size, max_connections, recv_timeout,
%% send_timeout) ride in the SocketOptions map but must never reach
%% socket:setopt/3.  They are stripped with nested maps:remove/2 in init/1 —
%% AtomVM's maps module does not implement maps:without/2.

-record(listener_state, {
    listen_socket,
    acceptor_pid,
    protocol,
    protocol_args,
    chunk_size = ?DEFAULT_SEND_CHUNK,
    send_timeout = ?DEFAULT_SEND_TIMEOUT,
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

%% @doc Chunked send helper for protocol modules.  Runs in the calling (worker)
%% process, so blocking is fine.  Returns ok | {error, Reason}.
send(Socket, Data, ChunkSize) ->
    send(Socket, Data, ChunkSize, ?DEFAULT_SEND_TIMEOUT).

%% @doc As send/3, but with an explicit per-send timeout (ms | infinity).
send(Socket, Data, ChunkSize, SendTimeout) ->
    do_send(Socket, Data, ChunkSize, SendTimeout).

%%
%% gen_server (listener) implementation
%%

%% @hidden
init({BindOptions, SocketOptions, Protocol, Args}) ->
    process_flag(trap_exit, true),
    MaxConnections = maps:get(max_connections, SocketOptions, 0),
    ChunkSize = maps:get(chunk_size, SocketOptions, ?DEFAULT_SEND_CHUNK),
    SendTimeout = maps:get(send_timeout, SocketOptions, ?DEFAULT_SEND_TIMEOUT),
    RecvTimeout = maps:get(recv_timeout, SocketOptions, infinity),
    %% Strip application-level keys before socket:setopt/3 so the AtomVM setopt
    %% allow-list is never violated (would crash the server).  Nested
    %% maps:remove/2 — maps:without/2 is not available on AtomVM.
    CleanSocketOptions =
        maps:remove(
            send_timeout,
            maps:remove(
                recv_timeout,
                maps:remove(chunk_size, maps:remove(max_connections, SocketOptions))
            )
        ),
    case socket:open(inet, stream, tcp) of
        {ok, ListenSocket} ->
            try set_socket_options(ListenSocket, CleanSocketOptions) of
                ok ->
                    case socket:bind(ListenSocket, BindOptions) of
                        ok ->
                            case socket:listen(ListenSocket) of
                                ok ->
                                    Self = self(),
                                    AcceptorPid =
                                        spawn_link(fun() -> accept_loop(Self, ListenSocket) end),
                                    {ok, #listener_state{
                                        listen_socket = ListenSocket,
                                        acceptor_pid = AcceptorPid,
                                        protocol = Protocol,
                                        protocol_args = Args,
                                        chunk_size = ChunkSize,
                                        send_timeout = SendTimeout,
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
                    end
            catch
                Class:Reason ->
                    %% e.g. an option outside the AtomVM setopt allow-list.  Close
                    %% the listen socket so the lwIP fd is not leaked on restart.
                    ?TRACE("Socket option setup failed: ~p:~p", [Class, Reason]),
                    try_close(ListenSocket),
                    {stop, {socket_options_error, {Class, Reason}}}
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
        send_timeout = SendTimeout,
        recv_timeout = RecvTimeout
    } = State,
    case MaxConns > 0 andalso map_size(Conns) >= MaxConns of
        true ->
            ?TRACE("Connection limit reached (~p), rejecting at accept", [MaxConns]),
            try_close(Socket),
            {noreply, State};
        false ->
            {Pid, Ref} = spawn_monitor(fun() ->
                worker_init(Socket, Protocol, Args, ChunkSize, SendTimeout, RecvTimeout)
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
handle_info({'EXIT', Pid, Reason}, State) ->
    #listener_state{acceptor_pid = AcceptorPid, listen_socket = ListenSocket} = State,
    case Pid =:= AcceptorPid of
        false ->
            %% Not our acceptor (e.g. a stray linked process); ignore it.
            ?TRACE("Ignoring EXIT from unrelated process ~p: ~p", [Pid, Reason]),
            {noreply, State};
        true ->
            case Reason of
                Normal when Normal =:= normal; Normal =:= shutdown ->
                    %% Clean acceptor termination (listen socket closed): do not
                    %% respawn, which would otherwise spin against a dead socket.
                    ?TRACE("Acceptor ~p terminated cleanly (~p)", [Pid, Reason]),
                    {noreply, State#listener_state{acceptor_pid = undefined}};
                _ ->
                    %% Acceptor crashed; respawn it so the accept loop survives
                    %% transient/unknown failures.
                    ?TRACE("Acceptor ~p exited: ~p; respawning", [Pid, Reason]),
                    Self = self(),
                    NewAcceptor = spawn_link(fun() -> accept_loop(Self, ListenSocket) end),
                    {noreply, State#listener_state{acceptor_pid = NewAcceptor}}
            end
    end;
handle_info(_Info, State) ->
    ?TRACE("Unexpected listener info: ~p", [_Info]),
    {noreply, State}.

%% @hidden
terminate(_Reason, State) ->
    #listener_state{
        listen_socket = ListenSocket,
        acceptor_pid = AcceptorPid,
        connections = Conns
    } = State,
    %% Stop the acceptor explicitly: it does not trap exits, so this kills it
    %% immediately instead of leaving an orphan blocked in socket:accept/1.
    case AcceptorPid of
        undefined -> ok;
        Pid -> exit(Pid, shutdown)
    end,
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
        {error, Reason} when Reason =:= closed; Reason =:= ebadf; Reason =:= einval ->
            %% Listen socket has been closed (server shutdown): exit instead of
            %% spinning so no acceptor process outlives the listener.
            ?TRACE("Accept loop stopping: ~p", [Reason]),
            ok;
        _Error ->
            ?TRACE("Error accepting connection: ~p", [_Error]),
            timer:sleep(100),
            accept_loop(Listener, ListenSocket)
    end.

%%
%% Connection worker process
%%

%% @private
worker_init(Socket, Protocol, Args, ChunkSize, SendTimeout, RecvTimeout) ->
    case Protocol:init(Socket, Args) of
        {ok, State} ->
            worker_loop(Socket, Protocol, State, ChunkSize, SendTimeout, RecvTimeout);
        {error, _Reason} ->
            ?TRACE("Protocol init refused connection: ~p", [_Reason]),
            try_close(Socket)
    end.

%% @private
worker_loop(Socket, Protocol, State, ChunkSize, SendTimeout, RecvTimeout) ->
    case drain_messages(Protocol, State) of
        {ok, NewState} ->
            case socket:recv(Socket, 0, RecvTimeout) of
                {ok, Data} ->
                    handle_protocol_result(
                        Protocol:handle_data(Data, NewState),
                        Socket, Protocol, ChunkSize, SendTimeout, RecvTimeout
                    );
                {error, timeout} ->
                    %% Idle recv timeout: let the protocol decide (if it cares),
                    %% otherwise loop back to re-check messages and keep waiting.
                    case call_handle_timeout(Protocol, NewState) of
                        {continue, TState} ->
                            worker_loop(
                                Socket, Protocol, TState, ChunkSize, SendTimeout, RecvTimeout
                            );
                        {close, TState} ->
                            Protocol:handle_close(timeout, TState),
                            try_close(Socket)
                    end;
                {error, closed} ->
                    ?TRACE("Peer closed connection ~p", [Socket]),
                    Protocol:handle_close(closed, NewState),
                    %% Release the lwIP fd deterministically; do not rely on GC.
                    try_close(Socket);
                {error, Reason} ->
                    ?TRACE("recv error ~p on ~p", [Reason, Socket]),
                    Protocol:handle_close(Reason, NewState),
                    try_close(Socket)
            end;
        {send, Response, NewState} ->
            case do_send(Socket, Response, ChunkSize, SendTimeout) of
                ok ->
                    worker_loop(Socket, Protocol, NewState, ChunkSize, SendTimeout, RecvTimeout);
                {error, Reason} ->
                    Protocol:handle_close(Reason, NewState),
                    try_close(Socket)
            end;
        {close, NewState} ->
            Protocol:handle_close(normal, NewState),
            try_close(Socket)
    end.

%% @private
handle_protocol_result(Result, Socket, Protocol, ChunkSize, SendTimeout, RecvTimeout) ->
    case Result of
        {send, Response, NewState} ->
            case do_send(Socket, Response, ChunkSize, SendTimeout) of
                ok ->
                    worker_loop(Socket, Protocol, NewState, ChunkSize, SendTimeout, RecvTimeout);
                {error, Reason} ->
                    Protocol:handle_close(Reason, NewState),
                    try_close(Socket)
            end;
        {send_close, Response} ->
            _ = do_send(Socket, Response, ChunkSize, SendTimeout),
            try_close(Socket);
        {continue, NewState} ->
            worker_loop(Socket, Protocol, NewState, ChunkSize, SendTimeout, RecvTimeout);
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
%% buffer (default ~8KB) can surface as a transient error even though the
%% connection is alive.  Each retry backs off ~10ms, so a genuinely-dead
%% connection stalls at most ~MAX_SEND_RETRIES * 10ms before we abandon it.
-define(MAX_SEND_RETRIES, 50).

do_send(Socket, Packet, ChunkSize, SendTimeout) ->
    do_send_iodata(Socket, Packet, ChunkSize, SendTimeout).

%% Walk nested iodata incrementally instead of flattening the complete response.
%% next_chunk/2 bounds both bytes and list entries, so peak temporary memory is
%% independent of the total response size.
do_send_iodata(Socket, Packet, ChunkSize, SendTimeout) ->
    case next_chunk(Packet, ChunkSize) of
        done ->
            ok;
        {Chunk, Rest} ->
            {ToSend, NextRest} = build_send_batch(Chunk, Rest, ChunkSize),
            case send_chunk(Socket, ToSend, SendTimeout, 0) of
                ok ->
                    case NextRest of
                        [] ->
                            ok;
                        _ ->
                            receive after 0 -> ok end,
                            do_send_iodata(Socket, NextRest, ChunkSize, SendTimeout)
                    end;
                {error, _Reason} = Error ->
                    Error
            end
    end.

%% @private
%% next_chunk/2 bounds entry count as well as bytes, so a chunk made of many
%% one-byte leaves stops at MAX_CHUNK_ENTRIES bytes (64) even when ChunkSize is
%% 4096.  Sending those tiny chunks one at a time fragments headers + small JSON
%% bodies into 64-byte TCP segments.  Collect up to MAX_COALESCE_CHUNKS following
%% mini-chunks (bounded by ChunkSize total bytes) and send them as one binary.
%% Each collected chunk is converted to a binary immediately, so at most
%% MAX_CHUNK_ENTRIES cons cells exist at any moment.
build_send_batch(Chunk, Rest, ChunkSize) ->
    First = chunk_to_binary(Chunk),
    Size = byte_size(First),
    case Rest of
        [] ->
            {First, []};
        _ when Size >= ChunkSize ->
            {First, Rest};
        _ ->
            collect_batch(Rest, ChunkSize, Size, ?MAX_COALESCE_CHUNKS, [First])
    end.

%% @private
collect_batch(Rest, _ChunkSize, _Size, 0, Acc) ->
    {finalize_batch(Acc), Rest};
collect_batch([], _ChunkSize, _Size, _Left, Acc) ->
    {finalize_batch(Acc), []};
collect_batch(Rest, ChunkSize, Size, Left, Acc) ->
    case next_chunk(Rest, ChunkSize) of
        done ->
            {finalize_batch(Acc), []};
        {Chunk, NextRest} ->
            Bin = chunk_to_binary(Chunk),
            NewSize = Size + byte_size(Bin),
            case NewSize > ChunkSize of
                true ->
                    %% Would overflow the byte budget: keep it for the next round.
                    %% Push back the already-converted binary rather than the raw
                    %% chunk so next_chunk/2 does not re-walk and re-convert it.
                    {finalize_batch(Acc), [Bin | NextRest]};
                false ->
                    collect_batch(NextRest, ChunkSize, NewSize, Left - 1, [Bin | Acc])
            end
    end.

%% @private
finalize_batch([Single]) ->
    Single;
finalize_batch(Acc) ->
    erlang:iolist_to_binary(lists:reverse(Acc)).

%% @private
next_chunk(Iodata, ChunkSize) when is_integer(ChunkSize) andalso ChunkSize > 0 ->
    take_chunk([Iodata], ChunkSize, ?MAX_CHUNK_ENTRIES, []);
next_chunk(_Iodata, _ChunkSize) ->
    erlang:error(badarg).

take_chunk([], _BytesLeft, _EntriesLeft, []) ->
    done;
take_chunk([], _BytesLeft, _EntriesLeft, Acc) ->
    {lists:reverse(Acc), []};
take_chunk(Pending, 0, _EntriesLeft, Acc) ->
    {lists:reverse(Acc), Pending};
take_chunk(Pending, _BytesLeft, 0, Acc) ->
    {lists:reverse(Acc), Pending};
take_chunk([[] | Rest], BytesLeft, EntriesLeft, Acc) ->
    take_chunk(Rest, BytesLeft, EntriesLeft, Acc);
take_chunk([Byte | Rest], BytesLeft, EntriesLeft, Acc)
        when is_integer(Byte) andalso Byte >= 0 andalso Byte =< 255 ->
    take_chunk(Rest, BytesLeft - 1, EntriesLeft - 1, [Byte | Acc]);
take_chunk([Bin | Rest], BytesLeft, EntriesLeft, Acc) when is_binary(Bin) ->
    Size = byte_size(Bin),
    case Size of
        0 ->
            take_chunk(Rest, BytesLeft, EntriesLeft, Acc);
        _ when Size =< BytesLeft ->
            take_chunk(Rest, BytesLeft - Size, EntriesLeft - 1, [Bin | Acc]);
        _ ->
            <<Part:BytesLeft/binary, Remaining/binary>> = Bin,
            {lists:reverse([Part | Acc]), [Remaining | Rest]}
    end;
take_chunk([[Head | Tail] | Rest], BytesLeft, EntriesLeft, Acc) ->
    take_chunk([Head, Tail | Rest], BytesLeft, EntriesLeft, Acc);
take_chunk(_Pending, _BytesLeft, _EntriesLeft, _Acc) ->
    erlang:error(badarg).

%% Avoid copying when a chunk is already represented by one binary leaf.
chunk_to_binary([Bin]) when is_binary(Bin) ->
    Bin;
chunk_to_binary(Chunk) ->
    erlang:iolist_to_binary(Chunk).

send_chunk(_Socket, <<>>, _SendTimeout, _Retries) ->
    ok;
send_chunk(Socket, Chunk, SendTimeout, Retries) ->
    case socket:send(Socket, Chunk, SendTimeout) of
        ok ->
            ok;
        {ok, <<>>} ->
            ok;
        {ok, Unsent} when is_binary(Unsent) ->
            %% Host OTP partial send: retry only the unsent part of this bounded
            %% chunk.  The remaining response stays in its iodata traversal stack
            %% and is never copied together with Unsent.
            ?TRACE("Partial send: unsent=~p chunk=~p", [byte_size(Unsent), byte_size(Chunk)]),
            receive after 10 -> ok end,
            send_chunk(Socket, Unsent, SendTimeout, 0);
        {error, {Reason, RestData}} when is_binary(RestData) ->
            %% AtomVM release-0.7 shape: the error carries the bytes that were
            %% NOT written.  Retry only those bytes — resending the whole chunk
            %% would duplicate everything the stack already accepted.
            case is_transient_send_error(Reason) of
                true ->
                    ?TRACE("Partial send error ~p, retrying ~p unsent bytes", [
                        Reason, byte_size(RestData)
                    ]),
                    retry_send_chunk(Socket, RestData, SendTimeout, Retries, Reason);
                false ->
                    ?TRACE("Terminal send error ~p (~p unsent bytes)", [
                        Reason, byte_size(RestData)
                    ]),
                    {error, Reason}
            end;
        {error, Reason} ->
            case is_transient_send_error(Reason) of
                true ->
                    retry_send_chunk(Socket, Chunk, SendTimeout, Retries, Reason);
                false ->
                    %% Terminal (closed/econnreset/epipe/ebadf/timeout/...):
                    %% fail immediately instead of burning the retry budget.
                    ?TRACE("Terminal send error ~p; abandoning chunk", [Reason]),
                    {error, Reason}
            end;
        Other ->
            ?TRACE("Unexpected socket:send result: ~p", [Other]),
            {error, Other}
    end.

%% @private
%% Only genuine backpressure/out-of-memory conditions are worth retrying; every
%% other error means the connection cannot make progress.
is_transient_send_error(eagain) -> true;
is_transient_send_error(ewouldblock) -> true;
is_transient_send_error(enobufs) -> true;
is_transient_send_error(enomem) -> true;
is_transient_send_error(_Reason) -> false.

%% @private
retry_send_chunk(_Socket, _Chunk, _SendTimeout, Retries, Reason)
        when Retries >= ?MAX_SEND_RETRIES ->
    ?TRACE("Send giving up after ~p retries: ~p (chunk ~p)", [Retries, Reason, byte_size(_Chunk)]),
    {error, Reason};
retry_send_chunk(Socket, Chunk, SendTimeout, Retries, _Reason) ->
    ?TRACE("Send error ~p; retry ~p (chunk ~p)", [_Reason, Retries, byte_size(Chunk)]),
    receive after 10 -> ok end,
    send_chunk(Socket, Chunk, SendTimeout, Retries + 1).

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
