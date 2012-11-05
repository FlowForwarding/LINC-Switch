%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
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
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc Callback module for OpenFlow Logical Switch application.
-module(linc).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%------------------------------------------------------------------------------
%% Application callbacks
%%------------------------------------------------------------------------------

%% @doc Start the application.
-spec start(any(), any()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    case application:get_env(linc, of_config) of
        {ok, enabled} ->
            ok = application:start(ssh),
            ok = application:start(enetconf);
        _ ->
            ok
    end,
    linc_sup:start_link().

%% @doc Stop the application
-spec stop(any()) -> ok.
stop(_State) ->
    case application:get_env(linc, of_config) of
        {ok, enabled} ->
            ok = application:stop(enetconf),
            ok = application:stop(ssh);
        _ ->
            ok
    end.
