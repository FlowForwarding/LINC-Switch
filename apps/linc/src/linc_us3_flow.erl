-module(linc_us3_flow).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-export([get_flow_tables/1,
         get_flow_stats/3,
         add_flow/1,
         apply_flow_mod/4,
         modify_entries/2,
         delete_entries/2,
         create_flow_entry/2,
         fm_strict_match/2,
         fm_non_strict_match/2,
         non_strict_match/2,
         cookie_match/3]).

-include("linc_us3.hrl").

%%% Flow mod functions ---------------------------------------------------------

-spec get_flow_tables(integer() | all) -> [#linc_flow_table{}].
get_flow_tables(all) ->
    ets:tab2list(flow_tables);
get_flow_tables(TableId) when is_integer(TableId) ->
    ets:lookup(flow_tables, TableId).

get_flow_stats(TID, Entries, #ofp_flow_stats_request{out_port = OutPort,
                                                     out_group = OutGroup,
                                                     cookie = Cookie,
                                                     cookie_mask = CookieMask,
                                                     match = Match}) ->
    MatchingEntries = [Entry || Entry <- Entries,
                                non_strict_match(Entry, Match),
                                port_match(Entry, OutPort),
                                group_match(Entry, OutGroup),
                                cookie_match(Entry, Cookie, CookieMask)],
    [#ofp_flow_stats{table_id = TID,
                     duration_sec = DurationUSec div 1000000,
                     duration_nsec = (DurationUSec rem 1000000) * 1000,
                     priority = Entry#flow_entry.priority,
                     idle_timeout = -1, %% FIXME
                     hard_timeout = -1, %% FIXME
                     cookie = Entry#flow_entry.cookie,
                     packet_count = EntryStats#flow_entry_counter.received_packets,
                     byte_count = EntryStats#flow_entry_counter.received_bytes,
                     match = Entry#flow_entry.match,
                     instructions = Entry#flow_entry.instructions}
     || Entry <- MatchingEntries,
        EntryStats <- ets:lookup(flow_entry_counters, {TID, Entry}),
        DurationUSec <- [
                         timer:now_diff(now(), Entry#flow_entry.install_time)
                        ]].

add_flow(#ofp_flow_mod{table_id = TableId,
                       flags = Flags}=FlowMod) ->
    %% For add there can only be one table
    [Table] = ofs_userspace_flow:get_flow_tables(TableId),
    case lists:member(check_overlap,Flags) of
        true ->
            %% Check that there are no overlapping flows.
            case check_overlap(FlowMod, Table) of
                true ->
                    {error, overlap};
                false ->
                    add_flow(TableId, Table, FlowMod),
                    ok
            end;
        false ->
            %% Check if there is any entry with the exact same priority 
            %% and match
            case find_exact_match(FlowMod,Table) of
                #flow_entry{}=Matching ->
                    mod_flow(TableId, Table, FlowMod, Matching, Flags);
                no_match ->
                    add_flow(TableId, Table, FlowMod)
            end,
            ok
    end.

apply_flow_mod(State, FlowMod, ModFun, MatchFun) ->
    ModFun(FlowMod, MatchFun),
    {ok, State}.

