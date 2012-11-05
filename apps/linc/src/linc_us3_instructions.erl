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
%% @doc Module for handling all instructions related tasks.

-module(linc_us3_instructions).

-export([apply/4]).

-include("linc_us3.hrl").

-spec apply(integer(),
            list(ofp_instruction()),
            #ofs_pkt{},
            output_or_group | {goto, integer()}) -> match().
apply(TableId,
      [#ofp_instruction_apply_actions{actions = Actions} | Rest],
      Pkt,
      NextStep) ->
    %% From Open Flow spec 1.2 page 14:
    %% Applies the specific action(s) immediately, without any change to the
    %% Action Set. This instruction may be used to modify the packet between
    %% two tables or to execute multiple actions of the same type.
    %% The actions are specified as an action list (see 5.8).
    NewPkt = linc_us3_actions:apply(TableId, Actions, Pkt),
    linc_us3_instructions:apply(TableId, Rest, NewPkt, NextStep);
apply(TableId,
      [#ofp_instruction_clear_actions{} | Rest],
      Pkt,
      NextStep) ->
    %% From Open Flow spec 1.2 page 14:
    %% Clears all the actions in the action set immediately.
    linc_us3_instructions:apply(TableId, Rest, Pkt#ofs_pkt{actions = []}, NextStep);
apply(TableId,
      [#ofp_instruction_write_actions{actions = Actions} | Rest],
      #ofs_pkt{actions = OldActions} = Pkt,
      NextStep) ->
    %% From Open Flow spec 1.2 page 14:
    %% Merges the specified action(s) into the current action set (see 5.7).
    %% If an action of the given type exists in the current set, overwrite it,
    %% otherwise add it.
    UActions = lists:ukeysort(2, Actions),
    NewActions = lists:ukeymerge(2, UActions, OldActions),
    linc_us3_instructions:apply(TableId, Rest, Pkt#ofs_pkt{actions = NewActions},
                                NextStep);
apply(TableId,
      [#ofp_instruction_write_metadata{metadata = NewMetadata,
                                       metadata_mask = Mask} | Rest],
      #ofs_pkt{metadata = OldMetadata} = Pkt,
      NextStep) ->
    %% From Open Flow spec 1.2 page 14:
    %% Writes the masked metadata value into the metadata field. The mask
    %% specifies which bits of the metadata register should be modified
    %% (i.e. new metadata = old metadata &  ̃mask | value & mask).
    MaskedMetadata = apply_mask(OldMetadata, NewMetadata, Mask, []),
    linc_us3_instructions:apply(TableId, Rest, Pkt#ofs_pkt{metadata = MaskedMetadata},
          NextStep);
apply(TableId,
      [#ofp_instruction_goto_table{table_id = Id} | Rest],
      Pkt,
      _NextStep) ->
    %% From Open Flow spec 1.2 page 14:
    %% Indicates the next table in the processing pipeline. The table-id must
    %% be greater than the current table-id. The flows of last table of the
    %% pipeline can not include this instruction (see 5.1).
    linc_us3_instructions:apply(TableId, Rest, Pkt, {goto, Id});
apply(_TableId, [], Pkt, output_or_group) ->
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
apply(_TableId, [], Pkt, {goto, Id}) ->
    {match, goto, Id, Pkt}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

-spec apply_mask(binary(), binary(), binary(), list(integer())) -> binary().
apply_mask(<<>>, <<>>, <<>>, Result) ->
    list_to_binary(lists:reverse(Result));
apply_mask(<<OldMetadata:8, OldRest/binary>>,
           <<NewMetadata:8, NewRest/binary>>,
           <<Mask:8, MaskRest/binary>>,
           Result) ->
    Part = (OldMetadata band (bnot Mask)) bor (NewMetadata band Mask),
    apply_mask(OldRest, NewRest, MaskRest, [Part | Result]).
