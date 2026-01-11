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
handle_http_req(#{method := get} = HttpRequest, State) ->
    HandlerConfig = State#state.handler_config,
    App = maps:get(app, HandlerConfig),
    PathSuffix = State#state.path_suffix,
    %% Handle index file for directory requests (empty path or trailing slash)
    ResolvedPath = case PathSuffix of
        [] -> [<<"index.html">>];
        _ -> PathSuffix
    end,
    FullPath = join("/", lists:reverse(ResolvedPath)),
    ?TRACE("App: ~p PathSuffix: ~p FullPath: ~p", [App, ResolvedPath, FullPath]),
    %% Check if client accepts gzip encoding
    AcceptEncoding = get_accept_encoding(HttpRequest),
    AcceptsGzip = accepts_gzip(AcceptEncoding),
    try
        serve_file(App, FullPath, ResolvedPath, AcceptsGzip)
    catch
        _:Reason ->
            io:format("httpd_file_handler: error reading file ~p: ~p~n", [FullPath, Reason]),
            {error, internal_server_error}
    end;
handle_http_req(_HttpRequest, _HandlerConfig) ->
    {error, internal_server_error}.

%% @private
%% Try to serve gzipped version if available and client accepts it
serve_file(App, FullPath, ResolvedPath, true = _AcceptsGzip) ->
    GzPath = FullPath ++ ".gz",
    case atomvm:read_priv(App, GzPath) of
        undefined ->
            %% No gzipped version, serve original
            serve_file(App, FullPath, ResolvedPath, false);
        Data when is_binary(Data) ->
            %% Serve gzipped version with Content-Encoding header
            ContentType = get_content_type(lists:reverse(ResolvedPath)),
            {close, #{"Content-Type" => ContentType, "Content-Encoding" => "gzip"}, Data}
    end;
serve_file(App, FullPath, ResolvedPath, false = _AcceptsGzip) ->
    case atomvm:read_priv(App, FullPath) of
        undefined ->
            io:format("httpd_file_handler: file not found - app=~p path=~p~n", [App, FullPath]),
            {error, not_found};
        Data when is_binary(Data) ->
            {close, #{"Content-Type" => get_content_type(lists:reverse(ResolvedPath))}, Data}
    end.

%% @private
get_accept_encoding(#{headers := Headers}) ->
    %% Try various header name formats
    case maps:get(<<"Accept-Encoding">>, Headers, undefined) of
        undefined ->
            case maps:get(<<"accept-encoding">>, Headers, undefined) of
                undefined -> <<>>;
                Val -> Val
            end;
        Val -> Val
    end;
get_accept_encoding(_) ->
    <<>>.

%% @private
accepts_gzip(AcceptEncoding) when is_binary(AcceptEncoding) ->
    %% Simple check - look for "gzip" in the Accept-Encoding header
    binary:match(AcceptEncoding, <<"gzip">>) =/= nomatch;
accepts_gzip(_) ->
    false.

%% @private
join(Separator, Path) ->
    join(Separator, Path, []).

%% @private
join(_Separator, [], Accum) ->
    Accum;
join(Separator, [H|T], []) ->
    join(Separator, T, binary_to_list(H));
join(Separator, [H|T], Accum) ->
    join(Separator, T, binary_to_list(H) ++ Separator ++ Accum).

%% @private
get_content_type([Filename|_]) ->
    case get_suffix(Filename) of
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

get_suffix(Filename) ->
    case string:split(binary_to_list(Filename), ".") of
        [_Basename, Suffix] ->
            Suffix;
        _ ->
            undefined
    end.
