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
%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc 
-module(linc_ofconfig).

-behaviour(gen_server).
-behaviour(gen_netconf).

%% Internal API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% gen_netconf callbacks
-export([handle_get_config/2,
	 handle_edit_config/2,
	 handle_copy_config/2,
	 handle_delete_config/1,
         handle_lock/1,
         handle_unlock/1,
         handle_get/1]).

-include_lib("of_config/include/of_config.hrl").

-record(state, {}).

%%------------------------------------------------------------------------------
%% Internal API functions
%%------------------------------------------------------------------------------

%% @private
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

%% @private
init([]) ->
    {ok, #state{}}.

%% @private
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% gen_netconf callbacks
%%------------------------------------------------------------------------------

%% @private
handle_get_config(_Source, _Filter) ->
    {ok, "<capable-switch/>"}.

%% @private
handle_edit_config(_Target, _Config) ->
    ok.

%% @private
handle_copy_config(_Source, _Target) ->
    ok.

%% @private
handle_delete_config(_Config) ->
    ok.

%% @private
handle_lock(_Config) ->
    ok.

%% @private
handle_unlock(_Config) ->
    ok.

%% @private
handle_get(_Filter) ->
    {ok, "<capable-switch/>"}.
