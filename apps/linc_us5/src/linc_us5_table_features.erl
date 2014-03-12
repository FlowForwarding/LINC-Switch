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
%% @doc Userspace implementation of the OpenFlow Switch logic.
-module(linc_us5_table_features).

-export([handle_req/3]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").
-include_lib("linc_us5/include/linc_us5.hrl").

-define(REQUIRED_PROPERTIES, [instructions,
                              next_tables,
                              write_actions,
                              apply_actions,
                              match,
                              wildcards,
                              write_setfield,
                              apply_setfield]).

-define(OPTIONAL_PROPERTIES, [instructions_miss,
                              next_tables_miss,
                              write_actions_miss,
                              apply_actions_miss,
                              write_setfield_miss,
                              apply_setfield_miss]).

handle_req(_SwitchId, #ofp_table_features_request{body=[]}, _MonitorData) ->
    %% Read request
    #ofp_table_features_reply{body = get_all_features()};
handle_req(SwitchId, #ofp_table_features_request{body=[_TF|_]=TableFeaturesList},
          MonitorData) ->
    %% SetRequest
    case validate_config(TableFeaturesList) of
        ok ->
            
            %% When a table is "deleted" by not being present in the
            %% list of tables in the request, we should remove all
            %% flow entries.
            linc_us5_monitor:batch_start(SwitchId, removed, MonitorData),
            DeletedTables = lists:seq(0, ?OFPTT_MAX) --
                [TableId || #ofp_table_features{table_id = TableId} <- TableFeaturesList],
            [linc_us5_flow:clear_table_flows(SwitchId, TableId, MonitorData)
             || TableId <- DeletedTables],
            linc_us5_monitor:batch_end(SwitchId),
            %% Currently we have no concept of deleted tables, though,
            %% so we report them all as existing.
            #ofp_table_features_reply{body = get_all_features()};
        {error,Reason} ->
            #ofp_error_msg{type=table_features_failed, code=Reason}
    end.

get_all_features() ->
    [get_table_features(TableId) || TableId <- lists:seq(0, ?OFPTT_MAX)].

get_table_features(TableId) ->
    #ofp_table_features{
       table_id = TableId,
       name = list_to_binary(io_lib:format("Flow Table 0x~2.16.0b", [TableId])),
       metadata_match = ?SUPPORTED_METADATA_MATCH,
       metadata_write = ?SUPPORTED_METADATA_WRITE,
       max_entries = ?MAX_FLOW_TABLE_ENTRIES,
       %% The #ofp_table_feature_prop_*_miss properties do not need to be
       %% included if they are equal to the #ofp_table_feature_prop_* property
       properties = [#ofp_table_feature_prop_instructions{
                        instruction_ids = ?SUPPORTED_INSTRUCTIONS}
                     , #ofp_table_feature_prop_next_tables{
                          next_table_ids = lists:seq(TableId+1,?OFPTT_MAX)}
                     , #ofp_table_feature_prop_write_actions{
                          action_ids = ?SUPPORTED_ACTIONS}
                     , #ofp_table_feature_prop_apply_actions{
                          action_ids = ?SUPPORTED_ACTIONS}
                     , #ofp_table_feature_prop_match{
                          oxm_ids = ?SUPPORTED_MATCH_FIELDS}
                     , #ofp_table_feature_prop_wildcards{
                          oxm_ids = ?SUPPORTED_WILDCARDS}
                     , #ofp_table_feature_prop_write_setfield{
                          oxm_ids = ?SUPPORTED_WRITE_SETFIELDS}
                     , #ofp_table_feature_prop_apply_setfield{
                          oxm_ids = ?SUPPORTED_WRITE_SETFIELDS}
                    ]}.

validate_config(TableFeaturesList) ->
    validate_configs(TableFeaturesList, []).

validate_configs([#ofp_table_features{table_id = TableId,
                                      properties = Properties}|TableFeaturesList],
                 TableIds) when TableId =< ?OFPTT_MAX ->
    case lists:member(TableId,TableIds) of
        true ->
            {error, bad_table};
        false ->
            case validate_feature_properties(TableId, Properties) of
                ok ->
                    validate_configs(TableFeaturesList, [TableId|TableIds]);
                Error ->
                    Error
            end
    end;
