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
%% @doc Module for handling all group related tasks.
-module(linc_us4_oe_groups).

%% API
-export([initialize/1,
         terminate/1,
         modify/2,
         apply/2,
         get_stats/2,
         get_desc/2,
         get_features/1,
         update_reference_count/3,
         is_valid/2]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("linc_us4_oe.hrl").

-type linc_bucket_id() :: {integer(), binary()}.

%% @doc Bucket wrapper adding unique_id field to the original OFP bucket
-record(linc_bucket, {
          bucket    :: ofp_bucket(),
          unique_id :: linc_bucket_id()
         }).

%% @doc Group object
-record(linc_group, {
          id               :: ofp_group_id(),
          type    = all    :: ofp_group_type(),
          total_weight = 0 :: integer(),
          buckets = []     :: [#linc_bucket{}],
          refers_to_groups = [] :: ordsets:ordset(integer())
         }).

-type linc_stats_key_type() :: {group, integer(), atom()}
                             | {bucket, {integer(), binary()}, atom()}
                             | {group_start_time, integer()}.

%% @doc Stats item record for storing stats in ETS
-record(linc_group_stats, {
          key   :: linc_stats_key_type(),
          value :: integer()
         }).

%%%==============================================================
%%% API implementation
%%%==============================================================

%% @doc Module startup
initialize(SwitchId) ->
    GroupTable = ets:new(group_table, [public,
                                       {keypos, #linc_group.id},
                                       {read_concurrency, true},
                                       {write_concurrency, true}]),
    linc:register(SwitchId, group_table, GroupTable),
    %% Stats are stored in form of #linc_group_stats{key, value}, key is a tuple
    %% {group, GroupId, packet_count}
    %% {group, GroupId, byte_count}
    %% {bucket, GroupId, BucketId, packet_count}
    %% {bucket, GroupId, BucketId, byte_count}
    %% and value is 32 or 64 bit unsigned counter, which wraps when reaching max
    %% value for 32 or 64 bit.
    GroupStats = ets:new(group_stats, [public,
                                       {keypos, #linc_group_stats.key},
                                       {read_concurrency, true},
                                       {write_concurrency, true}]),
    linc:register(SwitchId, group_stats, GroupStats),

    %% Time for groups is stored in the same way as stats, but holds unix
    %% microtime instead of counter
    ok.

%%--------------------------------------------------------------------
%% @doc Module shutdown
terminate(SwitchId) ->
    ets:delete(linc:lookup(SwitchId, group_table)),
    ets:delete(linc:lookup(SwitchId, group_stats)),
    ok.

%%--------------------------------------------------------------------
%% @doc Modifies group reference count by Increment
%% NOTE: will not wrap to 0xFFFFFFFF if accidentaly went below zero, the
%% counter will remain negative, but will wrap if overflows 32bit
update_reference_count(SwitchId, GroupId, Increment) ->
    group_update_stats(SwitchId, GroupId, reference_count, Increment).

%%--------------------------------------------------------------------
%% @doc Applies group GroupId to packet Pkt, result should be list of
%% packets and ports where they are destined or 'drop' atom. Packet is
%% cloned if multiple ports are the destination.
-spec apply(GroupId :: integer(), Pkt :: #linc_pkt{}) -> ok.
apply(GroupId, #linc_pkt{switch_id = SwitchId} = Pkt) ->
    case group_get(SwitchId, GroupId) of
        not_found -> ok;
        Group     ->
            %% update group stats
            group_update_stats(SwitchId, GroupId, packet_count, 1),
            group_update_stats(SwitchId, GroupId, byte_count, Pkt#linc_pkt.size),

            apply_group_type_to_packet(Group, Pkt)
    end.

%%--------------------------------------------------------------------
-spec modify(integer(), #ofp_group_mod{}) -> ok |
                                             {error, Type :: atom(), Code :: atom()}.

%%------ group_mod ADD GROUP
modify(_SwitchId, #ofp_group_mod{ command = add, group_id = BadGroupId })
  when is_atom(BadGroupId); BadGroupId > ?OFPG_MAX ->
    %% Can't add a group with a reserved group id (represented as
    %% atoms here), or with a group id greater than the largest
    %% allowed.
    {error, #ofp_error_msg{type = group_mod_failed, code = invalid_group}};
modify(SwitchId, #ofp_group_mod{ command = add,
                                 group_id = Id,
                                 type = Type,
                                 buckets = Buckets }) ->
    %% Add new entry to the group table, if entry with given group id is already
    %% present, then return error.
    OFSBuckets = wrap_buckets_into_linc_buckets(Id, Buckets),
    RefersToGroups = calculate_refers_to_groups(Buckets, ordsets:new()),
    Entry = #linc_group{
      id = Id,
      type = Type,
      buckets = OFSBuckets,
      total_weight = calculate_total_weight(Buckets),
      refers_to_groups = RefersToGroups
     },
    case ets:insert_new(linc:lookup(SwitchId, group_table), Entry) of
        true ->
            %% just in case, zero stats
            group_reset_stats(SwitchId, Id),
            group_reset_timers(SwitchId, Id),
            lists:foreach(
              fun(Bucket) ->
                      BucketId = Bucket#linc_bucket.unique_id,
                      group_reset_bucket_stats(SwitchId, BucketId)
              end, OFSBuckets);
        false ->
            {error, #ofp_error_msg{type = group_mod_failed,
                                   code = group_exists}}
    end;

%%------ group_mod MODIFY GROUP
modify(SwitchId, #ofp_group_mod{ command = modify,
                                 group_id = Id,
                                 type = Type,
                                 buckets = Buckets }) ->
    %% Modify existing entry in the group table, if entry with given group id
    %% is not in the table, then return error.
    Entry = #linc_group{
      id = Id,
      type = Type,
      buckets = wrap_buckets_into_linc_buckets(Id, Buckets),
      total_weight = calculate_total_weight(Buckets)
     },
    %% Reset group counters
    %% Delete stats for buckets
    case group_get(SwitchId, Id) of
        not_found ->
            {error, #ofp_error_msg{type = group_mod_failed,
                                   code = unknown_group}};
        OldGroup ->
            lists:foreach(
              fun(B) ->
                      group_reset_bucket_stats(SwitchId,
                                               B#linc_bucket.unique_id)
              end, OldGroup#linc_group.buckets),

            group_reset_stats(SwitchId, Id),
            group_delete_timers(SwitchId, Id),
            ets:insert(linc:lookup(SwitchId, group_table), Entry),
            ok
    end;

%%------ group_mod DELETE GROUP
modify(SwitchId, #ofp_group_mod{ command = delete,
                                 group_id = Id }) ->
    %% Deletes existing entry in the group table, if entry with given group id
    %% is not in the table, no error is recorded. Flows containing given
    %% group id are removed along with it.
    %% If one wishes to effectively delete a group yet leave in flow entries
    %% using it, that group can be cleared by sending a modify with no buckets
    %% specified.
    case Id of
        all ->
            %% Reset group counters
            ets:delete_all_objects(linc:lookup(SwitchId, group_table)),
            ets:delete_all_objects(linc:lookup(SwitchId, group_stats));
        any ->
            %% TODO: Should we support this case at all?
            ok;
        Id ->
            group_delete(SwitchId, Id)
    end,
    ok.

%%--------------------------------------------------------------------
%% @doc Responds with stats for given group or special atom 'all' requests
%% stats for all groups in a list
%% Returns no error, if the requested id doesn't exist, would return empty list
-spec get_stats(integer(), #ofp_group_stats_request{}) ->
                       #ofp_group_stats_reply{}.
get_stats(SwitchId, #ofp_group_stats_request{group_id = GroupId}) ->
    %% Special groupid 'all' requests all groups stats
    IdList = case GroupId of
                 all ->
                     Pattern = ets:fun2ms(fun(#linc_group{id = Id}) -> Id end),
                     ets:select(linc:lookup(SwitchId, group_table), Pattern);
                 Id ->
                     [Id]
             end,
    Stats = [group_get_stats(SwitchId, Id) || Id <- IdList],
    #ofp_group_stats_reply{body = lists:flatten(Stats)}.

%%--------------------------------------------------------------------
-spec get_desc(integer(), #ofp_group_desc_request{}) ->
                      #ofp_group_desc_reply{}.
get_desc(SwitchId, #ofp_group_desc_request{}) ->
    #ofp_group_desc_reply{
       body = group_enum_groups(SwitchId)
      }.

%%--------------------------------------------------------------------
-spec get_features(#ofp_group_features_request{}) ->
                          #ofp_group_features_reply{}.
get_features(#ofp_group_features_request{ flags = _F }) ->
    #ofp_group_features_reply{
       types = [all, select, indirect, ff],
       capabilities = [select_weight, chaining], %select_liveness, chaining_checks
       max_groups = {?MAX, ?MAX, ?MAX, ?MAX},
       actions = {?SUPPORTED_WRITE_ACTIONS, ?SUPPORTED_WRITE_ACTIONS,
                  ?SUPPORTED_WRITE_ACTIONS, ?SUPPORTED_WRITE_ACTIONS}
      }.

%%--------------------------------------------------------------------
%% @doc Test if a group exists.
-spec is_valid(integer(), integer()) -> boolean().
is_valid(SwitchId, GroupId) ->
    ets:member(linc:lookup(SwitchId, group_table), GroupId).

%%%==============================================================
%%% Tool Functions
%%%==============================================================

%% @internal
%% @doc Chooses a bucket of actions from list of buckets according to the
%% group type. Executes actions. Returns [{packet, portnum|'drop'}]
%% (see 5.4.1 of OF1.2 spec)
-spec apply_group_type_to_packet(#linc_group{}, #linc_pkt{}) -> ok.

apply_group_type_to_packet(#linc_group{type = all, buckets = Buckets},
                           Pkt = #linc_pkt{}) ->
    %% Required: all: Execute all buckets in the group. This group is used for
    %% multicast or broadcast forwarding. The packet is effectively cloned for
    %% each bucket; one packet is processed for each bucket of the group. If a
    %% bucket directs a packet explicitly out of the ingress port, this packet
    %% clone is dropped. If the controller writer wants to forward out of the
    %% ingress port, the group should include an extra bucket which includes an
    %% output action to the OFPP_IN_PORT reseved port.
    lists:map(fun(Bucket) ->
                      apply_bucket(Bucket, Pkt)
              end, Buckets),
    ok;

apply_group_type_to_packet(G = #linc_group{type = select, buckets = Buckets},
                           Pkt = #linc_pkt{}) ->
    %% Optional: select: Execute one bucket in the group. Packets are processed
    %% by a single bucket in the group, based on a switch-computed selection
    %% algorithm (e.g. hash on some user-configured tuple or simple round robin).
    %% All configuration and state for the selection algorithm is external to
    %% OpenFlow. The selection algorithm should implement equal load sharing and
    %% can optionally be based on bucket weights. When a port specified in a
    %% bucket in a select group goes down, the switch may restrict bucket
    %% selection to the remaining set (those with forwarding actions to live ports)
    %% instead of dropping packets destined to that port.

    Rand = random:uniform(G#linc_group.total_weight),
    Bucket = select_random_bucket_by_weight(Rand, 0, Buckets),

    %% check against empty bucket list
    true = (Bucket =/= not_found),
    ok = apply_bucket(Bucket, Pkt),
    ok;

apply_group_type_to_packet(#linc_group{type = indirect, buckets = Buckets},
                           Pkt = #linc_pkt{})  ->
    %% Required: indirect: Execute the one defined bucket in this group. This
    %% group supports only a single bucket. Allows multiple flows or groups to
    %% point to a common group identifier, supporting faster, more efficient
    %% convergence (e.g. next hops for IP forwarding). This group type is
    %% effectively identical to an 'all' group with one bucket.
    [Bucket] = Buckets,
    ok = apply_bucket(Bucket, Pkt),
    ok;

apply_group_type_to_packet(#linc_group{type = ff, buckets = Buckets},
                           Pkt = #linc_pkt{})  ->
    %% Optional: fast failover: Execute the first live bucket. Each action bucket
    %% is associated with a specific port and/or group that controls its liveness.
    %% The buckets are evaluated in the order defined by the group, and the first
    %% bucket which is associated with a live port/group is selected. This group
    %% type enables the switch to change forwarding without requiring a round
    %% trip to the controller. If no buckets are live, packets are dropped. This
    %% group type must implement a liveness mechanism (see 6.9 of OF1.2 spec)
    case pick_live_bucket(Buckets) of
        false ->
            ok;
        Bucket ->
            ok = apply_bucket(Bucket, Pkt),
            ok
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Select bucket based on port liveness logic
-spec pick_live_bucket([#linc_bucket{}]) -> #linc_bucket{} | false.

pick_live_bucket([]) -> false;
pick_live_bucket([Bucket | _]) -> Bucket.

%%--------------------------------------------------------------------
%% @internal
%% @doc Applies set of commands
-spec apply_bucket(#linc_bucket{}, #linc_pkt{}) -> ok.

apply_bucket(#linc_bucket{
                unique_id = BucketId,
                bucket = #ofp_bucket{actions = Actions}},
             #linc_pkt{switch_id = SwitchId} = Pkt) ->
    %% update bucket stats no matter where packet goes
    group_update_bucket_stats(SwitchId, BucketId, packet_count, 1),
    group_update_bucket_stats(SwitchId, BucketId, byte_count, Pkt#linc_pkt.size),

    %%ActionsSet = ordsets:from_list(Actions),
    case linc_us4_oe_actions:apply_set(Pkt#linc_pkt{ actions = Actions }) of
        {error, Reason} ->
            larger:error("Applying bucket with ID ~p failed becase: ~p~n",
                         [BucketId, Reason]),
            ok;
        _SideEffects ->
            ok
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Called from modify() to wrap incoming buckets into #linc_bucket{}, with
%% counters added, which is wrapped into #linc_bucket{} with unique id added
-spec wrap_buckets_into_linc_buckets(GroupId :: integer(),
                                     [#ofp_bucket{}]) -> [#linc_bucket{}].

wrap_buckets_into_linc_buckets(GroupId, Buckets) ->
    lists:map(fun(B) ->
                      #linc_bucket{
                         bucket = B,
                         unique_id = {GroupId, create_unique_id_for_bucket(B)}
                        }
              end, Buckets).

%%--------------------------------------------------------------------
%% @internal
%% @doc Creates an unique ID based on contents of the bucket. If contents changes,
%% the unique ID will be recalculated and changes as well.
-spec create_unique_id_for_bucket(#ofp_bucket{}) -> term().

create_unique_id_for_bucket(B) ->
    EncodedBucket = term_to_binary(B),

    %% Add a timestamp in case of identical buckets + a random
    {MegaS, S, MicroS} = os:timestamp(),
    Random = random:uniform(16#7FFFFFFF),

    %% NOTE: this may create key collision if random and microseconds match
    Image = <<EncodedBucket/binary, MegaS:32, S:32, MicroS:32, Random:32>>,
    %% Create a hash
    crypto:sha(Image).

%%%==============================================================
%%% Stats counters and groups support functions
%%%==============================================================

%%--------------------------------------------------------------------
%% @internal
%% @doc Deletes all stats for group but not the buckets!
group_reset_stats(SwitchId, GroupId) ->
    %% Delete stats for group
    GroupStats = linc:lookup(SwitchId, group_stats),
    ets:delete(GroupStats, {group, GroupId, reference_count}),
    ets:delete(GroupStats, {group, GroupId, packet_count}),
    ets:delete(GroupStats, {group, GroupId, byte_count}),
    ok.

%%--------------------------------------------------------------------
%% @internal
%% @doc Resets group stats starting time to current Unix time (in microsec)
group_reset_timers(SwitchId, GroupId) ->
    %% Set timer of the group to current time
    {Mega, Sec, Micro} = os:timestamp(),
    NowMicro = (Mega * 1000000 + Sec) * 1000000 + Micro,
    ets:insert(linc:lookup(SwitchId, group_stats),
               #linc_group_stats{
                  key   = {group_start_time, GroupId},
                  value = NowMicro
                 }),
    ok.

%%--------------------------------------------------------------------
%% @internal
%% @doc Deletes timer from ETS
group_delete_timers(SwitchId, GroupId) ->
    ets:delete(linc:lookup(SwitchId ,group_stats), {group_start_time, GroupId}).

%%--------------------------------------------------------------------
%% @internal
%% @doc Updates stat counter in ETS for group
-spec group_update_stats(SwitchId :: integer(),
                         GroupId :: integer(),
                         Stat :: atom(),
                         Increment :: integer()) -> ok.
group_update_stats(SwitchId, GroupId, Stat, Increment) ->
    Threshold = (1 bsl group_stat_bitsize(Stat)) - 1,
    try
        ets:update_counter(linc:lookup(SwitchId, group_stats),
                           {group, GroupId, Stat},
                           {#linc_group_stats.value, Increment, Threshold, 0})
    catch
        error:badarg ->
            ets:insert(linc:lookup(SwitchId, group_stats),
                       #linc_group_stats{
                          key = {group, GroupId, Stat},
                          value = Increment
                         })
    end,
    ok.

%%--------------------------------------------------------------------
%% @internal
%% @doc Requests full group stats
-spec group_get_stats(integer(), integer()) -> list(#ofp_group_stats{}).
group_get_stats(SwitchId, GroupId) ->
    case group_get(SwitchId, GroupId) of
        not_found ->
            [];
        G ->
            BStats = [#ofp_bucket_counter{
                         packet_count = group_get_bucket_stat(SwitchId,
                                                              Bucket#linc_bucket.unique_id,
                                                              packet_count),
                         byte_count = group_get_bucket_stat(SwitchId,
                                                            Bucket#linc_bucket.unique_id,
                                                            byte_count)
                        } || Bucket <- G#linc_group.buckets],

            {MicroNowMS, MicroNowS, MicroNowMicroS} = os:timestamp(),
            MicroNow = (MicroNowMS * 1000000 + MicroNowS) * 1000000 + MicroNowMicroS,
            GroupTime = MicroNow - group_get_time(SwitchId, GroupId),

            [#ofp_group_stats{
                group_id      = GroupId,
                ref_count     = group_get_stat(SwitchId, GroupId, reference_count),
                packet_count  = group_get_stat(SwitchId, GroupId, packet_count),
                byte_count    = group_get_stat(SwitchId, GroupId, byte_count),
                bucket_stats  = BStats,
                duration_sec  = GroupTime div 1000000,           % seconds
                duration_nsec = (GroupTime rem 1000000) * 1000 % microsec * 1000 = nsec
               }]
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Retrieves one stat for group, zero if stat or group doesn't exist
group_get_stat(SwitchId, GroupId, Stat) ->
    case ets:lookup(linc:lookup(SwitchId, group_stats),
                    {group, GroupId, Stat}) of
        [] ->
            0;
        [{linc_group_stats, {group, GroupId, Stat}, Value}] ->
            Value
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Retrieves life duration of group. Record not found is error
group_get_time(SwitchId, GroupId) ->
    case ets:lookup(linc:lookup(SwitchId, group_stats),
                    {group_start_time, GroupId}) of
        [] ->
            erlang:error({?MODULE, group_get_time, not_found, GroupId});
        [{linc_group_stats, {group_start_time, GroupId}, Value}] ->
            Value
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Retrieves one stat for bucket (group id is part of bucket id),
%% returns zero if stat or group or bucket doesn't exist
group_get_bucket_stat(SwitchId, BucketId, Stat) ->
    case ets:lookup(linc:lookup(SwitchId, group_stats),
                    {bucket, BucketId, Stat}) of
        [] ->
            0;
        [Value] ->
            Value
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Deletes bucket stats for groupid and bucketid
-spec group_reset_bucket_stats(integer(), linc_bucket_id()) -> ok.
group_reset_bucket_stats(SwitchId, BucketId) ->
    ets:delete(linc:lookup(SwitchId, group_stats),
               {bucket, BucketId, packet_count}),
    ets:delete(linc:lookup(SwitchId, group_stats),
               {bucket, BucketId, byte_count}),
    ok.

%%--------------------------------------------------------------------
%% @internal
%% @doc Updates stat counter in ETS for bucket in group
-spec group_update_bucket_stats(SwitchId :: integer(),
                                BucketId :: linc_bucket_id(),
                                Stat :: atom(),
                                Increment :: integer()) -> ok.
group_update_bucket_stats(SwitchId, BucketId, Stat, Increment) ->
    Threshold = (1 bsl group_bucket_stat_bitsize(Stat)) - 1,
    try
        ets:update_counter(linc:lookup(SwitchId, group_stats),
                           {bucket, BucketId, Stat},
                           {#linc_group_stats.value, Increment, Threshold, 0})
    catch
        error:badarg ->
            ets:insert(linc:lookup(SwitchId, group_stats),
                       #linc_group_stats{
                          key = {bucket, BucketId, Stat},
                          value = Increment
                         })
    end,
    ok.

%%--------------------------------------------------------------------
%% @internal
%% @doc Reads group from ETS or returns not_found
-spec group_get(integer(), integer()) -> not_found | #linc_group{}.
group_get(SwitchId, GroupId) ->
    case ets:lookup(linc:lookup(SwitchId, group_table), GroupId) of
        [] ->
            not_found;
        [Group] ->
            Group
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Returns bit width of counter fields for group
group_stat_bitsize(reference_count) -> 32;
group_stat_bitsize(packet_count)    -> 64;
group_stat_bitsize(byte_count)      -> 64.
                                                %group_stat_bitsize(X) ->
                                                %    erlang:raise(exit, {badarg, X}).

%%--------------------------------------------------------------------
%% @internal
%% @doc Returns bit width of counter fields for bucket
group_bucket_stat_bitsize(packet_count) -> 64;
group_bucket_stat_bitsize(byte_count)   -> 64.
                                                %group_bucket_stat_bitsize(X) ->
                                                %    erlang:raise(exit, {badarg, X}).


%%--------------------------------------------------------------------
%% @internal
%% @doc Iterates over all keys of groups table and creates list of
%% #ofp_group_desc_stats{} standard records for group stats response
-spec group_enum_groups(integer()) -> [#ofp_group_desc_stats{}].
group_enum_groups(SwitchId) ->
    GroupTable = linc:lookup(SwitchId, group_table),
    group_enum_groups_2(GroupTable, ets:first(GroupTable), []).

%% @internal
%% @hidden
%% @doc (does the iteration job for group_enum_groups/0)
group_enum_groups_2(_GroupTable, '$end_of_table', Accum) ->
    lists:reverse(Accum);
group_enum_groups_2(GroupTable, K, Accum) ->
    %% record must always exist, as we are iterating over table keys
    [Group] = ets:lookup(GroupTable, K),
    %% unwrap wrapped buckets
    Buckets = [B#linc_bucket.bucket || B <- Group#linc_group.buckets],
    %% create standard structure
    GroupDesc = #ofp_group_desc_stats{
                   group_id = Group#linc_group.id,
                   type = Group#linc_group.type,
                   buckets = Buckets
                  },
    group_enum_groups_2(GroupTable, ets:next(GroupTable, K),
                        [GroupDesc | Accum]).

%%--------------------------------------------------------------------
%% @internal
%% @doc Deletes a group by Id, also deletes all groups and flows referring
%% to this group
group_delete(SwitchId, Id) ->
    group_delete_2(SwitchId, Id, ordsets:new()).

%% @internal
%% @doc Does recursive deletion taking into account groups already processed to
%% avoid infinite loops. Returns false o
-spec group_delete_2(SwitchId :: integer(), Id :: integer(),
                     ProcessedGroups :: ordsets:ordset()) ->
                            ordsets:ordset().
group_delete_2(SwitchId, Id, ProcessedGroups) ->
    case ordsets:is_element(Id, ProcessedGroups) of
        true ->
            ProcessedGroups;

        false ->
            GroupTable = linc:lookup(SwitchId, group_table),
            FirstGroup = ets:first(GroupTable),
            ReferringGroups = group_find_groups_that_refer_to(SwitchId,
                                                              Id,
                                                              FirstGroup,
                                                              ordsets:new()),

            %% Delete group timers and bucket timers
            group_delete_timers(SwitchId, Id),

            %% Delete group stats and remove the group
            group_reset_stats(SwitchId, Id),
            ets:delete(GroupTable, Id),

            %% Remove flows containing given group along with it
            linc_us4_oe_flow:delete_where_group(SwitchId, Id),

            PG2 = ordsets:add_element(Id, ProcessedGroups),

            %% Remove referring groups
            RFunc = fun(X, Accum) -> group_delete_2(SwitchId, X, Accum) end,
            lists:foldl(RFunc, PG2, ReferringGroups)
    end.

%%--------------------------------------------------------------------
%% @internal
%% @doc Iterates over groups table, filters out groups which refer to the
%% group id 'Id' using cached field in #linc_group{} record
group_find_groups_that_refer_to(_SwitchId, _Id, '$end_of_table', OrdSet) ->
    OrdSet;
group_find_groups_that_refer_to(SwitchId, Id, EtsKey, OrdSet) ->
    %% this should never crash, as we are iterating over existing keys
    GroupTable = linc:lookup(SwitchId, group_table),
    [G] = ets:lookup(GroupTable, EtsKey),

    NextKey = ets:next(GroupTable, EtsKey),
    case ordsets:is_element(Id, G#linc_group.refers_to_groups) of
        false ->
            group_find_groups_that_refer_to(SwitchId, Id, NextKey, OrdSet);
        true ->
            OrdSet2 = ordsets:add_element(EtsKey, OrdSet),
            group_find_groups_that_refer_to(SwitchId, Id, NextKey, OrdSet2)
    end.

%%--------------------------------------------------------------------
%% @internal
select_random_bucket_by_weight(_RandomWeight, _Accum, []) ->
    not_found;
select_random_bucket_by_weight(RandomWeight, Accum, [Bucket|_])
  when RandomWeight >= Accum ->
    Bucket;
select_random_bucket_by_weight(RandomWeight, Accum, [Bucket|Tail]) ->
    select_random_bucket_by_weight(RandomWeight,
                                   Accum + (Bucket#linc_bucket.bucket)#ofp_bucket.weight,
                                   Tail).

%%--------------------------------------------------------------------
%% @internal
%% @doc Iterates over buckets, calculates sum of all weights in a bucket
-spec calculate_total_weight(Buckets :: [ofp_bucket()]) -> integer().
calculate_total_weight(Buckets) ->
    lists:foldl(fun(B, Sum) ->
                        case B#ofp_bucket.weight of
                            W when is_integer(W) -> W;
                            _ -> 1
                        end + Sum
                end, 0, Buckets).

%%--------------------------------------------------------------------
%% @internal
%% @doc Iterates over all buckets and actions, and builds a set of group
%% references, to have ordset of groupids this bucket list refers to
-spec calculate_refers_to_groups([#ofp_bucket{}],
                                 ordsets:ordset(integer())) ->
                                        ordsets:ordset(integer()).

calculate_refers_to_groups([], Set) ->
    Set;
calculate_refers_to_groups([B|Buckets], Set) ->
    Set2 = calculate_refers_to_groups_2(B#ofp_bucket.actions, Set),
    calculate_refers_to_groups(Buckets, Set2).

%% @internal
%% @doc Iterates over actions in a bucket, filtering out #ofp_action_group
%% actions, and adding GroupId in them to Set
calculate_refers_to_groups_2([], Set) -> Set;

calculate_refers_to_groups_2([#ofp_action_group{
                                 group_id = GroupId
                                }|Actions], Set) ->
    Set2 = ordsets:add_element(GroupId, Set),
    calculate_refers_to_groups_2(Actions, Set2);

calculate_refers_to_groups_2([_|Actions], Set) ->
    calculate_refers_to_groups_2(Actions, Set).
