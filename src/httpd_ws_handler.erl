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
-module(httpd_ws_handler).

%% internal API only called by httpd_ws_handler
-export([start/3, stop/1, handle_web_socket_message/2]).
%% API used by implementors of the httpd_ws_handler behavior
-export([send/2]).

-behavior(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

% -define(TRACE_ENABLED, true).
-include_lib("atomvm_httpd/include/trace.hrl").

%% Send-chunk size used when streaming framed packets through tcp_server (keeps
%% each socket:send within the small lwIP send buffer on ESP32).
-define(SEND_CHUNK_SIZE, 4096).

-type websocket() :: term().

-export_type([websocket/0]).

%%
%% httpd_ws_handler behavior
%%

-callback handle_ws_init(WebSocket :: websocket(), Path :: httpd:path(), Args :: term()) ->
    {ok, State :: term()} |
    term().

-callback handle_ws_message(PayloadData :: binary(), State :: term()) ->
    {reply, Reply :: iolist(), NewState :: term()} |
    {noreply, NewState :: term()} |
    {close, Reply :: iolist(), NewState :: term()} |
    {close, NewState :: term()} |
    term().

%%
%% API
%%

%% @hidden
start(Socket, Path, Config) ->
    %% Linked to the owning tcp_server connection worker: if the worker (and
    %% therefore the connection) goes away, the WebSocket process must not leak.
    gen_server:start_link(?MODULE, {Socket, Path, Config}, []).

%% @hidden
stop(WebSocket) ->
    gen_server:stop(WebSocket).


%% @hidden
handle_web_socket_message(WebSocket, Packet) ->
    gen_server:cast(WebSocket, {message, Packet}).

send(WebSocket, Packet) ->
    gen_server:cast(WebSocket, {send, Packet}).


%%
%% gen_server implementation
%%

-record(state, {
    socket,
    handler_module,
    handler_state,
    frame_buffer = <<>>  %% Buffer for incomplete WebSocket frames
}).

%% @hidden
init({Socket, Path, Config}) ->
    ?TRACE("Started WebSocket using socket ~p with Config ~p", [Socket, Config]),
    case maps:get(module, Config, undefined) of
        undefined ->
            {stop, bad_config};
        HandlerModule ->
            case HandlerModule:handle_ws_init(self(), Path, maps:get(args, Config, undefined)) of
                {ok, HandlerState} ->
                    {ok, #state{socket=Socket, handler_module=HandlerModule, handler_state=HandlerState}};
                Error ->
                    {stop, Error}
            end
    end.

%% @hidden
handle_cast({message, Packet}, State) ->
    ?TRACE("WebSocket received packet ~p", [Packet]),
    #state{frame_buffer = Buffer} = State,
    %% Coalesce with any partial frame left over from previous packets and
    %% dispatch every complete frame found in the buffer.
    handle_frames(<<Buffer/binary, Packet/binary>>, State);
%% @hidden
handle_cast({send, Packet}, State) ->
    ?TRACE("Sending packet ~p", [Packet]),
    do_send(State#state.socket, Packet, text),
    {noreply, State}.

%% @hidden
handle_call(_Request, _From, State) ->
    {reply, ok, State}.


%% @hidden
handle_info(_Msg, State) ->
    {noreply, State}.

%% @hidden
terminate(_Reason, _State) ->
    ok.


%%
%% internal implementation
%%

%% @private
%% Process every complete frame currently in the buffer.  A single TCP packet
%% may contain several coalesced WebSocket frames (or the tail of one frame plus
%% the next), and each must be dispatched to the handler module.
handle_frames(Buffer, State) ->
    #state{
        socket = Socket,
        handler_module = HandlerModule,
        handler_state = HandlerState
    } = State,
    case parse_frame(Buffer) of
        {ok, PayloadData, Remaining} ->
            ?TRACE("HandlerModule ~p; PayloadData ~p; Remaining ~p bytes", [
                HandlerModule, PayloadData, erlang:byte_size(Remaining)
            ]),
            NewState = State#state{frame_buffer = Remaining},
            case HandlerModule:handle_ws_message(PayloadData, HandlerState) of
                {reply, Reply, NewHandlerState} ->
                    ?TRACE("Handled WS payload.  NewHandlerState: ~p", [NewHandlerState]),
                    case do_send(Socket, Reply, text) of
                        ok ->
                            handle_frames(Remaining, NewState#state{
                                handler_state = NewHandlerState
                            });
                        {error, _SendError} ->
                            ?TRACE("Send failed after reply: ~p", [_SendError]),
                            close_socket(Socket),
                            {stop, normal, NewState#state{
                                handler_state = NewHandlerState,
                                frame_buffer = <<>>
                            }}
                    end;
                {noreply, NewHandlerState} ->
                    ?TRACE("Handled WS payload.  NewHandlerState: ~p", [NewHandlerState]),
                    handle_frames(Remaining, NewState#state{handler_state = NewHandlerState});
                {close, Reply, NewHandlerState} ->
                    ?TRACE("Handler requested close after reply", []),
                    do_send(Socket, Reply, text),
                    close_socket(Socket),
                    {stop, normal, NewState#state{handler_state = NewHandlerState, frame_buffer = <<>>}};
                {close, NewHandlerState} ->
                    ?TRACE("Handler requested close", []),
                    close_socket(Socket),
                    {stop, normal, NewState#state{handler_state = NewHandlerState, frame_buffer = <<>>}};
                _HandlerModuleError ->
                    ?TRACE("HandlerModuleError: ~p", [_HandlerModuleError]),
                    close_socket(Socket),
                    {stop, normal, State}
            end;
        incomplete ->
            ?TRACE("Incomplete frame, buffering ~p bytes", [erlang:byte_size(Buffer)]),
            {noreply, State#state{frame_buffer = Buffer}};
        empty_payload ->
            ?TRACE("Empty payload.", []),
            {noreply, State#state{frame_buffer = <<>>}};
        _ParseFrameError ->
            ?TRACE("ParseFrameError: ~p", [_ParseFrameError]),
            close_socket(Socket),
            {stop, normal, State}
    end.

%% @private
%% @private
parse_frame(<<0,0,0,0,0,0,0,0,0,0>>) ->
    empty_payload;
parse_frame(Packet) when byte_size(Packet) < 2 ->
    incomplete;
parse_frame(Packet) ->
    try
        <<_FinOpcode:8, MaskLen:8, Rest/binary>> = Packet,
        Mask = (MaskLen band 16#80) bsr 7,
        PayloadLen = MaskLen band 16#7F,
        
        %% Calculate how many bytes we need for the complete frame
        {ActualPayloadLen, HeaderSize} = case PayloadLen of
            126 ->
                case byte_size(Rest) >= 2 of
                    true ->
                        <<Len:16, _/binary>> = Rest,
                        {Len, 2};
                    false ->
                        {need_more, 2}
                end;
            127 ->
                case byte_size(Rest) >= 8 of
                    true ->
                        <<Len:64, _/binary>> = Rest,
                        {Len, 8};
                    false ->
                        {need_more, 8}
                end;
            Len ->
                {Len, 0}
        end,
        
        case ActualPayloadLen of
            need_more ->
                incomplete;
            _ ->
                MaskSize = case Mask of 1 -> 4; _ -> 0 end,
                RequiredBytes = HeaderSize + MaskSize + ActualPayloadLen,
                
                case byte_size(Rest) >= RequiredBytes of
                    true ->
                        %% We have enough data to parse the complete frame
                        parse_complete_frame(PayloadLen, Mask, Rest);
                    false ->
                        ?TRACE("Incomplete frame: have ~p bytes, need ~p", [byte_size(Packet), 2 + RequiredBytes]),
                        incomplete
                end
        end
    catch
        _:Error ->
            ?TRACE("Error in parse_frame: ~p", [Error]),
            {error, Error}
    end.

%% @private
parse_complete_frame(PayloadLen, Mask, Rest) ->
    case PayloadLen of
        0 ->
            {ok, <<"">>, Rest};
        126 ->
            <<MediumPayloadLen:16, Rest2/binary>> = Rest,
            extract_payload(Mask, MediumPayloadLen, Rest2);
        127 ->
            <<LargePayloadLen:64, Rest2/binary>> = Rest,
            extract_payload(Mask, LargePayloadLen, Rest2);
        _ ->
            extract_payload(Mask, PayloadLen, Rest)
    end.

%% @private
extract_payload(Mask, PayloadLen, Data) ->
    case Mask of
        1 ->
            <<MaskingKey:4/binary, MaskedPayload:PayloadLen/binary, Remaining/binary>> = Data,
            ?TRACE("MaskingKey: ~p, MaskedPayload length: ~p", [MaskingKey, byte_size(MaskedPayload)]),
            {ok, unmask(MaskingKey, MaskedPayload), Remaining};
        _ ->
            <<Payload:PayloadLen/binary, Remaining/binary>> = Data,
            {ok, Payload, Remaining}
    end.

%% @private
unmask(<<K0:8, K1:8, K2:8, K3:8>>, Payload) ->
    Size = byte_size(Payload),
    FullChunks = Size bsr 2,
    Rem = Size band 3,
    case Rem of
        0 ->
            << <<(A bxor K0), (B bxor K1), (C bxor K2), (D bxor K3)>> ||
                <<A, B, C, D>> <= Payload >>;
        _ ->
            ChunkSize = FullChunks bsl 2,
            <<ChunkedPart:ChunkSize/binary, Tail/binary>> = Payload,
            Unmasked = << <<(A bxor K0), (B bxor K1), (C bxor K2), (D bxor K3)>> ||
                <<A, B, C, D>> <= ChunkedPart >>,
            <<Unmasked/binary, (unmask_rem(Tail, K0, K1, K2, K3, Rem))/binary>>
    end.

unmask_rem(<<>>, _, _, _, _, 0) -> <<>>;
unmask_rem(<<B>>, K0, _, _, _, 1) -> <<(B bxor K0)>>;
unmask_rem(<<B, C>>, K0, K1, _, _, 2) -> <<(B bxor K0), (C bxor K1)>>;
unmask_rem(<<B, C, D>>, K0, K1, K2, _, 3) -> <<(B bxor K0), (C bxor K1), (D bxor K2)>>.

%% @private
do_send(Socket, Packet, Mode) ->
    FramedPacket = frame(Packet, Mode),
    ?TRACE("Sending framed packet of ~p bytes", [erlang:iolist_size(FramedPacket)]),
    %% Stream through tcp_server so large frames honour the send-chunk size and
    %% the lwIP backpressure / partial-send retry logic.
    tcp_server:send(Socket, FramedPacket, ?SEND_CHUNK_SIZE).

%% @private
close_socket(Socket) ->
    catch socket:close(Socket),
    ok.

%% @private
%% Build the frame header separately and return iodata, so a large payload
%% (binary or iolist) is streamed zero-copy instead of being flattened into a
%% single binary together with its header.
frame(Packet, Mode) when is_list(Packet) orelse is_binary(Packet) ->
    Fin = 16#80,
    Opcode = case Mode of text -> 16#01; binary -> 16#02; _ -> 16#01 end,
    FinOpcode = Fin bor Opcode,
    PayloadLen = erlang:iolist_size(Packet),
    Header =
        case PayloadLen of
            _ when PayloadLen =< 125 ->
                <<FinOpcode:8, PayloadLen:8>>;
            _ when PayloadLen < 65536 ->
                <<FinOpcode:8, 126:8, PayloadLen:16/unsigned>>;
            _ ->
                <<FinOpcode:8, 127:8, PayloadLen:64/unsigned>>
        end,
    [Header, Packet].
