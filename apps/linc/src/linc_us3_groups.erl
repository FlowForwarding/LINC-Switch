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

-module(linc_us3_groups).

%% Group routing
%%-export([apply/2]).

%% API as defined by LINC team
-export([create/0
         , destroy/0
         , apply/2
         , modify/1
         , get_stats/1
         , get_desc/1
         , get_features/1
         , update_reference_count/2]).

%% Group Mod
%% -export([add/1,
%%          modify/1,
%%          delete/1]).

-include("linc_us3.hrl").
%% already included from linc_us3.hrl -include_lib("of_protocol/include/ofp_v3.hrl").

%% @doc Bucket wrapper adding unique_id field to the original OFP bucket
-record(linc_bucket, {
          bucket    :: ofp_bucket(),
          unique_id :: binary()
         }).

%% @doc Group object
-record(linc_group, {
          id            :: ofp_group_id(),
          type    = all :: ofp_group_type(),
          buckets = []  :: [#linc_bucket{}]
         }).

%% @doc Stats item record for storing stats in ETS
-record(linc_group_stats, {
          key   :: tuple(),
          value :: integer()
         }).

%%%==============================================================
%%% API implementation
%%%==============================================================

%% @doc Module startup
create() ->
    group_table = ets:new(group_table, [named_table, public,
                                        {keypos, #linc_group.id},
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
    %% Stats are stored in form of #linc_group_stats{key, value}, key is a tuple
    %% {group, GroupId, packet_count}
    %% {group, GroupId, byte_count}
    %% {bucket, GroupId, BucketId, packet_count}
    %% {bucket, GroupId, BucketId, byte_count}
    %% and value is 32 or 64 bit unsigned counter, which wraps when reaching max
    %% value for 32 or 64 bit.
    group_stats = ets:new(group_stats, [named_table, public,
                                        {keypos, #linc_group_stats.key},
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
    ok.

%%--------------------------------------------------------------------
%% @doc Module shutdown
destroy() ->
    ets:delete(group_table),
    ets:delete(group_stats),
    ok.

%%--------------------------------------------------------------------
%% @doc Modifies group reference count by Increment
update_reference_count(GroupId, Increment) ->
    group_update_stats(GroupId, reference_count, Increment).

%%--------------------------------------------------------------------
%% @doc Applies group GroupId to packet Pkt, result should be list of
%% packets and ports where they are destined or 'drop' atom. Packet is
%% cloned if multiple ports are the destination.
-spec apply(GroupId :: integer(), Pkt :: #ofs_pkt{}) -> ok.
                   %% [{NewPkt :: #ofs_pkt{}, Port :: ofp_port_no() | drop}].

apply(GroupId, Pkt) ->
    case group_get(GroupId) of
        not_found -> ok;
        Group     -> apply_group_type(Group#linc_group.type,
                                      Group#linc_group.buckets, Pkt)
    end.

%%--------------------------------------------------------------------
-spec modify(#ofp_group_mod{}) -> ok | {error, Type :: atom(), Code :: atom()}.
modify(#ofp_group_mod{ command = add,
                       group_id = Id,
                       type = Type,
                       buckets = Buckets }) ->
    %% Add new entry to the group table, if entry with given group id is already
    %% present, then return error.
    OFSBuckets = wrap_buckets_into_linc_buckets(Buckets),
    Entry = #linc_group{id = Id, type = Type, buckets = OFSBuckets},
    case ets:insert_new(group_table, Entry) of
        true -> ok;
        false -> {error, #ofp_error_msg{type = group_mod_failed,
                                        code = group_exists}}
    end;
modify(#ofp_group_mod{ command = modify,
                       group_id = Id,
                       type = Type,
                       buckets = Buckets }) ->
    %% Modify existing entry in the group table, if entry with given group id
    %% is not in the table, then return error.
    Entry = #linc_group{id = Id, type = Type, buckets = Buckets},

    %% Reset group counters
    %% Delete stats for buckets
    case group_get(Id) of
        not_found -> ok;
        Group ->
            [group_reset_bucket_stats(Id, B#linc_bucket.unique_id)
             || B <- Group#linc_group.buckets]
    end,

    case ets:member(group_table, Id) of
        true ->
            ets:insert(group_table, Entry),
            ok;
        false ->
            {error, #ofp_error_msg{type = group_mod_failed,
                                   code = unknown_group}}
    end;

modify(#ofp_group_mod{ command = delete,
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
            ets:delete_all_objects(group_table),
            ets:delete_all_objects(group_stats);
        any ->
            %% TODO: Should we support this case at all?
            ok;
        Id ->
            group_reset_stats(Id),
            ets:delete(group_table, Id)
    end,
    %% TODO: Remove flows containing given group along with it
    ok.

%%--------------------------------------------------------------------
-spec get_stats(#ofp_group_stats_request{}) ->
                       #ofp_group_stats_reply{}.
get_stats(_R) ->
    #ofp_group_stats_reply{}.

%%--------------------------------------------------------------------
-spec get_desc(#ofp_group_desc_stats_request{}) ->
                      #ofp_group_desc_stats_reply{}.
get_desc(_R) ->
    #ofp_group_desc_stats_reply{}.

%%--------------------------------------------------------------------
-spec get_features(#ofp_group_features_stats_request{}) ->
                          #ofp_group_features_stats_reply{}.
get_features(_R) ->
    #ofp_group_features_stats_reply{}.

%%%==============================================================
%%% Tool Functions
%%%==============================================================

%% @doc Chooses a bucket of actions from list of buckets according to the
%% group type. Executes actions. Returns [{packet, portnum|'drop'}]
%% (see 5.4.1 of OF1.2 spec)
-spec apply_group_type(ofp_group_type(), [#linc_bucket{}], #ofs_pkt{}) -> ok.
                              % [{#ofs_pkt{}, Port :: integer() | drop}].

apply_group_type(all, Buckets, Pkt = #ofs_pkt{}) ->
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

apply_group_type(select, Buckets, Pkt) ->
    %% Optional: select: Execute one bucket in the group. Packets are processed
    %% by a single bucket in the group, based on a switch-computed selection
    %% algorithm (e.g. hash on some user-configured tuple or simple round robin).
    %% All configuration and state for the selection algorithm is external to
    %% OpenFlow. The selection algorithm should implement equal load sharing and
    %% can optionally be based on bucket weights. When a port specified in a
    %% bucket in a select group goes down, the switch may restrict bucket
    %% selection to the remaining set (those with forwarding actions to live ports)
    %% instead of dropping packets destined to that port.

    [Bucket | _Whatever] = Buckets, % TODO: add weights and round-robin logic
    ok = apply_bucket(Bucket, Pkt),
    ok;

apply_group_type(indirect, [Bucket], Pkt) ->
    %% Required: indirect: Execute the one defined bucket in this group. This
    %% group supports only a single bucket. Allows multiple flows or groups to
    %% point to a common group identifier, supporting faster, more efficient
    %% convergence (e.g. next hops for IP forwarding). This group type is
    %% effectively identical to an 'all' group with one bucket.
    ok = apply_bucket(Bucket, Pkt),
    ok;

apply_group_type(ff, Buckets, Pkt) ->
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

%% @doc Select bucket based on port liveness logic
-spec pick_live_bucket([#linc_bucket{}]) -> #linc_bucket{} | false.

pick_live_bucket([]) -> false;
pick_live_bucket([Bucket | _]) -> Bucket.

%% @doc Applies set of commands
-spec apply_bucket(#linc_bucket{}, #ofs_pkt{}) -> ok.

apply_bucket(#linc_bucket{bucket = #ofp_bucket{actions = Actions}}, Pkt) ->
    case linc_us3_actions:apply_set(Actions, Pkt) of
        {output, NewPkt, PortNo} ->
            linc_us3_port:send(NewPkt, PortNo);
        {group, NewPkt, GroupId} ->
            ?MODULE:apply(NewPkt, GroupId);
        drop ->
            drop
    end,
    ok.

%% @doc Called from modify() to wrap incoming buckets into #linc_bucket{}, with
%% counters added, which is wrapped into #linc_bucket{} with unique id added
-spec wrap_buckets_into_linc_buckets([#ofp_bucket{}]) -> [#linc_bucket{}].

wrap_buckets_into_linc_buckets(Buckets) ->
    lists:map(fun(B) ->
                      #linc_bucket{
                         bucket = B,
                         unique_id = create_unique_id_for_bucket(B)
                        }
              end, Buckets).

%% @internal
%% @doc Creates an unique ID based on contents of the bucket. If contents changes,
%% the unique ID will be recalculated and changes as well.
-spec create_unique_id_for_bucket(#ofp_bucket{}) -> term().

create_unique_id_for_bucket(B) ->
    EncodedBucket = ofp_v3_encode:encode_struct(B),

    %% Add a timestamp in case of identical buckets
    {MegaS, S, MicroS} = os:timestamp(),
    Image = <<EncodedBucket/binary, MegaS:32, S:32, MicroS:32>>,

    crypto:sha(Image).

%% create_unique_id_for_bucket(B) ->
%%     {MegaS, S, MicroS} = time:now(),
%%     MegaS * 1000000 * 1000000 + S * 1000000 + MicroS.

%%%==============================================================
%%% Stats counters and groups support functions
%%%==============================================================

%%--------------------------------------------------------------------
%% @doc Deletes all stats for group and its buckets
group_reset_stats(GroupId) ->
    %% Delete stats for group
    ets:delete(group_stats, {group, GroupId, reference_count}),
    ets:delete(group_stats, {group, GroupId, packet_count}),
    ets:delete(group_stats, {group, GroupId, byte_count}),
    ok.

%%--------------------------------------------------------------------
%% @doc Updates stat counter in ETS for group
-spec group_update_stats(GroupId :: integer(),
                         Stat :: atom(),
                         Increment :: integer()) -> ok.

group_update_stats(GroupId, Stat, Increment) ->
    Threshold = (1 bsl group_stat_bitsize(Stat)) - 1,
    try
        ets:update_counter(group_stats,
                           {group, GroupId, Stat},
                           {#linc_group_stats.value, Increment, Threshold, 0})
    catch
        error:badarg ->
            ets:insert(group_stats, #linc_group_stats{
                                       key = {group, GroupId, Stat},
                                       value = Increment
                                      })
    end,
    ok.

%%--------------------------------------------------------------------
%% @doc Deletes bucket stats for groupid and bucketid
-spec group_reset_bucket_stats(integer(), binary()) -> ok.

group_reset_bucket_stats(GroupId, BucketId) ->
    ets:delete(group_stats, {bucket, GroupId, BucketId, packet_count}),
    ets:delete(group_stats, {bucket, GroupId, BucketId, byte_count}),
    ok.

%%--------------------------------------------------------------------
%% @doc Updates stat counter in ETS for bucket in group
-spec group_update_bucket_stats(GroupId :: integer(),
                                BucketId :: binary(),
                                Stat :: atom(),
                                Increment :: integer()) -> ok.

group_update_bucket_stats(GroupId, BucketId, Stat, Increment) ->
    Threshold = (1 bsl group_bucket_stat_bitsize(Stat)) - 1,
    try
        ets:update_counter(group_stats,
                           {bucket, GroupId, BucketId, Stat},
                           {#linc_group_stats.value, Increment, Threshold, 0})
    catch
        error:badarg ->
            ets:insert(group_stats, #linc_group_stats{
                                       key = {bucket, GroupId, BucketId, Stat},
                                       value = Increment
                                      })
    end,
    ok.

%%--------------------------------------------------------------------
%% @doc Reads group from ETS or returns not_found
-spec group_get(integer()) -> not_found | #linc_group{}.

group_get(GroupId) ->
    case ets:lookup(group_table, GroupId) of
        [] -> not_found;
        [Group] -> Group
    end.

%%--------------------------------------------------------------------
group_stat_bitsize(reference_count) -> 32;
group_stat_bitsize(packet_count)    -> 64;
group_stat_bitsize(byte_count)      -> 64;
group_stat_bitsize(X) ->
    erlang:raise(exit, {badarg, X}).
    
%%--------------------------------------------------------------------
group_bucket_stat_bitsize(packet_count) -> 64;
group_bucket_stat_bitsize(byte_count)   -> 64;
group_bucket_stat_bitsize(X) ->
    erlang:raise(exit, {badarg, X}).
