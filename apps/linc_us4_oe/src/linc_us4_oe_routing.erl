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
-module(linc_us4_oe_routing).

-export([maybe_spawn_route/1,
         spawn_route/1,
         route/1]).

-ifdef(TEST).
-compile([export_all]).
-endif.

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us4_oe.hrl").

%%%
%%% Routing functions ----------------------------------------------------------
%%%

-type route_result() :: {match, integer(), linc_pkt()}
                      | {table_miss, drop | controller}.

-spec maybe_spawn_route(#linc_pkt{}) -> pid() | route_result().
maybe_spawn_route(Pkt) ->
    case application:get_env(linc, sync_routing) of
	{ok, false} ->
	    spawn_route(Pkt);
	_ ->
	    %% Default is not spawning a new process for each pkt
	    try route(Pkt)
	    catch Class:Reason ->
		    ?ERROR("Routing failed for pkt ~p: ~p:~p",
			   [Pkt, Class, Reason])
	    end
    end.


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
    FlowEntries = linc_us4_oe_flow:get_flow_table(SwitchId, TableId),
    case match_flow_entries(Pkt, TableId, FlowEntries) of
        {match, #flow_entry{id = FlowId,
                            cookie = Cookie,
                            instructions = Instructions}} ->
            Pkt2 = Pkt#linc_pkt{table_id = TableId, cookie = Cookie},
            case linc_us4_oe_instructions:apply(Pkt2, Instructions) of
                {stop, Pkt3} ->
                    linc_us4_oe_actions:apply_set(Pkt3),
                    {match, FlowId, Pkt3};
                {{goto, NextTableId}, Pkt3} ->
                    route(Pkt3, NextTableId)
            end;
        {match, table_miss, #flow_entry{id = FlowId,
                                        cookie = Cookie,
                                        instructions = Instructions}} ->
            Pkt2 = Pkt#linc_pkt{packet_in_reason = no_match,
                               cookie = Cookie,
                               table_id = TableId},
            case linc_us4_oe_instructions:apply(Pkt2, Instructions) of
                {stop, Pkt3} ->
                    linc_us4_oe_actions:apply_set(Pkt3),
                    {match, FlowId, Pkt3};
                {{goto, NextTableId}, Pkt3} ->
                    route(Pkt3, NextTableId)
            end;
        %% In OpenFlow Protocol 1.3.1 there is no explicit table config setting,
        %% but OFP 1.3.1 specification on page 12 says:
        %% ---
        %% If the table-miss flow entry does not exist, by default packets
        %% unmatched by flow entries are dropped (discarded). A switch
        %% configuration, for example using the OpenFlow Configuration Protocol,
        %% may override this default and specify another behaviour.
        %% ---
        %% Thus we still support table miss logic where no flow entries are 
        %% present in the flow table.
        table_miss ->
            Pkt2 = Pkt#linc_pkt{packet_in_reason = no_match,
                                switch_id = SwitchId,
                                table_id = TableId},
            case linc_us4_oe_flow:get_table_config(SwitchId, TableId) of
                drop ->
                    {table_miss, drop};
                controller ->
                    linc_us4_oe_port:send(Pkt2, controller),
                    {table_miss, controller};
                continue ->
                    %% TODO: Return error when reached last flow table
                    route(Pkt2, TableId + 1)
            end
    end.

