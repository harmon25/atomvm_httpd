%
% Copyright 2022 Fred Dushin <fred@dushin.net>
%
% Licensed under the Apache License, Version 2.0 (the "License");
% you may not use this file except in compliance with the License.
% You may obtain a copy of the License at
%
%    http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS,
% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
% See the License for the specific language governing permissions and
% limitations under the License.
%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%
%% An AtomVM HTTP/WebSocket example application.
%%
%% Serves a static dashboard from priv/ (httpd_file_handler), a JSON API under
%% /api (httpd_api_handler), live memory updates over a WebSocket at /ws
%% (httpd_ws_handler), and OTA firmware uploads at /ota (httpd_ota_handler).
%%

-module(httpd_example).

-behavior(httpd_api_handler).
-behavior(httpd_ws_handler).

-export([start/0, handle_api_request/4, handle_ws_init/3, handle_ws_message/2]).

start() ->
    timer:sleep(5000),

    ok = maybe_start_network(atomvm:platform()),

    timer:sleep(5000),

    Config = [
        {[<<"api">>], #{
            handler => httpd_api_handler,
            handler_config => #{
                module => ?MODULE
            }
        }},
        {[<<"ws">>], #{
            handler => httpd_ws_handler,
            handler_config => #{
                module => ?MODULE
            }
        }},
        {[<<"ota">>], #{
            handler => httpd_ota_handler
        }},
        {[], #{
            handler => httpd_file_handler,
            handler_config => #{
                app => ?MODULE
            }
        }}
    ],

    io:format("Starting httpd on port 8080 ...~n", []),
    case httpd:start_link(8080, Config) of
        {ok, _Pid} ->
            io:format("httpd started.~n", []),
            timer:sleep(infinity);
        Error ->
            io:format("An error occurred: ~p~n", [Error])
    end.

%%
%% API Handler implementation
%%

handle_api_request(get, [<<"system_info">>], HttpRequest, _Args) ->
    Socket = maps:get(socket, HttpRequest),
    {ok, #{addr := Host, port := Port}} = socket:peername(Socket),
    io:format("GET system_info request from ~p:~p~n", [Host, Port]),
    {ok, get_system_info()};
handle_api_request(get, [<<"memory">>], HttpRequest, _Args) ->
    Socket = maps:get(socket, HttpRequest),
    {ok, #{addr := Host, port := Port}} = socket:peername(Socket),
    io:format("GET memory request from ~p:~p~n", [Host, Port]),
    {ok, get_memory_data()};
handle_api_request(Method, Path, _HttpRequest, _Args) ->
    io:format("ERROR!  Unsupported method ~p or path ~p~n", [Method, Path]),
    {error, not_found}.

get_system_info() ->
    #{
        platform => atomvm:platform(),
        word_size => erlang:system_info(wordsize),
        system_architecture => to_binary(erlang:system_info(system_architecture)),
        atomvm_version => to_binary(erlang:system_info(atomvm_version)),
        esp32_chip_info => get_esp32_chip_info(),
        esp_idf_version => to_binary(erlang:system_info(esp_idf_version))
    }.

%% Charlists must be converted to binaries so json:encode/1 emits JSON strings
%% rather than arrays of integer code points.
to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> list_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(_) -> <<"unknown">>.

get_esp32_chip_info() ->
    case erlang:system_info(esp32_chip_info) of
        undefined ->
            null;
        %% Old AtomVM API
        {_Model, Features, Cores, Revision} ->
            #{features => Features, cores => Cores, revision => Revision, model => null};
        Info when is_map(Info) ->
            Info;
        _ ->
            null
    end.

get_memory_data() ->
    #{
        atom_count => erlang:system_info(atom_count),
        process_count => erlang:system_info(process_count),
        port_count => erlang:system_info(port_count),
        esp32_free_heap_size => erlang:system_info(esp32_free_heap_size),
        esp32_largest_free_block => erlang:system_info(esp32_largest_free_block),
        esp32_minimum_free_size => erlang:system_info(esp32_minimum_free_size)
    }.

%%
%% WebSocket handlers
%%

handle_ws_init(WebSocket, _Path, _Args) ->
    io:format("Initializing websocket pid=~p~n", [self()]),
    spawn(fun() -> update_loop(WebSocket, get_memory_data()) end),
    {ok, undefined}.

handle_ws_message(<<"ping">>, State) ->
    {reply, <<"pong">>, State};
handle_ws_message(Message, State) ->
    io:format("Received message from web socket.  Message: ~p~n", [Message]),
    {noreply, State}.

update_loop(WebSocket, LastMemoryData) ->
    %% Monitor the WebSocket process so this loop exits as soon as the client
    %% disconnects instead of polling with timer:sleep/1.
    Ref = erlang:monitor(process, WebSocket),
    receive
        {'DOWN', Ref, process, WebSocket, _Reason} ->
            ok
    after 5000 ->
        LatestMemoryData = get_memory_data(),
        NewMemoryData = get_difference(LastMemoryData, LatestMemoryData),
        case NewMemoryData of
            [] ->
                ok;
            _ ->
                Binary = iolist_to_binary(json:encode(maps:from_list(NewMemoryData))),
                io:format("Sending websocket message to client ~p ... ", [Binary]),
                httpd_ws_handler:send(WebSocket, Binary),
                io:format("sent.~n")
        end,
        erlang:demonitor(Ref, [flush]),
        update_loop(WebSocket, LatestMemoryData)
    end.

%%
%% Internal functions
%%

get_difference(Map1, Map2) ->
    maps:fold(
        fun(Key, Value, Accum) ->
            case maps:get(Key, Map2, undefined) of
                undefined ->
                    [{Key, Value} | Accum];
                Value ->
                    Accum;
                NewValue ->
                    [{Key, NewValue} | Accum]
            end
        end,
        [],
        Map1
    ).

maybe_start_network(esp32) ->
    Config = maps:get(sta, config:get()),
    case network:wait_for_sta(Config, 30000) of
        {ok, {Address, Netmask, Gateway}} ->
            io:format(
                "Acquired IP address: ~p Netmask: ~p Gateway: ~p~n",
                [Address, Netmask, Gateway]
            ),
            ok;
        {error, disconnected} ->
            maybe_start_network(esp32);
        {error, {already_started, _}} ->
            ok;
        Error ->
            io:format("An error occurred starting network: ~p~n", [Error]),
            Error
    end;
maybe_start_network(_Platform) ->
    ok.
