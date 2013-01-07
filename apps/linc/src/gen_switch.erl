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
%% @doc OpenFlow Switch behaviour.
-module(gen_switch).

-include_lib("of_protocol/include/of_protocol.hrl").

%% Start the switch.
-callback start(Args :: term()) -> {ok, Version :: integer(), State :: term()}.

%% Stop the switch.
-callback stop(State :: term()) -> any().

%% Handle all message types supported by the given OFP version.
-callback handle_message(ofp_message(), State :: term()) ->
    {noreply, NewState :: term()} |
    {reply, Reply :: ofp_message(), NewState :: term()}.
