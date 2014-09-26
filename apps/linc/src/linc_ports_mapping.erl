%%------------------------------------------------------------------------------
%% Copyright 2014 FlowForwarding.org
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
%% @copyright 2014 FlowForwarding.org
%% @doc Module for setting up mapping between capable switch ports
%% and logical switch ports.
-module(linc_ports_mapping).

-export([initialize/1,
        get_logical_switch_port/1,
        get_capable_switch_port/2,
        terminate/0]).

-include("linc_logger.hrl").

-define(PORTS_MAP_ETS, ports_map).

-type logical_port_id() :: {SwitchId :: non_neg_integer(),
                            PortNo :: non_neg_integer()}.


%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

-spec initialize(list({switch, SwitchID :: non_neg_integer(),
                       SwitchOpts :: list()})) -> ok.
initialize(LogicalSwitches) ->
    try
        ets:new(?PORTS_MAP_ETS, [named_table, public,
                                 {read_concurrency, true}]),
        create_mapping_between_capable_and_logical_ports(LogicalSwitches)
    catch
        throw:Reason ->
            terminate(),
            throw({bad_port_config, Reason})
    end.

-spec get_logical_switch_port(non_neg_integer()) -> Result when
      Result :: logical_port_id() | not_found.
get_logical_switch_port(CapablePortNo) ->
    case ets:lookup(?PORTS_MAP_ETS, CapablePortNo) of
        [{CapablePortNo, SwIdLogicalNo}] ->
            SwIdLogicalNo;
        [] ->
            not_found
    end.

-spec get_capable_switch_port(non_neg_integer(), non_neg_integer())
                             -> Result when
      Result :: non_neg_integer().
get_capable_switch_port(SwitchId, LogicalPortNo) ->
    case ets:match(?PORTS_MAP_ETS, {'$1', {SwitchId, LogicalPortNo}}) of
        [[CapablePortNo]] ->
            CapablePortNo;
        [] ->
            not_found
    end.

-spec terminate() -> true.
terminate() ->
    true = ets:delete(?PORTS_MAP_ETS).

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

create_mapping_between_capable_and_logical_ports(LogicalSwitches) ->
    [begin
         SwPorts = proplists:get_value(ports, SwOpts),
         create_mapping_between_capable_and_logical_ports(SwId, SwPorts)
     end || {switch, SwId, SwOpts} <- LogicalSwitches],
    ok.

create_mapping_between_capable_and_logical_ports(SwId, SwPorts) ->
    [begin
         LogicalNo = logical_port_no(CapableNo, PortOpts),
         assert_logical_port_no_unique_in_logical_switch(SwId, LogicalNo),
         assert_capable_port_no_uniqie_in_capable_switch(CapableNo),
         ets:insert_new(?PORTS_MAP_ETS, {CapableNo, {SwId, LogicalNo}})
     end || {port, CapableNo, PortOpts} <- SwPorts].

logical_port_no(CapableNo, PortOpts) when is_list(PortOpts) ->
    proplists:get_value(port_no, PortOpts, CapableNo);
logical_port_no(CapableNo, _OldFormatOpts = {queues, _}) ->
    CapableNo.

assert_logical_port_no_unique_in_logical_switch(SwId, LogicalNo) ->
    case ets:match(?PORTS_MAP_ETS, {'_', {SwId, LogicalNo}}) of
        [] ->
            ok;
        _ ->
            ?ERROR("Logical port ~p duplicated in logical switch ~p~n",
                    [LogicalNo, SwId]),
            throw(duplicated_logical_port_no)
    end.

assert_capable_port_no_uniqie_in_capable_switch(CapableNo) ->
    case ets:lookup(?PORTS_MAP_ETS, CapableNo) of
        [] ->
            ok;
        _ ->
            ?ERROR("Capable port ~p duplicated~n", [CapableNo]),
            throw(duplicated_capable_port_no)
    end.