modify_entries(#ofp_flow_mod{table_id = TableId} = FlowMod, MatchFun) ->
    lists:foreach(
      fun(#linc_flow_table{entries = Entries} = Table) ->
              NewEntries = [modify_flow_entry(Entry, FlowMod, MatchFun)
                            || Entry <- Entries],
              ets:insert(flow_tables,
                         Table#linc_flow_table{entries = NewEntries})
      end, get_flow_tables(TableId)).

delete_entries(#ofp_flow_mod{table_id = TableId} = FlowMod, MatchFun) ->
    lists:foreach(
      fun(#linc_flow_table{entries = Entries} = Table) ->
              NewEntries = lists:filter(fun(Entry) ->
                                                not MatchFun(Entry, FlowMod)
                                        end, Entries),
              ets:insert(flow_tables,
                         Table#linc_flow_table{entries = NewEntries})
      end, get_flow_tables(TableId)).

-spec create_flow_entry(ofp_flow_mod(), integer()) -> #flow_entry{}.
create_flow_entry(#ofp_flow_mod{priority = Priority,
                                cookie = Cookie,
                                match = Match,
                                instructions = Instructions},
                  FlowTableId) ->
    FlowEntry = #flow_entry{priority = Priority,
                            cookie = Cookie,
                            match = Match,
                            install_time = erlang:now(),
                            %% All record of type ofp_instruction() MUST have
                            %% seq number as a first element.
                            instructions = lists:keysort(2, Instructions)},
    ets:insert(flow_entry_counters,
               #flow_entry_counter{key = {FlowTableId, FlowEntry}}),
    FlowEntry.

%% strict match: use all match fields (including the masks) and the priority
fm_strict_match(#flow_entry{priority = Priority, match = Match} = Entry,
                #ofp_flow_mod{priority = Priority, match = Match} = FlowMod) ->
    cookie_match(Entry, FlowMod#ofp_flow_mod.cookie, FlowMod#ofp_flow_mod.cookie_mask);
fm_strict_match(_FlowEntry, _FlowMod) ->
    false.

%% non-strict match: match more specific fields, ignore the priority
fm_non_strict_match(FlowEntry, #ofp_flow_mod{match = Match,
                                             cookie = Cookie,
                                             cookie_mask = CookieMask}) ->
    cookie_match(FlowEntry, Cookie, CookieMask)
        andalso
        non_strict_match(FlowEntry, Match).

non_strict_match(#flow_entry{match = #ofp_match{fields = EntryFields}},
                 #ofp_match{fields = FlowModFields}) ->
    lists:all(fun(#ofp_field{name = Field} = FlowModField) ->
                      case lists:keyfind(Field, #ofp_field.name, EntryFields) of
                          #ofp_field{} = EntryField ->
                              is_more_specific(EntryField, FlowModField);
                          false ->
                              false
                      end
              end, FlowModFields);
non_strict_match(_FlowEntry, _Match) ->
    throw(#ofp_error_msg{type = bad_match, code = bad_type}).

cookie_match(#flow_entry{cookie = Cookie1}, Cookie2, CookieMask) ->
    mask_match(Cookie1, Cookie2, CookieMask).

find_exact_match(Flow, #linc_flow_table{entries=Entries}) ->
    find_exact_match1(Flow, Entries).

find_exact_match1(#ofp_flow_mod{priority = Priority, match = Match},
                 [#flow_entry{priority = Priority, match = Match}=Entry|_Entries]) ->
    Entry;
find_exact_match1(FlowMod, [_Entry|Entries]) ->
    find_exact_match1(FlowMod, Entries);
find_exact_match1(_FlowMod,[]) ->
    no_match.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

%% Check if FlowMod overlaps with any existing flow with the same Priority.
check_overlap(#ofp_flow_mod{match=#ofp_match{fields=MF}, priority=Priority},
              #linc_flow_table{entries=Fs}) ->
    Flows = [F||#flow_entry{priority=Prio}=F <- Fs, Prio==Priority],
    MF1 = lists:sort(MF),
    lists:any(fun (#flow_entry{match=#ofp_match{fields=MF2}}) ->
                      overlaps(MF1, lists:sort(MF2))
              end, Flows).

overlaps([#ofp_field{class=C,name=F,has_mask=false,value=V1}|_Fields1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V2}|_Fields2])
  when V1=/=V2 ->
    false;
overlaps([#ofp_field{class=C,name=F,has_mask=true,value=V1,mask=MaskBin}|_Fields1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V2}|_Fields2]) ->
    Bits = bit_size(MaskBin),
    <<Val1:Bits>> = V1,
    <<Val2:Bits>> = V2,
    <<Mask:Bits>> = MaskBin,
    Val1 band Mask == Val2 band Mask;
overlaps([#ofp_field{class=C,name=F,has_mask=true,value=V1}|_Fields1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V2,mask=MaskBin}|_Fields2]) ->
    Bits = bit_size(MaskBin),
    <<Val1:Bits>> = V1,
    <<Val2:Bits>> = V2,
    <<Mask:Bits>> = MaskBin,
    Val1 band Mask == Val2 band Mask;
overlaps([#ofp_field{class=C,name=F,has_mask=true,value=V1,mask=M1}|Ms1],
         [#ofp_field{class=C,name=F,has_mask=true,value=V2,mask=M2}|Ms2]) ->
    Bits = bit_size(M1),
    <<Val1:Bits>> = V1,
    <<Val2:Bits>> = V2,
    <<Mask1:Bits>> = M1,
    <<Mask2:Bits>> = M2,
    CommonBits = Mask1 band Mask2,
    %% Is this correct?
    case (Val1 band CommonBits)==(Val2 band CommonBits) of
        false ->
            false;
        true ->
            overlaps(Ms1,Ms2)
    end;
overlaps([#ofp_field{class=C,name=F}|Ms1],
         [#ofp_field{class=C,name=F}|Ms2]) ->
    overlaps(Ms1,Ms2);
overlaps([#ofp_field{class=C,name=F1}|Ms1],
         [#ofp_field{class=C,name=F2}|_]=Ms2) when F1<F2 ->
    overlaps(Ms1,Ms2);
overlaps([#ofp_field{class=C,name=F1}|_]=Ms1,
         [#ofp_field{class=C,name=F2}|Ms2]) when F1>F2 ->
    overlaps(Ms1,Ms2);
overlaps(_,_) ->
    true.

%% Add a new flow entry
add_flow(TableId, #linc_flow_table{entries = Entries}=Table, FlowMod) ->
    NewEntry = create_flow_entry(FlowMod, TableId),
    NewEntries = ordsets:add_element(NewEntry, Entries),
    NewTable = Table#linc_flow_table{entries = NewEntries},
    ets:insert(flow_tables, NewTable).

%% Update existing flow_entry with new instructions
%% Maybe reset counters
mod_flow(TableId, #linc_flow_table{entries = Entries}=Table, FlowMod, Matching, Flags) ->
    ModEntries = ordsets:del_element(Matching,Entries),
    NewEntry = create_flow_entry(FlowMod, TableId),
    NewEntries = ordsets:add_element(NewEntry, ModEntries),
    NewTable = Table#linc_flow_table{entries = NewEntries},
    ets:insert(flow_tables, NewTable),
    case lists:member(reset_counts, Flags) of
        true ->
            %% TODO: Reset counters
            true = ets:insert(flow_entry_counters,
                              #flow_entry_counter{key = {TableId, NewEntry}}),
            true = ets:delete(flow_entry_counters, {TableId,Matching});
        false ->
            %% FIXME: This is not atomic. A better way would be to use only
            %% {TableId,Prio,Match} as key so it is not necessary to modify the
            %% Key when modifying the flow.
            [Counters] = ets:lookup(flow_entry_counters,{TableId,Matching}),
            true = ets:insert(flow_entry_counters,
                              Counters#flow_entry_counter{key = {TableId, NewEntry}}),
            true = ets:delete(flow_entry_counters, Counters#flow_entry_counter.key)
    end.

modify_flow_entry(#flow_entry{} = Entry,
                  #ofp_flow_mod{match = NewMatch,
                                instructions = NewInstructions} = FlowMod,
                  MatchFun) ->
    case MatchFun(Entry, FlowMod) of
        true ->
            %% TODO: update counters
            Entry#flow_entry{match = NewMatch,
                             instructions = NewInstructions};
        false ->
            Entry
    end.

is_more_specific(#ofp_field{class = Cls1}, #ofp_field{class = Cls2}) when
      Cls1 =/= openflow_basic; Cls2 =/= openflow_basic ->
    throw(#ofp_error_msg{type = bad_match, code = bad_field});
is_more_specific(#ofp_field{has_mask = true},
                 #ofp_field{has_mask = false}) ->
    false; %% masked is less specific than non-masked
is_more_specific(#ofp_field{has_mask = false, value = Value},
                 #ofp_field{has_mask = _____, value = Value}) ->
    true; %% value match with no mask is more specific
is_more_specific(#ofp_field{has_mask = true, mask = M1, value = V1},
                 #ofp_field{has_mask = true, mask = M2, value = V2}) ->
    %% M1 is more specific than M2 (has all of it's bits)
    %% and V1*M2 == V2*M2
    is_mask_more_specific(M1, M2)
        andalso
        mask_match(V1, V2, M2);
is_more_specific(_MoreSpecific, _LessSpecific) ->
    false.

-spec is_mask_more_specific(binary(), binary()) -> boolean().
is_mask_more_specific(<<B1,Rest1/binary>>, <<B2,Rest2/binary>>) ->
    B1 bor B2 == B1
        andalso
        is_mask_more_specific(Rest1, Rest2);
is_mask_more_specific(<<>>, <<>>) ->
    true.

port_match(_, _) ->
    true. %% FIXME: implement

group_match(_, _) ->
    true. %% FIXME: implement

mask_match(<<V1,Rest1/binary>>, <<V2,Rest2/binary>>, <<M,Rest3/binary>>) ->
    V1 band M == V2 band M
        andalso
        mask_match(Rest1, Rest2, Rest3);
mask_match(<<>>, <<>>, <<>>) ->
    true.
