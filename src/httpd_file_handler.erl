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
-module(httpd_file_handler).

-export([handler_module/0, init_handler/2, handle_http_req/2]).
-ifdef(TEST).
-export([get_content_type/1]).
-endif.
-behavior(httpd_handler).

% -define(TRACE_ENABLED, true).
-include_lib("atomvm_httpd/include/trace.hrl").

-record(state, {
    path_suffix,
    handler_config
}).

%% @hidden
handler_module() ->
    ?MODULE.

%% @hidden
init_handler(PathSuffix, HandlerConfig) ->
    {ok, #state{path_suffix = PathSuffix, handler_config = HandlerConfig}}.

%% @hidden
handle_http_req(#{method := get} = _HttpRequest, State) ->
    HandlerConfig = State#state.handler_config,
    App = maps:get(app, HandlerConfig),
    PathSuffix = State#state.path_suffix,
    %% Handle index file for directory requests (empty path or trailing slash)
    ResolvedPath = case PathSuffix of
        [] -> [<<"index.html">>];
        _ -> PathSuffix
    end,
    FullPath = join_path(ResolvedPath),
    ?TRACE("App: ~p PathSuffix: ~p FullPath: ~p", [App, ResolvedPath, FullPath]),
    case atomvm:read_priv(App, FullPath) of
        undefined ->
            ?TRACE("file not found - app=~p path=~p", [App, FullPath]),
            {error, not_found};
        Data ->
            %% Reply (not close): httpd keeps HTTP/1.1 connections alive and
            %% honours both Connection: close and HTTP/1.0 itself.
            {reply, #{"Content-Type" => get_content_type(last_segment(ResolvedPath))}, Data, State}
    end;
handle_http_req(_HttpRequest, _HandlerConfig) ->
    {error, internal_server_error}.

%% @private
%% Join path segments in order (no reversal): [<<"js">>, <<"app.js">>] => "js/app.js".
join_path([H | T]) ->
    lists:flatten([binary_to_list(H) | [[$/ | binary_to_list(Segment)] || Segment <- T]]).

%% @private
%% The filename is the final path segment.
last_segment([Segment]) ->
    Segment;
last_segment([_ | T]) ->
    last_segment(T).

%% @private
get_content_type(Filename) when is_binary(Filename) ->
    content_type_for_suffix(get_suffix(Filename));
get_content_type(Filename) when is_list(Filename) ->
    content_type_for_suffix(get_suffix(list_to_binary(Filename))).

%% @private
content_type_for_suffix(Suffix) ->
    case Suffix of
        "html" ->
            "text/html";
        "htm" ->
            "text/html";
        "css" ->
            "text/css";
        "js" ->
            "text/javascript";
        "json" ->
            "application/json";
        "xml" ->
            "application/xml";
        "txt" ->
            "text/plain";
        "png" ->
            "image/png";
        "jpg" ->
            "image/jpeg";
        "jpeg" ->
            "image/jpeg";
        "gif" ->
            "image/gif";
        "svg" ->
            "image/svg+xml";
        "ico" ->
            "image/x-icon";
        "woff" ->
            "font/woff";
        "woff2" ->
            "font/woff2";
        "ttf" ->
            "font/ttf";
        "eot" ->
            "application/vnd.ms-fontobject";
        "pdf" ->
            "application/pdf";
        "wasm" ->
            "application/wasm";
        _ ->
            "application/octet-stream"
    end.

%% @private
%% Take the final dot-separated segment so multi-dot names such as
%% "jquery-3.1.1-min.js" resolve to "js".  `all' (rather than `trailing') is
%% used because AtomVM 0.7's string:split/3 only implements the leading and all
%% directions.
get_suffix(Filename) ->
    case string:split(Filename, <<".">>, all) of
        [_Basename] ->
            undefined;
        Parts ->
            binary_to_list(lists:last(Parts))
    end.