-spec match_flow_entries(#linc_pkt{}, integer(), list(#flow_entry{}))
                        -> {match, #flow_entry{}} |
                           table_miss.
match_flow_entries(Pkt, TableId, [FlowEntry | Rest]) ->
    case match_flow_entry(Pkt, TableId, FlowEntry) of
        nomatch ->
            match_flow_entries(Pkt, TableId, Rest);
        {match, table_miss} ->
            {match, table_miss, FlowEntry};
        match ->
            {match, FlowEntry}
    end;
match_flow_entries(#linc_pkt{switch_id = SwitchId}, TableId, []) ->
    linc_us4_oe_flow:update_lookup_counter(SwitchId, TableId),
    table_miss.

-spec match_flow_entry(#linc_pkt{}, integer(), #flow_entry{}) -> match | nomatch.
match_flow_entry(_Pkt, _TableId, #flow_entry{priority = 0,
                                           match = #ofp_match{fields = []}}) ->
    {match, table_miss};
match_flow_entry(_Pkt, _TableId,
                 #flow_entry{match = #ofp_match{fields = []}}) ->
    match;
match_flow_entry(#linc_pkt{switch_id = SwitchId} = Pkt, TableId, FlowEntry) ->
    case pkt_fields_match_flow_fields(Pkt#linc_pkt.fields#ofp_match.fields,
                      FlowEntry#flow_entry.match#ofp_match.fields) of
        false ->
            nomatch;
        true ->
            linc_us4_oe_flow:update_match_counters(SwitchId, TableId,
                                                FlowEntry#flow_entry.id,
                                                Pkt#linc_pkt.size),
            match
    end.

-spec pkt_fields_match_flow_fields(list(#ofp_field{}), list(#ofp_field{})) ->
                                          boolean().
pkt_fields_match_flow_fields(PktFields, FlowFields) ->
    lists:all(fun(FlowField) ->
                      pkt_fields_match_flow_field(PktFields, FlowField)
              end, FlowFields).

-spec pkt_fields_match_flow_field(list(#ofp_field{}), #ofp_field{}) ->
                                         boolean().
pkt_fields_match_flow_field(PktFields,
                            #ofp_field{name = vlan_vid} = FlowField) ->
    case lists:keyfind(vlan_vid, #ofp_field.name, PktFields) of
        false ->
            vlan_pkt_field_match_flow_field(none, FlowField);
        PktField ->
            vlan_pkt_field_match_flow_field(PktField, FlowField)
    end;
pkt_fields_match_flow_field(_PktFields,
                            #ofp_field{class = infoblox, name = och_sigtype}) ->
    %% For now don't care about matching on och_sigtype
    true;
pkt_fields_match_flow_field(PktFields, FlowField) ->
    lists:any(fun(PktField) ->
                      pkt_field_match_flow_field(PktField, FlowField)
              end, PktFields).

vlan_pkt_field_match_flow_field(PktField, #ofp_field{value = <<?OFPVID_NONE:13>>,
                                                     has_mask = false})  ->
    not is_record(PktField, ofp_field);
vlan_pkt_field_match_flow_field(PktField,
                                #ofp_field{value = <<?OFPVID_PRESENT:13>>,
                                           has_mask = true,
                                           mask = <<?OFPVID_PRESENT:13>>}) ->
    is_record(PktField, ofp_field);
vlan_pkt_field_match_flow_field(PktField,
                                #ofp_field{value = <<_:1, VID:12>>} = FlowField)
  when <<(?OFPVID_PRESENT bor VID):13>> =:= FlowField#ofp_field.value ->
    case PktField of
        #ofp_field{} ->
            pkt_field_match_flow_field(
              PktField,
              strip_vlan_presence_bit_from_flow_field(FlowField));
        _ ->
            false
    end.

pkt_field_match_flow_field(PktField, FlowField) ->
    fields_classes_match(PktField, FlowField) andalso
        fields_values_and_masks_match(PktField, FlowField).

fields_classes_match(#ofp_field{class = Class1}, #ofp_field{class = Class2}) ->
    Class1 =:= Class2.

fields_values_and_masks_match(#ofp_field{name = PktFieldName},
                              #ofp_field{name = FlowFieldName})
  when PktFieldName =/= FlowFieldName ->
    false;
fields_values_and_masks_match(#ofp_field{value= Value},
                              #ofp_field{value= Value, has_mask = false}) ->
    true;
fields_values_and_masks_match(#ofp_field{value = PktFieldValue},
                              #ofp_field{value= FlowFieldValue, has_mask = true,
                                         mask = Mask}) ->
    masked_pkt_value_match_flow_value(PktFieldValue, FlowFieldValue, Mask);
fields_values_and_masks_match(_, _) ->
    false.

masked_pkt_value_match_flow_value(<<>>, <<>>, <<>>) ->
    true;
masked_pkt_value_match_flow_value(PktValue, FlowValue, MaskValue) ->
    ValueSize = bit_size(PktValue),
    <<IntPktValue:ValueSize>> = PktValue,
    <<IntFlowValue:ValueSize>> = FlowValue,
    <<IntMaskValue:ValueSize>> = MaskValue,
    IntPktValue band IntMaskValue == IntFlowValue band IntMaskValue.

%% @doc OFP field of type VLAN_VID has additional bit to indicate special
%% conditions regarding VLAN tag.
strip_vlan_presence_bit_from_flow_field(#ofp_field{value =
                                                       <<_:1, VID:12/bitstring>>,
                                                   has_mask = HasMask,
                                                   mask = Mask} = Field) ->
    NewMask = case HasMask of
                  true ->
                      <<_:1, StrippedMask:12/bitstring>> = Mask,
                      StrippedMask;
                  false ->
                      Mask
              end,
    Field#ofp_field{value = VID, mask = NewMask}.
