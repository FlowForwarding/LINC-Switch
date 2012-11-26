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

-export([do_route/1,
         route_to_controller/3]).

-ifdef(TEST).
-compile([export_all]).
-endif.

-include("linc_us3.hrl").
-include_lib("pkt/include/pkt.hrl").

%%%
%%% Routing functions ----------------------------------------------------------
%%%

-type route_result() :: match | {table_miss, drop | controller}.

%% @doc Applies flow instructions from the first flow table to a packet.
-spec do_route(#ofs_pkt{}) -> route_result().
do_route(Pkt) ->
    do_route(Pkt, 0).

%% @doc Applies flow instructions from the given table to a packet.
-spec do_route(#ofs_pkt{}, integer()) -> route_result().
do_route(Pkt, TableId) ->
    FlowEntries = linc_us3_flow:get_flow_table(TableId),
    case match_flow_entries(Pkt, TableId, FlowEntries) of
        {match, #flow_entry{id = FlowId,
                            instructions = Instructions}} ->
            case linc_us3_instructions:apply(Pkt, Instructions) of
                {stop, NewPkt} ->
                    linc_us3_actions:apply_set(NewPkt),
                    {match, TableId, FlowId};
                {{goto, NextTableId}, NewPkt} ->
                    do_route(NewPkt, NextTableId)
            end;
        table_miss ->
            case linc_us3_flow:get_table_config(TableId) of
                drop ->
                    {table_miss, drop};
                controller ->
                    route_to_controller(TableId, Pkt, no_match),
                    {table_miss, controller};
                continue ->
                    %% TODO: Return error when reached last flow table
                    do_route(Pkt, TableId + 1)
            end
    end.

-spec route_to_controller(integer(), #ofs_pkt{}, atom()) -> ok.
route_to_controller(TableId,
                    #ofs_pkt{fields = Fields,
                             packet = Packet} = OFSPkt,
                    Reason) ->
    try
        PacketIn = #ofp_packet_in{buffer_id = no_buffer,
                                  reason = Reason,
                                  table_id = TableId,
                                  match = Fields,
                                  data = pkt:encapsulate(Packet)},
        linc_logic:send_to_controllers(#ofp_message{body = PacketIn})
    catch
        E1:E2 ->
            ?ERROR("Encapsulate failed when routing to controller "
                   "for pkt: ~p because: ~p:~p",
                   [OFSPkt, E1, E2])
    end.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

-spec match_flow_entries(#ofs_pkt{}, integer(), list(#flow_entry{}))
                        -> {match, #flow_entry{}} | table_miss.
match_flow_entries(Pkt, TableId, [FlowEntry | Rest]) ->
    case match_flow_entry(Pkt, TableId, FlowEntry) of
        nomatch ->
            match_flow_entries(Pkt, TableId, Rest);
        Match ->
            Match
    end;
match_flow_entries(_Pkt, TableId, []) ->
    linc_us3_flow:update_lookup_counter(TableId),
    table_miss.

-spec match_flow_entry(#ofs_pkt{}, integer(), #flow_entry{}) -> match | nomatch.
match_flow_entry(Pkt, TableId, FlowEntry) ->
    case fields_match(Pkt#ofs_pkt.fields#ofp_match.fields,
                      FlowEntry#flow_entry.match#ofp_match.fields) of
        false ->
            nomatch;
        true ->
            linc_us3_flow:update_match_counters(TableId,
                                                FlowEntry#flow_entry.id,
                                                Pkt#ofs_pkt.size),
            {match, FlowEntry}
    end.

-spec fields_match(list(#ofp_field{}), list(#ofp_field{})) -> boolean().
fields_match(PktFields, FlowFields) ->
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
