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
         do_route/2,
         route_to_controller/3,
         route_to_output/3]).

-include("linc_us3.hrl").
-include_lib("pkt/include/pkt.hrl").

%%%
%%% Routing functions ----------------------------------------------------------
%%%

-type route_result() :: match | {table_miss, drop | controller}.

%% @doc Applies flow instructions from the first flow table to a packet.
-spec do_route(#ofs_pkt{}) -> route_result().
do_route(Pkt) ->
    do_route(Pkt, 1).

%% @doc Applies flow instructions from the given table to a packet.
-spec do_route(#ofs_pkt{}, integer()) -> route_result().
do_route(Pkt, TableId) ->
    [FlowTable] = ets:lookup(flow_tables, TableId),
    case match_flow_entries(Pkt, TableId, FlowTable#linc_flow_table.entries) of
        match ->
            match;
        table_miss when FlowTable#linc_flow_table.config == drop ->
            update_flow_table_miss_counters(TableId),
            {table_miss, drop};
        table_miss when FlowTable#linc_flow_table.config == controller ->
            update_flow_table_miss_counters(TableId),
            route_to_controller(TableId, Pkt, no_match),
            {table_miss, controller};
        table_miss when FlowTable#linc_flow_table.config == continue ->
            update_flow_table_miss_counters(TableId),
            %% TODO: Return error when reached last flow table
            do_route(Pkt, TableId + 1)
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
        linc_logic:send(#ofp_message{xid = xid(), body = PacketIn})
    catch
        E1:E2 ->
            ?ERROR("Encapsulate failed when routing to controller "
                   "for pkt: ~p because: ~p:~p",
                   [OFSPkt, E1, E2]),
            io:format("Stacktrace: ~p~n", [erlang:get_stacktrace()])
    end.

-spec route_to_output(integer(), #ofs_pkt{}, integer() | atom()) -> any().
route_to_output(_TableId, Pkt = #ofs_pkt{in_port = InPort}, all) ->
    Ports = ets:tab2list(ofs_ports),
    [linc_us3_port:send(PortNum, Pkt)
     || #ofs_port{number = PortNum} <- Ports, PortNum /= InPort];
route_to_output(TableId, Pkt, controller) ->
    route_to_controller(TableId, Pkt, action);
route_to_output(_TableId, _Pkt, table) ->
    %% FIXME: Only valid in an output action in the
    %%        action list of a packet-out message.
    ok;
route_to_output(_TableId, Pkt = #ofs_pkt{in_port = InPort}, in_port) ->
    linc_us3_port:send(InPort, Pkt);
route_to_output(_TableId, Pkt, PortNum) when is_integer(PortNum) ->
    linc_us3_port:send(PortNum, Pkt#ofs_pkt.queue_id, Pkt);
route_to_output(_TableId, _Pkt, OtherPort) ->
    ?WARNING("unsupported port type: ~p", [OtherPort]).

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

-spec match_flow_entries(#ofs_pkt{}, integer(), list(#flow_entry{}))
                        -> match | table_miss.
match_flow_entries(Pkt, TableId, [FlowEntry | Rest]) ->
    case match_flow_entry(Pkt, TableId, FlowEntry) of
        match ->
            match;
        nomatch ->
            match_flow_entries(Pkt, TableId, Rest)
    end;
match_flow_entries(_Pkt, _TableId, []) ->
    table_miss.

-spec match_flow_entry(#ofs_pkt{}, integer(), #flow_entry{}) -> match | nomatch.
match_flow_entry(Pkt, TableId, FlowEntry) ->
    case fields_match(Pkt#ofs_pkt.fields#ofp_match.fields,
                      FlowEntry#flow_entry.match#ofp_match.fields) of
        false ->
            nomatch;
        true ->
            update_flow_table_match_counters(TableId),
            update_flow_entry_counters(TableId, FlowEntry, Pkt#ofs_pkt.size),
            case linc_us3_instructions:apply(Pkt, FlowEntry#flow_entry.instructions) of
                {stop, NewPkt} ->
                    linc_us3_actions:apply_set(NewPkt),
                    match;
                {{goto, NextTableId}, NewPkt} ->
                    linc_us3_routing:do_route(NewPkt, NextTableId)
            end
    end.

-spec fields_match(list(#ofp_field{}), list(#ofp_field{})) -> boolean().
fields_match(PktFields, FlowFields) ->
    lists:all(fun(FlowField) ->
                      lists:any(fun(PktField) ->
                                        two_fields_match(PktField, FlowField)
                                end, PktFields)
              end, FlowFields).

-spec update_flow_table_match_counters(integer()) -> [integer()].
update_flow_table_match_counters(FlowTableId) ->
    ets:update_counter(flow_table_counters, FlowTableId,
                       [{#flow_table_counter.packet_lookups, 1},
                        {#flow_table_counter.packet_matches, 1}]).

-spec update_flow_table_miss_counters(integer()) -> [integer()].
update_flow_table_miss_counters(FlowTableId) ->
    ets:update_counter(flow_table_counters, FlowTableId,
                       [{#flow_table_counter.packet_lookups, 1}]).

-spec update_flow_entry_counters(integer(), #flow_entry{}, integer())
                                -> [integer()].
update_flow_entry_counters(FlowTableId, FlowEntry, PktSize) ->
    ets:update_counter(flow_entry_counters,
                       {FlowTableId, FlowEntry},
                       [{#flow_entry_counter.received_packets, 1},
                        {#flow_entry_counter.received_bytes, PktSize}]).

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

-spec xid() -> integer().
xid() ->
    %% TODO: think about sequental XIDs
    %% XID is a 32 bit integer
    random:uniform(1 bsl 32) - 1.

mask_match(<<V1,Rest1/binary>>, <<V2,Rest2/binary>>, <<M,Rest3/binary>>) ->
    V1 band M == V2 band M
        andalso
        mask_match(Rest1, Rest2, Rest3);
mask_match(<<>>, <<>>, <<>>) ->
    true.
