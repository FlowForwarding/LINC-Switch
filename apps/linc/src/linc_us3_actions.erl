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
apply_list(Pkt, [#ofp_action_output{port = PortNum} | _Rest]) ->
    %% Required action
    %% linc_us3_port:send(Pkt, Port),
    %% linc_us3_routing:route_to_output(TableId, Pkt, PortNum),
    Pkt;
apply_list(Pkt, [#ofp_action_group{group_id = GroupId} | _Rest]) ->
    %% Required action
    linc_us3_groups:apply(GroupId, Pkt);
apply_list(Pkt, [#ofp_action_set_queue{queue_id = QueueId} | Rest]) ->
    %% Optional action
    apply_list(Pkt#ofs_pkt{queue_id = QueueId}, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Modifies top tag on MPLS stack to set ttl field to a value
%% Nothing happens if packet had no MPLS header
apply_list(Pkt, [Act = #ofp_action_set_mpls_ttl{} | Rest]) ->
    NewTTL = Act#ofp_action_set_mpls_ttl.mpls_ttl,
    Pkt2 = linc_us3_packet_edit:find_and_edit(
             Pkt, mpls_tag,
             fun(T) ->
                     [TopTag | StackTail] = T#mpls_tag.stack,
                     NewTag = TopTag#mpls_stack_entry{ ttl = NewTTL },
                     T#mpls_tag{ stack = [NewTag | StackTail] }
             end),
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Modifies top tag on MPLS stack to have TTL reduced by 1.
%% Nothing happens if packet had no MPLS header. Clamps value below 0 to 0.
apply_list(Pkt, [#ofp_action_dec_mpls_ttl{} | Rest]) ->
    Pkt2 = linc_us3_packet_edit:find_and_edit(
             Pkt, mpls_tag,
             fun(T) ->
                     [TopTag | StackTail] = T#mpls_tag.stack,
                     Decremented = erlang:max(0, TopTag#mpls_stack_entry.ttl - 1),
                     NewTag = TopTag#mpls_stack_entry{
                                ttl = Decremented
                               },
                     T#mpls_tag{ stack = [NewTag | StackTail] }
             end),
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Sets IPv4 or IPv6 packet header TTL to a defined value. NOTE: ipv6 has no TTL
%% Nothing happens if packet had no IPv4 header
apply_list(Pkt, [#ofp_action_set_nw_ttl{nw_ttl = NewTTL} | Rest]) ->
    Pkt2 = linc_us3_packet_edit:find_and_edit(
             Pkt, ipv4,
             fun(T) ->
                     T#ipv4{ ttl = NewTTL }
             end),
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Decrements IPv4 or IPv6 packet header TTL by 1. NOTE: ipv6 has no TTL
%% Nothing happens if packet had no IPv4 header. Clamps values below 0 to 0.
apply_list(Pkt, [#ofp_action_dec_nw_ttl{} | Rest]) ->
    %% Optional action
    Pkt2 = linc_us3_packet_edit:find_and_edit(
             Pkt, ipv4,
             fun(T) ->
                     Decremented = erlang:max(0, T#ipv4.ttl - 1),
                     T#ipv4{ ttl = Decremented }
             end),
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Copy the TTL from next-to-outermost to outermost header with TTL.
%% Copy can be IPv4-IPv4, MPLS-MPLS, IPv4-MPLS
apply_list(Pkt, [#ofp_action_copy_ttl_out{} | Rest]) ->
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
            Pkt2 = linc_us3_packet_edit:find_and_edit(
                     Pkt, ipv4,
                     fun(T) ->
                             T#ipv4{ ttl = NextOutermost#ipv4.ttl }
                     end);
        {mpls_tag, ipv4} ->
            Pkt2 = linc_us3_packet_edit:find_and_edit(
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
            Pkt2 = linc_us3_packet_edit:find_and_edit(
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
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Copy the TTL from outermost to next-to-outermost header with TTL
%% Copy can be IPv4-IPv4, MPLS-MPLS, MPLS-IPv4
apply_list(Pkt, [#ofp_action_copy_ttl_in{} | Rest]) ->
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
            Pkt2 = linc_us3_packet_edit:find_and_edit_skip(
                     Pkt, ipv4,
                     fun(T) ->
                             T#ipv4{ ttl = Outermost#ipv4.ttl }
                     end, 1);
        {mpls_tag, ipv4} ->
            Pkt2 = linc_us3_packet_edit:find_and_edit(
                     Pkt, ipv4,
                     fun(T) ->
                             T#ipv4{ ttl = mpls_get_outermost_ttl(Outermost) }
                     end);
        %% matches on MPLS tag/whatever and does the copy inside MPLS tag
        {mpls_tag, _} ->
            %% Copies TTL from outermost to next-outermost tag inside the same MPLS tag
            %% TODO: can the packet contain two MPLS stacks? Then this code needs change
            Pkt2 = linc_us3_packet_edit:find_and_edit(
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
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Push a new VLAN header onto the packet.
%% Only Ethertype 0x8100 and 0x88A8 should be used (this is not checked)
apply_list(Pkt, [#ofp_action_push_vlan{ ethertype = EtherType } | Rest])
  when EtherType =:= 16#8100; EtherType =:= 16#88A8-> %% might be 'when' is redundant
    %% When pushing, fields are based on existing tag if there is any
    case linc_us3_packet_edit:find(Pkt, ieee802_1q_tag) of
        not_found ->
            InheritVid = 1,
            InheritPrio = 0;
        {_, BasedOnTag} ->
            InheritVid = BasedOnTag#ieee802_1q_tag.vid,
            InheritPrio = BasedOnTag#ieee802_1q_tag.pcp
    end,
    Pkt2 = linc_us3_packet_edit:find_and_edit(
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
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% pops the outermost VLAN header from the packet.
%% "The effect of any inconsistent actions on matched packet is undefined"
%% OF1.3 spec PDF page 32. Nothing happens if there is no VLAN tag.
apply_list(Pkt, [#ofp_action_pop_vlan{} | Rest])
  when length(Pkt) > 1 ->
    Pkt2 = linc_us3_packet_edit:find_and_edit(
             Pkt, ieee802_1q_tag,
             %% returning 'delete' atom will work for first VLAN tag only
             fun(_) -> 'delete' end),
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Finds an MPLS tag, and pushes an item in its stack. If there is no MPLS tag,
%% a new one is added.
%% Only ethertype 0x8847 or 0x88A8 should be used (OF1.2 spec, p.16)
apply_list(Pkt, [#ofp_action_push_mpls{ ethertype = EtherType } | Rest])
  when EtherType =:= 16#8847;
       EtherType =:= 16#88A8 -> %% might be 'when' is redundant
    %% inherit IP or MPLS ttl value
    FindOldMPLS = linc_us3_packet_edit:find(Pkt, mpls_tag),
    SetTTL = case linc_us3_packet_edit:find(Pkt, ipv4) of
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
            InsertAfter = case linc_us3_packet_edit:find(Pkt, vlan) of
                              not_found -> ether;
                              _ -> vlan
                          end,
            Pkt2 = linc_us3_packet_edit:find_and_edit(
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
            Pkt2 = linc_us3_packet_edit:find_and_edit(
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
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Pops an outermost MPLS tag or MPLS shim header. Deletes MPLS header if stack
%% inside it is empty. Nothing happens if no MPLS header found.
apply_list(Pkt, [#ofp_action_pop_mpls{} | Rest]) ->
    Pkt2 = linc_us3_packet_edit:find_and_edit(
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
    apply_list(Pkt2, Rest);

%%------------------------------------------------------------------------------
%% Optional action
%% Applies all set-field actions to the packet 
apply_list(Pkt, [#ofp_action_set_field{ field = F } | Rest]) ->
    Pkt2 = linc_us3_packet_edit:set_field(F, Pkt),
    apply_list(Pkt2, Rest);

apply_list(Pkt, [#ofp_action_experimenter{} | Rest]) ->
    %% Optional action
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
