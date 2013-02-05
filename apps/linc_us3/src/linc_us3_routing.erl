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
%% @doc Main module responsible for routing packets.
-module(linc_us3_routing).

-export([spawn_route/1,
         route/1]).

-ifdef(TEST).
-compile([export_all]).
-endif.

-include_lib("pkt/include/pkt.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include("linc_us3.hrl").

%%%
%%% Routing functions ----------------------------------------------------------
%%%

-type route_result() :: match | {table_miss, drop | controller}.

-spec spawn_route(#linc_pkt{}) -> pid().
spawn_route(Pkt) ->
    proc_lib:spawn_link(?MODULE, route, [Pkt]).

%% @doc Applies flow instructions from the first flow table to a packet.
-spec route(#linc_pkt{}) -> route_result().
route(Pkt) ->
    route(Pkt, 0).

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

%% @doc Applies flow instructions from the given table to a packet.
-spec route(#linc_pkt{}, integer()) -> route_result().
route(#linc_pkt{switch_id = SwitchId} = Pkt, TableId) ->
    FlowEntries = linc_us3_flow:get_flow_table(SwitchId, TableId),
    case match_flow_entries(Pkt, TableId, FlowEntries) of
        {match, #flow_entry{id = FlowId,
                            instructions = Instructions}, Pkt2} ->
            case linc_us3_instructions:apply(Pkt2, Instructions) of
                {stop, Pkt3} ->
                    linc_us3_actions:apply_set(Pkt3),
                    {match, TableId, FlowId};
                {{goto, NextTableId}, Pkt3} ->
                    route(Pkt3, NextTableId)
            end;
        {table_miss, Pkt2} ->
            case linc_us3_flow:get_table_config(SwitchId, TableId) of
                drop ->
                    {table_miss, drop};
                controller ->
                    linc_us3_port:send(Pkt2, controller),
                    {table_miss, controller};
                continue ->
                    %% TODO: Return error when reached last flow table
                    route(Pkt2, TableId + 1)
            end
    end.

-spec match_flow_entries(#linc_pkt{}, integer(), list(#flow_entry{}))
                        -> {match, #flow_entry{}, #linc_pkt{}} |
                           {table_miss, #linc_pkt{}}.
match_flow_entries(Pkt, TableId, [FlowEntry | Rest]) ->
    case match_flow_entry(Pkt, TableId, FlowEntry) of
        nomatch ->
            match_flow_entries(Pkt, TableId, Rest);
        {match, FlowEntry} ->
            {match, FlowEntry, Pkt#linc_pkt{table_id = TableId}}
    end;
match_flow_entries(#linc_pkt{switch_id = SwitchId} = Pkt, TableId, []) ->
    linc_us3_flow:update_lookup_counter(SwitchId, TableId),
    {table_miss, Pkt#linc_pkt{table_id = TableId, packet_in_reason = no_match}}.

-spec match_flow_entry(#linc_pkt{}, integer(), #flow_entry{}) -> match | nomatch.
match_flow_entry(#linc_pkt{switch_id = SwitchId} = Pkt, TableId, FlowEntry) ->
    case fields_match(Pkt#linc_pkt.fields#ofp_match.fields,
                      FlowEntry#flow_entry.match#ofp_match.fields) of
        false ->
            nomatch;
        true ->
            linc_us3_flow:update_match_counters(SwitchId, TableId,
                                                FlowEntry#flow_entry.id,
                                                Pkt#linc_pkt.size),
            {match, FlowEntry}
    end.

-spec fields_match(list(#ofp_field{}), list(#ofp_field{})) -> boolean().
fields_match(PktFields, FlowFields) ->
    %% Returns true if FlowFields is an empty list - expected behaviour as this
    %% means that flow entries with no match fields will match any packet.
    lists:all(fun(FlowField) ->
                      lists:any(fun(PktField) ->
                                        two_fields_match(PktField, FlowField)
                                end, PktFields)
              end, FlowFields).

%% TODO: check for different types and classes
two_fields_match(#ofp_field{name = F1},
                 #ofp_field{name = F2}) when F1 =/= F2 ->
    false;
two_fields_match(#ofp_field{value=Val},
                 #ofp_field{value=Val, has_mask = false}) ->
    true;
two_fields_match(#ofp_field{value=Val1},
                 #ofp_field{value=Val2, has_mask = true, mask = Mask}) ->
    mask_match(Val1, Val2, Mask);
two_fields_match(_, _) ->
    false.

mask_match(<<V1,Rest1/binary>>, <<V2,Rest2/binary>>, <<M,Rest3/binary>>) ->
    V1 band M == V2 band M
        andalso
        mask_match(Rest1, Rest2, Rest3);
mask_match(<<>>, <<>>, <<>>) ->
    true.
