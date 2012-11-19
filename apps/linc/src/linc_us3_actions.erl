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
%% @doc Module for handling all actions related tasks.

-module(linc_us3_actions).

-export([apply_set/2,
         apply_list/2]).

-include_lib("pkt/include/pkt.hrl").
-include("linc_us3.hrl").

-type side_effect() :: {output, integer()} | {group, integer()}.

-type action_list_output() :: {NewPkt :: #ofs_pkt{},
                               SideEffects :: [side_effect()]}.

-type action_set_output() :: list({NewPkt :: #ofs_pkt{},
                                   ActionOutput :: side_effect() | drop}).

%%------------------------------------------------------------------------------
%% @doc Applies set of actions to the packet.
-spec apply_set(Pkt :: ofs_pkt(), 
                Actions :: ordsets:ordset(ofp_action())) -> ok.
apply_set(Pkt, [Action | Rest]) ->
    case lists:keymember(ofp_action_group, 1, Pkt#ofs_pkt.actions) of
        true ->
            %% From Open Flow spec 1.2 page 15:
            %% If both an output action and a group action are specified in
            %% an action set, the output action is ignored and the group action
            %% takes precedence.
            {stop, Pkt#ofs_pkt{actions = lists:keydelete(ofp_action_output,
                                                         1,
                                                         Pkt#ofs_pkt.actions)}};
        false ->
            case lists:keymember(ofp_action_output, 1, Pkt#ofs_pkt.actions) of
                true ->
                    {match, output, Pkt};
                false ->
                    {match, drop, Pkt}
            end
    end,
    NewPkt = apply_list(Pkt, [Action]),
    apply_set(NewPkt, Rest);
apply_set(Pkt, []) ->
    Pkt.

%%------------------------------------------------------------------------------
%% @doc Does the routing decisions for the packet according to the action list
-spec apply_list(Pkt :: ofs_pkt(),
                 Actions :: list(ofp_action())) -> [side_effect()].
apply_list(Pkt, [#ofp_action_output{port = Port} | _Rest]) ->
    linc_us3_port:send(Pkt, Port),
    {output, Port, Pkt};
apply_list(Pkt, [#ofp_action_group{group_id = GroupId} | _Rest]) ->
    linc_us3_groups:apply(GroupId, Pkt),
    {group, GroupId, Pkt};
apply_list(Pkt, [#ofp_action_set_queue{queue_id = QueueId} | Rest]) ->
    apply_list(Pkt#ofs_pkt{queue_id = QueueId}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Modifies top tag on MPLS stack to set ttl field to a value
%% Nothing happens if packet had no MPLS header
apply_list(#ofs_pkt{packet = P} = Pkt,
           [#ofp_action_set_mpls_ttl{mpls_ttl = NewTTL} | Rest]) ->
    P2 = linc_us3_packet_edit:find_and_edit(
           P, mpls_tag,
           fun(T) ->
                   [TopTag | StackTail] = T#mpls_tag.stack,
                   NewTag = TopTag#mpls_stack_entry{ ttl = NewTTL },
                   T#mpls_tag{ stack = [NewTag | StackTail] }
           end),
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Modifies top tag on MPLS stack to have TTL reduced by 1.
%% Nothing happens if packet had no MPLS header. Clamps value below 0 to 0.
apply_list(#ofs_pkt{packet = P} = Pkt, [#ofp_action_dec_mpls_ttl{} | Rest]) ->
    P2 = linc_us3_packet_edit:find_and_edit(
           P, mpls_tag,
           fun(T) ->
                   [TopTag | StackTail] = T#mpls_tag.stack,
                   Decremented = erlang:max(0, TopTag#mpls_stack_entry.ttl - 1),
                   NewTag = TopTag#mpls_stack_entry{
                              ttl = Decremented
                             },
                   T#mpls_tag{ stack = [NewTag | StackTail] }
           end),
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Sets IPv4 or IPv6 packet header TTL to a defined value. NOTE: ipv6 has no TTL
%% Nothing happens if packet had no IPv4 header
apply_list(#ofs_pkt{packet = P} = Pkt,
           [#ofp_action_set_nw_ttl{nw_ttl = NewTTL} | Rest]) ->
    P2 = linc_us3_packet_edit:find_and_edit(
           P, ipv4,
           fun(T) ->
                   T#ipv4{ ttl = NewTTL }
           end),
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Decrements IPv4 or IPv6 packet header TTL by 1. NOTE: ipv6 has no TTL
%% Nothing happens if packet had no IPv4 header. Clamps values below 0 to 0.
apply_list(#ofs_pkt{packet = P} = Pkt, [#ofp_action_dec_nw_ttl{} | Rest]) ->
    P2 = linc_us3_packet_edit:find_and_edit(
           P, ipv4,
           fun(T) ->
                   Decremented = erlang:max(0, T#ipv4.ttl - 1),
                   T#ipv4{ ttl = Decremented }
           end),
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Copy the TTL from next-to-outermost to outermost header with TTL.
%% Copy can be IPv4-IPv4, MPLS-MPLS, IPv4-MPLS
apply_list(#ofs_pkt{packet = P} = Pkt, [#ofp_action_copy_ttl_out{} | Rest]) ->
    Tags = filter_copy_fields(P),
    P2 = case Tags of
             [#mpls_tag{stack = S}, #ipv4{ttl = NextOutermostTTL} | _]
               when length(S) == 1 ->
                 linc_us3_packet_edit:find_and_edit(
                   P, mpls_tag,
                   fun(T) ->
                           [Stack1 | StackRest] = T#mpls_tag.stack,
                           Stack1b = Stack1#mpls_stack_entry{
                                       ttl = NextOutermostTTL
                                      },
                           T#mpls_tag{
                             stack = [Stack1b | StackRest]
                            }
                   end);
             [#mpls_tag{stack = S} | _] when length(S) > 1 ->
                 linc_us3_packet_edit:find_and_edit(
                   P, mpls_tag,
                   fun(T) ->
                           [Stack1, Stack2 | StackRest] = T#mpls_tag.stack,
                           Stack1b = Stack1#mpls_stack_entry{
                                       ttl = Stack2#mpls_stack_entry.ttl
                                      },
                           T#mpls_tag{
                             %% reconstruct the stack
                             stack = [Stack1b, Stack2 | StackRest] 
                            }
                   end);
             [#ipv4{}, #ipv4{ttl = NextOutermostTTL}] ->
                 linc_us3_packet_edit:find_and_edit(
                   P, ipv4,
                   fun(T) ->
                           T#ipv4{ ttl = NextOutermostTTL }
                   end)
             end,
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);
    
%%------------------------------------------------------------------------------
%% Optional action
%% Copy the TTL from outermost to next-to-outermost header with TTL
%% Copy can be IPv4-IPv4, MPLS-MPLS, MPLS-IPv4
apply_list(#ofs_pkt{packet = P} = Pkt, [#ofp_action_copy_ttl_in{} | Rest]) ->
    Tags = filter_copy_fields(P),
    P2 = case Tags of
             [#mpls_tag{stack = S} = MPLS, #ipv4{} | _]
               when length(S) == 1 ->
                 linc_us3_packet_edit:find_and_edit(
                   P, ipv4,
                   fun(T) ->
                           T#ipv4{ ttl = mpls_get_outermost_ttl(MPLS) }
                   end);
             [#mpls_tag{stack = S} | _] when length(S) > 1 ->
                 linc_us3_packet_edit:find_and_edit(
                   P, mpls_tag,
                   fun(T) ->
                           [Stack1, Stack2 | StackRest] = T#mpls_tag.stack,
                           Stack2b = Stack2#mpls_stack_entry{
                                       ttl = Stack1#mpls_stack_entry.ttl
                                      },
                           T#mpls_tag{
                             stack = [Stack1, Stack2b | StackRest]
                            }
                   end);
             [#ipv4{ttl = OutermostTTL}, #ipv4{}] ->
                 linc_us3_packet_edit:find_and_edit_skip(
                   P, ipv4,
                   fun(T) ->
                           T#ipv4{ ttl = OutermostTTL }
                   end, 1)
         end,
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Push a new VLAN header onto the packet.
%% Only Ethertype 0x8100 and 0x88A8 should be used (this is not checked)
apply_list(#ofs_pkt{packet = P} = Pkt,
           [#ofp_action_push_vlan{ ethertype = EtherType } | Rest])
  when EtherType =:= 16#8100; EtherType =:= 16#88A8 ->
    %% When pushing, fields are based on existing tag if there is any
    case linc_us3_packet_edit:find(P, ieee802_1q_tag) of
        not_found ->
            InheritVid = 1,
            InheritPrio = 0;
        {_, BasedOnTag} ->
            InheritVid = BasedOnTag#ieee802_1q_tag.vid,
            InheritPrio = BasedOnTag#ieee802_1q_tag.pcp
    end,
    P2 = linc_us3_packet_edit:find_and_edit(
           P, ether,
           fun(T) -> 
                   NewTag = #ieee802_1q_tag{
                     pcp = InheritPrio,
                     vid = InheritVid,
                     ether_type = EtherType
                    },
                   %% found ether element, return it plus VLAN tag for insertion
                   [T, NewTag]
           end),
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% pops the outermost VLAN header from the packet.
%% "The effect of any inconsistent actions on matched packet is undefined"
%% OF1.3 spec PDF page 32. Nothing happens if there is no VLAN tag.
apply_list(#ofs_pkt{packet = P} = Pkt, [#ofp_action_pop_vlan{} | Rest])
  when length(P) > 1 ->
    P2 = linc_us3_packet_edit:find_and_edit(
           P, ieee802_1q_tag,
           %% returning 'delete' atom will work for first VLAN tag only
           fun(_) -> 'delete' end),
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Finds an MPLS tag, and pushes an item in its stack. If there is no MPLS tag,
%% a new one is added.
%% Only ethertype 0x8847 or 0x88A8 should be used (OF1.2 spec, p.16)
apply_list(#ofs_pkt{packet = P} = Pkt,
           [#ofp_action_push_mpls{ ethertype = EtherType } | Rest])
  when EtherType =:= 16#8847;
       EtherType =:= 16#88A8 ->
    %% inherit IP or MPLS ttl value
    FindOldMPLS = linc_us3_packet_edit:find(P, mpls_tag),
    SetTTL = case linc_us3_packet_edit:find(P, ipv4) of
                 not_found ->
                     case FindOldMPLS of
                         not_found ->
                             0;
                         {_, T} ->
                             mpls_get_outermost_ttl(T)
                     end;
                 {_, T} ->
                     T#ipv4.ttl
             end,

    case FindOldMPLS of
        not_found ->
            %% Must insert after ether or vlan tag,
            %% whichever is deeper in the packet
            InsertAfter = case linc_us3_packet_edit:find(P, ieee802_1q_tag) of
                              not_found ->
                                  ether;
                              _ ->
                                  ieee802_1q_tag
                          end,
            P2 = linc_us3_packet_edit:find_and_edit(
                   P, InsertAfter,
                   fun(T) -> 
                           NewEntry = #mpls_stack_entry{ttl = SetTTL},
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
            P2 = linc_us3_packet_edit:find_and_edit(
                   P, mpls_tag,
                   fun(T) -> 
                           %% base the newly inserted entry on a previous one
                           NewEntry = hd(T#mpls_tag.stack),
                           T#mpls_tag{
                             stack = [NewEntry | T#mpls_tag.stack],
                             ether_type = EtherType
                            }
                   end)
    end,
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Pops an outermost MPLS tag or MPLS shim header. Deletes MPLS header if stack
%% inside it is empty. Nothing happens if no MPLS header found.
apply_list(#ofs_pkt{packet = P} = Pkt, [#ofp_action_pop_mpls{} | Rest]) ->
    P2 = linc_us3_packet_edit:find_and_edit(
           P, mpls_tag,
           fun(T) ->
                   Stk = T#mpls_tag.stack,
                   %% based on how many elements were in stack, either pop a
                   %% top most element or delete the whole tag (for empty)
                   case Stk of
                       [OnlyOneElement] ->
                           'delete';
                       [_|RestOfStack] ->
                           T#mpls_tag{ stack = RestOfStack }
                   end
           end),
    apply_list(Pkt#ofs_pkt{packet = P2}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Applies all set-field actions to the packet 
apply_list(#ofs_pkt{packet = Packet} = Pkt,
           [#ofp_action_set_field{field = F} | Rest]) ->
    Packet2 = linc_us3_packet_edit:set_field(F, Packet),
    apply_list(Pkt#ofs_pkt{packet = Packet2}, Rest);

apply_list(Pkt, [#ofp_action_experimenter{} | Rest]) ->
    apply_list(Pkt, Rest);
apply_list(Pkt, []) ->
    Pkt.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

%% @doc Extracts a TTL value from given MPLS tag's stack topmost entry
mpls_get_outermost_ttl(T = #mpls_tag{}) ->
    [H | _] = T#mpls_tag.stack,
    H#mpls_stack_entry.ttl.

filter_copy_fields(List) ->
    lists:filter(fun(T) when is_tuple(T) ->
                         element(1,T) =:= mpls_tag orelse
                             element(1,T) =:= ipv4
                 end, List).