validate_configs([#ofp_table_features{table_id = all}|_TableFeaturesList],
                 _TableIds)  ->
    {error, bad_table};
validate_configs([], _TableIds) ->
    ok.

%% There are three classes of features
%% - mandatory, must appear just once
%% - optional, may appear 0 or 1 time
%% - experimenters, it is probably up to the experimenter to define the rules.
%%   Currently we do not support any experimenters features so we do not care.
validate_feature_properties(TableId, Properties) ->
    case validate_feature_properties(TableId, Properties, [], []) of
        {ok, {MandatoryFound, _Optional}} ->
            case all_mandatory_present(MandatoryFound, ?REQUIRED_PROPERTIES) of
                true ->
                    ok;
                false ->
                    {error, bad_argument}
            end;
        Error ->
            Error
    end.

%% In version 1.3.1 of the OpenFlow specification, there is no error code defined
%% for duplicate feature properties, so we use bad_argument instead.
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_instructions{
                                instruction_ids = Instructions
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(instructions, Mandatory) of
        true ->
            {error,bad_argument};
        false ->
            case lists:all(fun (I) -> lists:member(I, ?SUPPORTED_INSTRUCTIONS) end,
                           Instructions)  of
                true->
                    validate_feature_properties(TableId, Properties,
                                                [instructions|Mandatory],
                                                Optional);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_instructions_miss{
                                instruction_ids = Instructions
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(instructions_miss, Optional) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(Instructions, ?SUPPORTED_INSTRUCTIONS) of
                true->
                    validate_feature_properties(TableId, Properties, Mandatory,
                                                [instructions_miss|Optional]);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_next_tables{
                                next_table_ids = TableIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(next_tables, Mandatory) of
        true ->
            {error,bad_argument};
        false ->
            case lists:all(fun (Id) -> Id > TableId end, TableIds) of
                true->
                    validate_feature_properties(TableId, Properties,
                                                [next_tables|Mandatory],
                                                Optional);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_next_tables_miss{
                                next_table_ids = TableIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(next_tables_miss, Optional) of
        true ->
            {error,bad_argument};
        false ->
            case lists:all(fun (Id) -> Id > TableId end, TableIds) of
                true->
                    validate_feature_properties(TableId, Properties, Mandatory, 
                                                [next_tables_miss|Optional]);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_write_actions{
                                action_ids = ActionIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(write_actions, Mandatory) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(ActionIds, ?SUPPORTED_WRITE_ACTIONS) of
                true->
                    validate_feature_properties(TableId, Properties,
                                                [write_actions|Mandatory],
                                                Optional);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_write_actions_miss{
                                action_ids = ActionIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(write_actions_miss, Optional) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(ActionIds, ?SUPPORTED_WRITE_ACTIONS) of
                true->
                    validate_feature_properties(TableId, Properties, Mandatory, 
                                                [write_actions_miss|Optional]);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_apply_actions{
                                action_ids = ActionIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(apply_actions, Mandatory) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(ActionIds, ?SUPPORTED_APPLY_ACTIONS) of
                true->
                    validate_feature_properties(TableId, Properties,
                                                [apply_actions|Mandatory],
                                                Optional);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_apply_actions_miss{
                                action_ids = ActionIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(apply_actions_miss, Optional) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(ActionIds, ?SUPPORTED_APPLY_ACTIONS) of
                true->
                    validate_feature_properties(TableId, Properties, Mandatory,
                                                [apply_actions_miss|Optional]);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_match{
                                oxm_ids = FieldIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(match, Mandatory) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(FieldIds, ?SUPPORTED_MATCH_FIELDS) of
                true->
                    validate_feature_properties(TableId, Properties,
                                                [match|Mandatory], Optional);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_wildcards{
                                oxm_ids = FieldIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(wildcards, Mandatory) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(FieldIds, ?SUPPORTED_WILDCARDS) of
                true->
                    validate_feature_properties(TableId, Properties,
                                                [wildcards|Mandatory], Optional);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_write_setfield{
                                oxm_ids = FieldIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(write_setfield, Mandatory) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(FieldIds, ?SUPPORTED_WRITE_SETFIELDS) of
                true->
                    validate_feature_properties(TableId, Properties,
                                                [write_setfield|Mandatory],
                                                Optional);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_write_setfield_miss{
                                oxm_ids = FieldIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(write_setfield_miss, Optional) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(FieldIds, ?SUPPORTED_WRITE_SETFIELDS) of
                true->
                    validate_feature_properties(TableId, Properties, Mandatory,
                                                [write_setfield_miss|Optional]);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_apply_setfield{
                                oxm_ids = FieldIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(apply_setfield, Mandatory) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(FieldIds, ?SUPPORTED_APPLY_SETFIELDS) of
                true->
                    validate_feature_properties(TableId, Properties,
                                                [apply_setfield|Mandatory],
                                                Optional);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(TableId,
                            [#ofp_table_feature_prop_apply_setfield_miss{
                                oxm_ids = FieldIds
                               } | Properties],
                            Mandatory, Optional) ->
    case lists:member(apply_setfield_miss, Optional) of
        true ->
            {error,bad_argument};
        false ->
            case all_supported(FieldIds, ?SUPPORTED_APPLY_SETFIELDS) of
                true->
                    validate_feature_properties(TableId, Properties, Mandatory,
                                                [apply_setfield_miss|Optional]);
                false ->
                    {error,bad_argument}
            end
    end;
validate_feature_properties(_TableId,
                            [#ofp_table_feature_prop_experimenter{} | _Properties],
                            _Mandatory, _Optional) ->
    %% No experimeters properties are currently supported
    {error,bad_type};
validate_feature_properties(_TableId,
                            [#ofp_table_feature_prop_experimenter_miss{} | _Properties],
                            _Mandatory, _Optional) ->
    %% No experimeters properties are currently supported
    {error,bad_type};
validate_feature_properties(_TableId, [], Mandatory, Optional) ->
    {ok, {Mandatory, Optional}}.


all_supported(Items, SupportedItems) ->
    lists:all(fun (I) -> lists:member(I, SupportedItems) end, Items).

all_mandatory_present(Found, Required) ->
    lists:sort(Found) == lists:sort(Required).
