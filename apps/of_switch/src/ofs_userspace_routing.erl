-module(ofs_userspace_routing).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-export([do_route/2,
         apply_action_list/3]).

-include("ofs_userspace.hrl").

%%%
%%% Routing functions ----------------------------------------------------------
%%%

%% @doc Applies flow instructions to a packet
%% @end
-spec do_route(#ofs_pkt{}, integer()) -> route_result().

do_route(Pkt, FlowId) ->
    case apply_flow(Pkt, FlowId) of
        {match, goto, NextFlowId, NewPkt} ->
            do_route(NewPkt, NextFlowId);
        {match, output, NewPkt} ->
            apply_action_set(FlowId, NewPkt#ofs_pkt.actions, NewPkt),
            {match, FlowId, output};
        {match, group, NewPkt} ->
            apply_action_set(FlowId, NewPkt#ofs_pkt.actions, NewPkt),
            {match, FlowId, output};
        {match, drop, _NewPkt} ->
            {match, FlowId, drop};
        {table_miss, controller} ->
            route_to_controller(FlowId, Pkt, no_match),
            {nomatch, FlowId, controller};
        {table_miss, drop} ->
            {nomatch, FlowId, drop};
        {table_miss, continue, NextFlowId} ->
            do_route(Pkt, NextFlowId)
    end.

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% @doc Does the routing decisions for the package according to the action list
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

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Modifies top tag on MPLS stack to set ttl field to a value
%% Nothing happens if packet had no MPLS header
apply_action_list(TableId, [#ofp_action_set_mpls_ttl{} | Rest], Pkt) ->
	NewTTL = Act#ofp_action_set_mpls_ttl.mpls_ttl,
	Pkt2 = ofs_packet_edit:find_and_edit(
			 Pkt, mpls_tag,
			 fun(T) ->
					 [TopTag | StackTail] = T#mpls_tag.stack,
					 NewTag = TopTag#mpls_stack_entry{ ttl = NewTTL },
					 T#mpls_tag{ stack = [NewTag | StackTail] }
			 end),2
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Modifies top tag on MPLS stack to have TTL reduced by 1.
%% Nothing happens if packet had no MPLS header. Clamps value below 0 to 0.
apply_action_list(TableId, [#ofp_action_dec_mpls_ttl{} | Rest], Pkt) ->
	Pkt2 = ofs_packet_edit:find_and_edit(
			 Pkt, mpls_tag,
			 fun(T) ->
					 [TopTag | StackTail] = T#mpls_tag.stack,
					 Decremented = erlang:max(0, TopTag#mpls_stack_entry.ttl - 1),
					 NewTag = TopTag#mpls_stack_entry{
								ttl = Decremented
							   },
					 T#mpls_tag{ stack = [NewTag | StackTail] }
			 end),
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Sets IPv4 or IPv6 packet header TTL to a defined value. NOTE: ipv6 has no TTL
%% Nothing happens if packet had no IPv4 header
apply_action_list(TableId, [#ofp_action_set_nw_ttl{nw_ttl = NewTTL} | Rest], Pkt) ->
	Pkt2 = ofs_packet_edit:find_and_edit(
			 Pkt, ipv4,
			 fun(T) ->
					 T#ipv4{ ttl = NewTTL }
			 end),
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Decrements IPv4 or IPv6 packet header TTL by 1. NOTE: ipv6 has no TTL
%% Nothing happens if packet had no IPv4 header. Clamps values below 0 to 0.
apply_action_list(TableId, [#ofp_action_dec_nw_ttl{} | Rest], Pkt) ->
    %% Optional action
	Pkt2 = ofs_packet_edit:find_and_edit(
			 Pkt, ipv4,
			 fun(T) ->
					 Decremented = erlang:max(0, T#ipv4.ttl - 1),
					 T#ipv4{ ttl = Decremented }
			 end),
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Copy the TTL from next-to-outermost to outermost header with TTL.
%% Copy can be IPv4-IPv4, MPLS-MPLS, IPv4-MPLS
apply_action_list(TableId, [#ofp_action_copy_ttl_out{} | Rest], Pkt) ->
	Tags = lists:filter(Pkt,
						fun(T) when is_tuple(T) ->
								element(1,T) =:= mpls_tag orelse
									element(1,T) =:= ipv4
						end),

	%% this will crash if less than 2 ipv4/mpls tags found
	[Outermost, NextOutermost | _] = Tags,

	%% NOTE: the following code abuses the fact records are tuples
	case {element(1, Outermost), element(1, NextOutermost)} of
		{ipv4, ipv4} ->
			Pkt2 = ofs_packet_edit:find_and_edit(
					 Pkt, ipv4,
					 fun(T) ->
							 T#ipv4{ ttl = NextOutermost#ipv4.ttl }
					 end);
		{mpls_tag, ipv4} ->
			Pkt2 = ofs_packet_edit:find_and_edit(
					 Pkt, mpls_tag,
					 fun(T) ->
							 [Stack1 | StackRest] = T#mpls_tag.stack,
							 Stack1b = Stack1#mpls_stack_entry{
										 ttl = NextOutermost#ipv4.ttl
										},
							 T#mpls_tag{
							   stack = [Stack1b | StackRest]
							  }
					 end);

		%% matches on MPLS tag/whatever and does the copy inside MPLS tag
		{mpls_tag, _} ->
			Pkt2 = ofs_packet_edit:find_and_edit(
					 Pkt, mpls_tag,
					 fun(T) ->
							 [Stack1, Stack2 | StackRest] = T#mpls_tag.stack,
							 Stack1b = Stack1#mpls_stack_entry{
										 ttl = Stack2#mpls_stack_entry.ttl
										},
							 T#mpls_tag{
							   stack = [Stack1b, Stack2 | StackRest] %% reconstruct the stack
							  }
					 end);
		{_, _} ->
			Pkt2 = Pkt
	end,
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Copy the TTL from outermost to next-to-outermost header with TTL
%% Copy can be IPv4-IPv4, MPLS-MPLS, MPLS-IPv4
apply_action_list(TableId, [#ofp_action_copy_ttl_in{} | Rest], Pkt) ->
	Tags = lists:filter(Pkt,
						fun(T) when is_tuple(T) ->
								element(1,T) =:= mpls_tag orelse
									element(1,T) =:= ipv4
						end),

	%% this will crash if less than 2 ipv4/mpls tags found
	[Outermost, NextOutermost | _] = Tags,

	%% NOTE: the following code abuses the fact records are tuples
	case {element(1, Outermost), element(1, NextOutermost)} of
		{ipv4, ipv4} ->
			Pkt2 = ofs_packet_edit:find_and_edit_skip(
					 Pkt, ipv4,
					 fun(T) ->
							 T#ipv4{ ttl = Outermost#ipv4.ttl }
					 end, 1);
		{mpls_tag, ipv4} ->
			Pkt2 = ofs_packet_edit:find_and_edit(
					 Pkt, ipv4,
					 fun(T) ->
							 T#ipv4{ ttl = mpls_get_outermost_ttl(Outermost) }
					 end);
		%% matches on MPLS tag/whatever and does the copy inside MPLS tag
		{mpls_tag, _} ->
			%% Copies TTL from outermost to next-outermost tag inside the same MPLS tag
			%% TODO: can the packet contain two MPLS stacks? Then this code needs change
			Pkt2 = ofs_packet_edit:find_and_edit(
					 Pkt, mpls_tag,
					 fun(T) ->
							 [Stack1, Stack2 | StackRest] = T#mpls_tag.stack,
							 Stack2b = Stack2#mpls_stack_entry{
										 ttl = Stack1#mpls_stack_entry.ttl
										},
							 T#mpls_tag{
							   stack = [Stack1, Stack2b | StackRest] %% reconstruct the stack
							  }
					 end);
		{_, _} ->
			Pkt2 = Pkt
	end,
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Push a new VLAN header onto the packet.
%% Only Ethertype 0x8100 and 0x88A8 should be used (this is not checked)
apply_action_list(TableId, [#ofp_action_push_vlan{ ethertype = EtherType } | Rest], Pkt)
  when EtherType =:= 16#8100; EtherType =:= 16#88A8-> %% might be 'when' is redundant
	%% When pushing, fields are based on existing tag if there is any
	case ofs_packet_edit:find(Pkt, ieee802_1q_tag) of
		not_found ->
			InheritVid = 1,
			InheritPrio = 0;
		{_, BasedOnTag} ->
			InheritVid = BasedOnTag#ieee802_1q_tag.vid,
			InheritPrio = BasedOnTag#ieee802_1q_tag.pcp
	end,
	Pkt2 = ofs_packet_edit:find_and_edit(
			 Pkt, ether,
			 fun(T) -> 
					 NewTag = #ieee802_1q_tag{
								 pcp = InheritPrio,
								 vid = InheritVid,
								 ether_type = EtherType
								},
					 %% found ether element, return it plus VLAN tag for insertion
					 [T, NewTag]
			 end),
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% pops the outermost VLAN header from the packet.
%% "The effect of any inconsistent actions on matched packet is undefined"
%% OF1.3 spec PDF page 32. Nothing happens if there is no VLAN tag.
apply_action_list(TableId, [#ofp_action_pop_vlan{} | Rest], Pkt)
  when length(Pkt) > 1 ->
	Pkt2 = ofs_packet_edit:find_and_edit(
			 Pkt, ieee802_1q_tag,
			 %% returning 'delete' atom will work for first VLAN tag only
			 fun(_) -> 'delete' end),22
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Finds an MPLS tag, and pushes an item in its stack. If there is no MPLS tag,
%% a new one is added.
%% Only ethertype 0x8847 or 0x88A8 should be used (OF1.2 spec, p.16)
apply_action_list(TableId, [#ofp_action_push_mpls{ ethertype = EtherType } | Rest], Pkt)
  when EtherType =:= 16#8847;
	   EtherType =:= 16#88A8 -> %% might be 'when' is redundant
	%% inherit IP or MPLS ttl value
	FindOldMPLS = ofs_packet_edit:find(Pkt, mpls_tag),
	SetTTL = case ofs_packet_edit:find(Pkt, ipv4) of
				 not_found ->
					 case FindOldMPLS of
						 not_found -> 0;
						 {_, T} -> mpls_get_outermost_ttl(T)
					 end;
				 {_, T} ->
					 T#ipv4.ttl
       end,

	case FindOldMPLS of
		not_found ->
			%% Must insert after ether or vlan tag, whichever is deeper in the packet
			InsertAfter = case ofs_packet_edit:find(Pkt, vlan) of
							  not_found -> ether;
							  _ -> vlan
						  end,
			Pkt2 = ofs_packet_edit:find_and_edit(
					 Pkt, InsertAfter,
					 fun(T) -> 
							 NewEntry = #mpls_stack_entry{},
							 NewTag = #mpls_tag{
										 stack = [NewEntry],
										 ether_type = EtherType
										},
							 %% found ether or vlan element, return it plus
							 %% MPLS tag for insertion
							 [T, NewTag]
					 end);
		%% found an MPLS shim header, and will push tag into it
		_ ->
			Pkt2 = ofs_packet_edit:find_and_edit(
					 Pkt, mpls_tag,
					 fun(T) -> 
							 %% base the newly inserted entry on a previous one
							 NewEntry = case T#mpls_tag.stack of
											[] -> #mpls_stack_entry{ttl = SetTTL};
											[H|_] -> H
										end,
							 T#mpls_tag{
							   stack = [NewEntry | T#mpls_tag.stack],
							   ether_type = EtherType
							  }
					 end)
	end,
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Pops an outermost MPLS tag or MPLS shim header. Deletes MPLS header if stack
%% inside it is empty. Nothing happens if no MPLS header found.
apply_action_list(TableId, [#ofp_action_pop_mpls{} | Rest], Pkt) ->
	Pkt2 = ofs_packet_edit:find_and_edit(
			 Pkt, mpls_tag,
			 fun(T) ->
					 Stk = T#mpls_tag.stack,
					 %% based on how many elements were in stack, either pop a
					 %% top most element or delete the whole tag (for empty)
					 case Stk of
						 [] -> 'delete';
						 L when is_list(L), length(L) =:= 1 -> 'delete';
						 [_|Rest] -> T#mpls_tag{ stack = Rest }
					 end
			 end),
	apply_action_list(TableId, Rest, Pkt2);

+%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  	340 	

+%% Optional action

  	341 	

+%% Logically pushes a new PBB service instance header onto the packet (I-TAG TCI)

  	342 	

+%% and copies the original Ethernet addresses of the packet into the customer

  	343 	

+%% addresses (C-DA, C-SA) of the tag. The customer addresses of the I-TAG are in

  	344 	

+%% the location of the original Ethernet addresses of the encapsulated packet,

  	345 	

+%% therefore this operations can be seen as adding both the backbone MAC-in-MAC

  	346 	

+%% header and the I-SID field to the front of the packet. The backbone VLAN

  	347 	

+%% header (B-TAG) is not added via this operaion, it can be added via the Push VLAN

  	348 	

+%% header action. After this operation regular set-field actions can be used to

  	349 	

+%% modify the outer Ethernet addresses B-DA and B-SA

  	350 	

+%% picture at http://www.carrierethernetstudyguide.org/MEF SG/pages/2transport/studyguide_2-1-1-3.html

  	351 	

+apply_action_list(TableId, [#ofp_action_push_pbb{ ethertype = EtherType } | Rest], Pkt) ->

  	352 	

+  %% Cut out the first header to take addrs from it

  	353 	

+  [OriginalEther = #ether{} | _] = Pkt,

  	354 	

+  %% If there was PBB tag, copy isid from it

  	355 	

+  case ofs_packet_edit:find(Pkt, pbb_ether) of

  	356 	

+    not_found ->

  	357 	

+      SetEISID = 1;

  	358 	

+    {_, PreviousPBB} ->

  	359 	

+      SetEISID = PreviousPBB#pbb_ether.encap_i_sid

  	360 	

+  end,

  	361 	

+  %% If there was VLAN tag, copy PCP from it

  	362 	

+  case ofs_packet_edit:find(Pkt, ieee802_1q_tag) of

  	363 	

+    not_found ->

  	364 	

+      SetVLANPCP = 0;

  	365 	

+    {_, PreviousVLAN} ->

  	366 	

+      SetVLANPCP = PreviousVLAN#ieee802_1q_tag.pcp

  	367 	

+  end,

  	368 	

+  %% Create the new header

  	369 	

+  H1 = #pbb_ether{

  	370 	

+      shost = OriginalEther#ether.shost, % copy src from original ether

  	371 	

+      dhost = OriginalEther#ether.dhost, % copy src from original ether

  	372 	

+      b_tag = 0,

  	373 	

+      b_vid = 1,

  	374 	

+      encap_flag_pcp = SetVLANPCP,

  	375 	

+      encap_flag_dei = 0,

  	376 	

+      encap_i_sid = SetEISID

  	377 	

+       },

  	378 	

+  %% prepending a new ethernet header

  	379 	

+  Pkt2 = [H1 | Pkt],

  	380 	

+  apply_action_list(TableId, Rest, Pkt2);

  	381 	

+

  	382 	

+%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

  	383 	

%% Optional action
%% Logically pops up the outermost PBB service header from the packet (I-TAG TCI)
%% and copies the customer addresses (C-DA, C-SA) in the ethernet addresses of
%% the packet. This operation can be seen as removing the backbone MAC-in-MAC
%% header and the I-SID field from the front of the packet. Does not include
%% removing the backbone VLAN headers (B-TAG), it should be removed prior to this
%% operation via the Pop VLAN header action.
apply_action_list(TableId, [#ofp_action_pop_pbb{} | Rest], Pkt) ->
	Pkt2 = case Pkt of
			   [PBBEther = #pbb_ether{}, Ether | Rest] ->
				   Ether2 = Ether#ether{
							  saddr = PBBEther#pbb_ether.saddr,
							  daddr = PBBEther#pbb_ether.daddr
							 },
				   [Ether2 | Rest];
			   _ ->
				   Pkt
		   end,
	apply_action_list(TableId, Rest, Pkt2);

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% Optional action
%% Applies all set-field actions to the packet 
apply_action_list(TableId, [#ofp_action_set_field{ field = F } | Rest], Pkt) ->
	Pkt2 = ofs_packet_edit:set_field(F, Pkt),
	apply_action_list(TableId, Rest, Pkt2);

apply_action_list(TableId, [#ofp_action_experimenter{} | Rest], Pkt) ->
    %% Optional action
    apply_action_list(TableId, Rest, Pkt);
apply_action_list(_TableId, [], Pkt) ->
    Pkt.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

%% @doc Extracts a TTL value from given MPLS tag's stack topmost entry
mpls_get_outermost_ttl(T = #mpls_tag{}) ->
	[H | _] = T#mpls_tag.stack,
	H#mpls_stack_entry.ttl.

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

-type miss() :: tuple(table_miss, drop | controller) |
                tuple(table_miss, continue, integer()).

-spec apply_flow(#ofs_pkt{}, integer()) -> match() | miss().
apply_flow(Pkt, FlowId) ->
    [FlowTable] = ets:lookup(flow_tables, FlowId),
    FlowTableId = FlowTable#linc_flow_table.id,
    case match_flow_entries(Pkt, FlowTableId,
                            FlowTable#linc_flow_table.entries) of
        {match, goto, NextFlowId, NewPkt} ->
            update_flow_table_match_counters(FlowTableId),
            {match, goto, NextFlowId, NewPkt};
        {match, Action, NewPkt} ->
            update_flow_table_match_counters(FlowTableId),
            {match, Action, NewPkt};
        table_miss when FlowTable#linc_flow_table.config == drop ->
            update_flow_table_miss_counters(FlowTableId),
            {table_miss, drop};
        table_miss when FlowTable#linc_flow_table.config == controller ->
            update_flow_table_miss_counters(FlowTableId),
            {table_miss, controller};
        table_miss when FlowTable#linc_flow_table.config == continue ->
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
    case fields_match(Pkt#ofs_pkt.fields#ofp_match.fields,
                      FlowEntry#flow_entry.match#ofp_match.fields) of
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
    %% From Open Flow spec 1.2 page 14:
    %% Applies the specific action(s) immediately, without any change to the
    %% Action Set. This instruction may be used to modify the packet between
    %% two tables or to execute multiple actions of the same type.
    %% The actions are specified as an action list (see 5.8).
    NewPkt = apply_action_list(TableId, Actions, Pkt),
    apply_instructions(TableId, Rest, NewPkt, NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_clear_actions{} | Rest],
                   Pkt,
                   NextStep) ->
    %% From Open Flow spec 1.2 page 14:
    %% Clears all the actions in the action set immediately.
    apply_instructions(TableId, Rest, Pkt#ofs_pkt{actions = []}, NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_write_actions{actions = Actions} | Rest],
                   #ofs_pkt{actions = OldActions} = Pkt,
                   NextStep) ->
    %% From Open Flow spec 1.2 page 14:
    %% Merges the specified action(s) into the current action set (see 5.7).
    %% If an action of the given type exists in the current set, overwrite it,
    %% otherwise add it.
    UActions = lists:ukeysort(2, Actions),
    NewActions = lists:ukeymerge(2, UActions, OldActions),
    apply_instructions(TableId, Rest, Pkt#ofs_pkt{actions = NewActions},
                       NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_write_metadata{metadata = NewMetadata,
                                                    metadata_mask = Mask} | Rest],
                   #ofs_pkt{metadata = OldMetadata} = Pkt,
                   NextStep) ->
    %% From Open Flow spec 1.2 page 14:
    %% Writes the masked metadata value into the metadata field. The mask
    %% specifies which bits of the metadata register should be modified
    %% (i.e. new metadata = old metadata &  ̃mask | value & mask).
    MaskedMetadata = apply_mask(OldMetadata, NewMetadata, Mask, []),
    apply_instructions(TableId, Rest, Pkt#ofs_pkt{metadata = MaskedMetadata},
                       NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_goto_table{table_id = Id} | Rest],
                   Pkt,
                   _NextStep) ->
    %% From Open Flow spec 1.2 page 14:
    %% Indicates the next table in the processing pipeline. The table-id must
    %% be greater than the current table-id. The flows of last table of the
    %% pipeline can not include this instruction (see 5.1).
    apply_instructions(TableId, Rest, Pkt, {goto, Id});
apply_instructions(_TableId, [], Pkt, output_or_group) ->
    case lists:keymember(ofp_action_group, 1, Pkt#ofs_pkt.actions) of
        true ->
            %% From Open Flow spec 1.2 page 15:
            %% If both an output action and a group action are specified in
            %% an action set, the output action is ignored and the group action
            %% takes precedence.
            {match, group, Pkt#ofs_pkt{
                             actions = lists:keydelete(ofp_action_output,
                                                       1,
                                                       Pkt#ofs_pkt.actions)}};
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

-spec apply_mask(binary(), binary(), binary(), list(integer())) -> binary().
apply_mask(<<>>, <<>>, <<>>, Result) ->
    list_to_binary(lists:reverse(Result));
apply_mask(<<OldMetadata:8, OldRest/binary>>,
           <<NewMetadata:8, NewRest/binary>>,
           <<Mask:8, MaskRest/binary>>,
           Result) ->
    Part = (OldMetadata band (bnot Mask)) bor (NewMetadata band Mask),
    apply_mask(OldRest, NewRest, MaskRest, [Part | Result]).

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
                             packet = Packet} = OFSPkt,
                    Reason) ->
    try
        PacketIn = #ofp_packet_in{buffer_id = no_buffer,
                                  reason = Reason,
                                  table_id = TableId,
                                  match = Fields,
                                  data = pkt:encapsulate(Packet)},
        ofs_logic:send(#ofp_message{xid = xid(), body = PacketIn})
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
    ?WARNING("unsupported port type: ~p", [OtherPort]).

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
