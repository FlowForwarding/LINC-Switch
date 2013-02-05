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

-export([apply/2]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us3.hrl").

-type instructions_apply_result() :: stop | {goto, integer()}.

-type instructions_apply_output() :: {instructions_apply_result(),
                                      NewPkt :: linc_pkt()}.

-spec apply(Pkt :: linc_pkt(),
            Instructions :: list(ofp_instruction()))
           -> instructions_apply_output().
apply(Pkt, Instructions) ->
    apply2(Pkt, Instructions, stop).

-spec apply2(Pkt :: linc_pkt(),
             Instructions :: list(ofp_instruction()),
             TerminationType :: instructions_apply_result())
            -> instructions_apply_output().
apply2(Pkt,
       [#ofp_instruction_apply_actions{actions = Actions} | InstructionsRest],
       stop) ->
    %% From Open Flow spec 1.2 page 14:
    %% Applies the specific action(s) immediately, without any change to the
    %% Action Set. This instruction may be used to modify the packet between
    %% two tables or to execute multiple actions of the same type.
    %% The actions are specified as an action list (see 5.8).
    {NewPkt, _SideEffects} = linc_us3_actions:apply_list(Pkt, Actions),
    apply2(NewPkt, InstructionsRest, stop);
apply2(Pkt,
       [#ofp_instruction_clear_actions{} | InstructionsRest],
       stop) ->
    %% From Open Flow spec 1.2 page 14:
    %% Clears all the actions in the action set immediately.
    apply2(Pkt#linc_pkt{actions = []}, InstructionsRest, stop);
apply2(#linc_pkt{actions = OldActions} = Pkt,
       [#ofp_instruction_write_actions{actions = Actions} | InstructionsRest],
       stop) ->
    %% From Open Flow spec 1.2 page 14:
    %% Merges the specified action(s) into the current action set (see 5.7).
    %% If an action of the given type exists in the current set, overwrite it,
    %% otherwise add it.
    UActions = lists:ukeysort(2, Actions),
    NewActions = lists:ukeymerge(2, UActions, OldActions),
    apply2(Pkt#linc_pkt{actions = NewActions}, InstructionsRest, stop);
apply2(#linc_pkt{fields = #ofp_match{fields = Fields}} = Pkt,
       [#ofp_instruction_write_metadata{metadata = NewMetadata,
                                        metadata_mask = Mask} | InstructionsRest],
       stop) ->
    %% From Open Flow spec 1.2 page 14:
    %% Writes the masked metadata value into the metadata field. The mask
    %% specifies which bits of the metadata register should be modified
    %% (i.e. new metadata = old metadata &  ̃mask | value & mask).
    Metadata = case lists:keyfind(metadata, #ofp_field.name, Fields) of
                   false ->
                       NewMetadata;
                   #ofp_field{value = OldMetadata} ->
                       apply_mask(OldMetadata, NewMetadata, Mask, [])
               end,
    MetadataField = #ofp_field{name = metadata, value = Metadata},
    Fields2 = lists:keystore(metadata, #ofp_field.name, Fields, MetadataField),
    apply2(Pkt#linc_pkt{fields = #ofp_match{fields = Fields2}},
           InstructionsRest, stop);
apply2(Pkt,
       [#ofp_instruction_goto_table{table_id = Id} | InstructionsRest],
       stop) ->
    %% From Open Flow spec 1.2 page 14:
    %% Indicates the next table in the processing pipeline. The table-id must
    %% be greater than the current table-id. The flows of last table of the
    %% pipeline can not include this instruction (see 5.1).
    apply2(Pkt, InstructionsRest, {goto, Id});
apply2(Pkt, [], stop) ->
    {stop, Pkt};
apply2(Pkt, [], {goto, Id}) ->
    {{goto, Id}, Pkt}.

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
