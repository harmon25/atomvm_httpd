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

-module(httpd_env_api_handler).

-behavior(httpd_api_handler).
-export([handle_api_request/4]).

% -define(TRACE_ENABLED, true).
-include_lib("atomvm_httpd/include/trace.hrl").

%%
%% API Handler implementation
%%

handle_api_request(get, [Application, Param | Rest], _HttpRequest, _Args) ->
    ?TRACE("Application: ~p Param: ~p, Rest: ~p", [Application, Param, Rest]),

    case to_existing_atoms(Application, Param) of
        {ok, ApplicationAtom, ParamAtom} ->
            Result = case avm_application:get_env(ApplicationAtom, ParamAtom) of
                undefined ->
                    undefined;
                {ok, Value} ->
                    find_value_in_path(Value, Rest)
                end,
            case Result of
                undefined ->
                    {error, not_found};
                _ ->
                    {ok, Result}
            end;
        error ->
            {error, not_found}
    end;

handle_api_request(post, [Application, Param | Rest], HttpRequest, _Args) ->
    ?TRACE("Application: ~p Param: ~p, Rest: ~p", [Application, Param, Rest]),

    case to_existing_atoms(Application, Param) of
        {ok, ApplicationAtom, ParamAtom} ->
            QueryParams = maps:get(query_params, HttpRequest, #{}),
            ?TRACE("QueryParams: ~p", [QueryParams]),

            NewValue = create_value(Rest, QueryParams, #{}),
            ?TRACE("NewValue: ~p", [NewValue]),
            MergedValue = case avm_application:get_env(ApplicationAtom, ParamAtom) of
                undefined ->
                    NewValue;
                {ok, OldValue} ->
                    ?TRACE("merging OldValue: ~p NewValue: ~p", [OldValue, NewValue]),
                    map_utils:deep_maps_merge(OldValue, NewValue)
                end,

            ?TRACE("QueryParams: ~p MergedValue: ~p", [QueryParams, MergedValue]),
            ok = avm_application:set_env(ApplicationAtom, ParamAtom, MergedValue, [{persistent, true}]);
        error ->
            {error, not_found}
    end;

handle_api_request(delete, [Application, Param | Rest], _HttpRequest, _Args) ->
    ?TRACE("Application: ~p Param: ~p, Rest: ~p", [Application, Param, Rest]),

    case to_existing_atoms(Application, Param) of
        {ok, ApplicationAtom, ParamAtom} ->
            Result = case avm_application:get_env(ApplicationAtom, ParamAtom) of
                undefined ->
                    undefined;
                {ok, Env} ->
                    map_utils:remove_entry_in_path(Env, Rest)
                end,
            case Result of
                undefined ->
                    {error, not_found};
                NewEnv ->
                    ?TRACE("NewEnv: ~p", [NewEnv]),
                    avm_application:set_env(ApplicationAtom, ParamAtom, NewEnv),
                    ok
            end;
        error ->
            {error, not_found}
    end;

handle_api_request(Method, Path, _HttpRequest, _Args) ->
    io:format("ERROR!  Unsupported method ~p or path ~p~n", [Method, Path]),
    {error, not_found}.

find_value_in_path(Map, []) ->
    Map;
find_value_in_path(Value, [H | T]) when is_map(Value) ->
    case maps:get(H, Value, undefined) of
        undefined ->
            case to_existing_atom(H) of
                {ok, Atom} -> find_value_in_path(maps:get(Atom, Value, undefined), T);
                error -> undefined
            end;
        V ->
            find_value_in_path(V, T)
    end;
find_value_in_path(_Value, _Path) ->
    undefined.

create_value([], QueryParams, Accum) ->
    maps:merge(Accum, QueryParams);
create_value([H | T], QueryParams, Accum) ->
    #{H => create_value(T, QueryParams, Accum)}.

to_existing_atoms(A, B) ->
    case to_existing_atom(A) of
        {ok, AtomA} ->
            case to_existing_atom(B) of
                {ok, AtomB} -> {ok, AtomA, AtomB};
                error -> error
            end;
        error ->
            error
    end.

to_existing_atom(Bin) ->
    try list_to_existing_atom(binary_to_list(Bin)) of
        Atom -> {ok, Atom}
    catch
        error:badarg -> error
    end.
