-module(ofs_userspace_routing).

-export([do_route/2,
         apply_action_list/3]).

-include("ofs_userspace.hrl").

%%% Routing functions ----------------------------------------------------------

-spec do_route(#ofs_pkt{}, integer()) -> route_result().
do_route(Pkt, FlowId) ->
    case apply_flow(Pkt, FlowId) of
        {match, goto, NextFlowId, NewPkt} ->
            do_route(NewPkt, NextFlowId);
        {match, output, NewPkt} ->
            apply_action_set(FlowId, NewPkt#ofs_pkt.actions, NewPkt),
            output;
        {match, group, NewPkt} ->
            apply_action_set(FlowId, NewPkt#ofs_pkt.actions, NewPkt),
            output;
        {match, drop, _NewPkt} ->
            drop;
        {table_miss, controller} ->
            route_to_controller(FlowId, Pkt, no_match),
            controller;
        {table_miss, drop} ->
            drop;
        {table_miss, continue, NextFlowId} ->
            do_route(Pkt, NextFlowId)
    end.

-spec apply_action_list(integer(),
                        list(ofp_action()),
                        #ofs_pkt{}) -> #ofs_pkt{}.
apply_action_list(TableId, [#ofp_action_output{port = PortNum} | _Rest], Pkt) ->
    %% Required action
    route_to_output(TableId, Pkt, PortNum),
    Pkt;
apply_action_list(_TableId, [#ofp_action_group{group_id = GroupId} | _Rest],
                  Pkt) ->
    %% Required action
    apply_group(GroupId, Pkt);
apply_action_list(TableId,
                  [#ofp_action_set_queue{queue_id = QueueId} | Rest],
                  Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt#ofs_pkt{queue_id = QueueId});
apply_action_list(TableId, [#ofp_action_set_mpls_ttl{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_dec_mpls_ttl{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_set_nw_ttl{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_dec_nw_ttl{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_copy_ttl_out{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_copy_ttl_in{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_push_vlan{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_pop_vlan{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_push_mpls{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_pop_mpls{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_set_field{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(TableId, [#ofp_action_experimenter{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(_TableId, [], Pkt) ->
    Pkt.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

-type miss() :: tuple(table_miss, drop | controller) |
                tuple(table_miss, continue, integer()).

-spec apply_flow(#ofs_pkt{}, #flow_entry{}) -> match() | miss().
apply_flow(Pkt, FlowId) ->
    [FlowTable] = ets:lookup(flow_tables, FlowId),
    FlowTableId = FlowTable#flow_table.id,
    case match_flow_entries(Pkt, FlowTableId, FlowTable#flow_table.entries) of
        {match, goto, NextFlowId, NewPkt} ->
            update_flow_table_match_counters(FlowTableId),
            {match, goto, NextFlowId, NewPkt};
        {match, Action, NewPkt} ->
            update_flow_table_match_counters(FlowTableId),
            {match, Action, NewPkt};
        table_miss when FlowTable#flow_table.config == drop ->
            update_flow_table_miss_counters(FlowTableId),
            {table_miss, drop};
        table_miss when FlowTable#flow_table.config == controller ->
            update_flow_table_miss_counters(FlowTableId),
            {table_miss, controller};
        table_miss when FlowTable#flow_table.config == continue ->
            update_flow_table_miss_counters(FlowTableId),
            {table_miss, continue, FlowId + 1}
    end.

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

-spec match_flow_entries(#ofs_pkt{}, integer(), list(#flow_entry{}))
                        -> match() | table_miss.
match_flow_entries(Pkt, FlowTableId, [FlowEntry | Rest]) ->
    case match_flow_entry(Pkt, FlowTableId, FlowEntry) of
        {match, goto, NextFlowId, NewPkt} ->
            update_flow_entry_counters(FlowTableId,
                                       FlowEntry,
                                       Pkt#ofs_pkt.size),
            {match, goto, NextFlowId, NewPkt};
        {match, Action, NewPkt} ->
            update_flow_entry_counters(FlowTableId,
                                       FlowEntry,
                                       Pkt#ofs_pkt.size),
            {match, Action, NewPkt};
        nomatch ->
            match_flow_entries(Pkt, FlowTableId, Rest)
    end;
match_flow_entries(_Pkt, _FlowTableId, []) ->
    table_miss.

-spec match_flow_entry(#ofs_pkt{}, integer(), #flow_entry{})
                      -> match() | nomatch.
match_flow_entry(Pkt, FlowTableId, FlowEntry) ->
    case fields_match(Pkt#ofs_pkt.fields#ofp_match.oxm_fields,
                      FlowEntry#flow_entry.match#ofp_match.oxm_fields) of
        true ->
            apply_instructions(FlowTableId,
                               FlowEntry#flow_entry.instructions,
                               Pkt,
                               output_or_group);
        false ->
            nomatch
    end.

-spec fields_match(list(#ofp_field{}), list(#ofp_field{})) -> boolean().
fields_match(PktFields, FlowFields) ->
    lists:all(fun(#ofp_field{field = F1} = PktField) ->
                      %% TODO: check for class other than openflow_basic
                      lists:all(fun(#ofp_field{field = F2} = FlowField) ->
                                        F1 =/= F2 %% field is not relevant here
                                            orelse
                                            two_fields_match(PktField, FlowField)
                                end, FlowFields)
              end, PktFields).


two_fields_match(#ofp_field{value=Val},
                 #ofp_field{value=Val, has_mask = false}) ->
    true;
two_fields_match(#ofp_field{value=Val1},
                 #ofp_field{value=Val2, has_mask = true, mask = Mask}) ->
    mask_match(Val1, Val2, Mask);
two_fields_match(_, _) ->
    false.

-type match() :: tuple(match, output | group | drop, #ofs_pkt{}) |
                 tuple(match, goto, integer(), #ofs_pkt{}).

-spec apply_instructions(integer(),
                         list(ofp_instruction()),
                         #ofs_pkt{},
                         output_or_group | {goto, integer()}) -> match().
apply_instructions(TableId,
                   [#ofp_instruction_apply_actions{actions = Actions} | Rest],
                   Pkt,
                   NextStep) ->
    NewPkt = apply_action_list(TableId, Actions, Pkt),
    apply_instructions(TableId, Rest, NewPkt, NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_clear_actions{} | Rest],
                   Pkt,
                   NextStep) ->
    apply_instructions(TableId, Rest, Pkt#ofs_pkt{actions = []}, NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_write_actions{actions = Actions} | Rest],
                   #ofs_pkt{actions = OldActions} = Pkt,
                   NextStep) ->
    UActions = lists:ukeysort(2, Actions),
    NewActions = lists:ukeymerge(2, UActions, OldActions),
    apply_instructions(TableId, Rest, Pkt#ofs_pkt{actions = NewActions},
                       NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_write_metadata{metadata = Metadata,
                                                    metadata_mask = Mask} | Rest],
                   Pkt,
                   NextStep) ->
    MaskedMetadata = apply_mask(Metadata, Mask),
    apply_instructions(TableId, Rest, Pkt#ofs_pkt{metadata = MaskedMetadata},
                       NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_goto_table{table_id = Id} | Rest],
                   Pkt,
                   _NextStep) ->
    apply_instructions(TableId, Rest, Pkt, {goto, Id});
apply_instructions(_TableId, [], Pkt, output_or_group) ->
    case lists:keymember(ofp_action_group, 1, Pkt#ofs_pkt.actions) of
        true ->
            {match, group, Pkt};
        false ->
            case lists:keymember(ofp_action_output, 1, Pkt#ofs_pkt.actions) of
                true ->
                    {match, output, Pkt};
                false ->
                    {match, drop, Pkt}
            end
    end;
apply_instructions(_TableId, [], Pkt, {goto, Id}) ->
    {match, goto, Id, Pkt}.

-spec apply_mask(binary(), binary()) -> binary().
apply_mask(Metadata, _Mask) ->
    Metadata.

-spec apply_group(ofp_group_id(), #ofs_pkt{}) -> #ofs_pkt{}.
apply_group(GroupId, Pkt) ->
    case ets:lookup(group_table, GroupId) of
        [] ->
            Pkt;
        [Group] ->
            apply_group_type(Group#group.type, Group#group.buckets, Pkt)
    end.

-spec apply_group_type(ofp_group_type(), [#ofs_bucket{}], #ofs_pkt{}) ->
                              #ofs_pkt{}.
apply_group_type(all, Buckets, Pkt) ->
    lists:map(fun(Bucket) ->
                      apply_bucket(Bucket, Pkt)
              end, Buckets);
apply_group_type(select, [Bucket | _Rest], Pkt) ->
    apply_bucket(Bucket, Pkt);
apply_group_type(indirect, [Bucket], Pkt) ->
    apply_bucket(Bucket, Pkt);
apply_group_type(ff, Buckets, Pkt) ->
    case pick_live_bucket(Buckets) of
        false ->
            drop;
        Bucket ->
            apply_bucket(Bucket, Pkt)
    end.

-spec apply_bucket(#ofs_bucket{}, #ofs_pkt{}) -> #ofs_pkt{}.
apply_bucket(#ofs_bucket{value = #ofp_bucket{actions = Actions}}, Pkt) ->
    apply_action_list(0, Actions, Pkt).

-spec pick_live_bucket([#ofs_bucket{}]) -> #ofs_bucket{} | false.
pick_live_bucket(Buckets) ->
    %% TODO Implement bucket liveness logic
    case Buckets of
        [] ->
            false;
        _ ->
            hd(Buckets)
    end.

-spec apply_action_set(integer(),
                       ordsets:ordset(ofp_action()),
                       #ofs_pkt{}) -> #ofs_pkt{}.
apply_action_set(TableId, [Action | Rest], Pkt) ->
    NewPkt = apply_action_list(TableId, [Action], Pkt),
    apply_action_set(TableId, Rest, NewPkt);
apply_action_set(_TableId, [], Pkt) ->
    Pkt.

-spec route_to_controller(integer(), #ofs_pkt{}, atom()) -> ok.
route_to_controller(TableId,
                    #ofs_pkt{fields = Fields,
                             packet = Packet},
                    Reason) ->
    PacketIn = #ofp_packet_in{buffer_id = no_buffer,
                              reason = Reason,
                              table_id = TableId,
                              match = Fields,
                              data = pkt:encapsulate(Packet)},
    ofs_logic:send(#ofp_message{xid = xid(), body = PacketIn}).

-spec route_to_output(integer(), #ofs_pkt{}, integer() | atom()) -> any().
route_to_output(_TableId, Pkt = #ofs_pkt{in_port = InPort}, all) ->
    Ports = ets:tab2list(ofs_ports),
    [ofs_userspace_port:send(PortNum, Pkt)
     || #ofs_port{number = PortNum} <- Ports, PortNum /= InPort];
route_to_output(TableId, Pkt, controller) ->
    route_to_controller(TableId, Pkt, action);
route_to_output(_TableId, _Pkt, table) ->
    %% FIXME: Only valid in an output action in the
    %%        action list of a packet-out message.
    ok;
route_to_output(_TableId, Pkt = #ofs_pkt{in_port = InPort}, in_port) ->
    ofs_userspace_port:send(InPort, Pkt);
route_to_output(_TableId, Pkt, PortNum) when is_integer(PortNum) ->
    ofs_userspace_port:send(PortNum, Pkt#ofs_pkt.queue_id, Pkt);
route_to_output(_TableId, _Pkt, OtherPort) ->
    lager:warning("unsupported port type: ~p", [OtherPort]).

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
