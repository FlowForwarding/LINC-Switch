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
         , get_features/1]).

%% Group Mod
%% -export([add/1,
%%          modify/1,
%%          delete/1]).

-include("linc_us3.hrl").
%% already included from linc_us3.hrl -include_lib("of_protocol/include/ofp_v3.hrl").

-record(linc_group, {
          id            :: ofp_group_id(),
          type    = all :: ofp_group_type(),
          buckets = []  :: [#ofs_bucket{}]
         }).

-record(linc_bucket, {
          bucket :: ofp_bucket(),
          unique_id :: integer()
         }).

%%%==============================================================
%%% API implementation
%%%==============================================================

create() ->
    group_table = ets:new(group_table, [named_table, public,
                                        {keypos, #linc_group.id},
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
    group_stats = ets:new(group_stats, [named_table, public,
                                        {keypos, #ofp_group_stats.group_id},
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
    ok.

destroy() ->
    ets:delete(group_table),
    ets:delete(group_stats),
    ok.

%% @doc Applies group GroupId to packet Pkt, result should be list of
%% packets and ports where they are destined or 'drop' atom. Packet is
%% cloned if multiple ports are the destination.
-spec apply(GroupId :: integer(), Pkt :: #ofs_pkt{}) -> ok.
                   %% [{NewPkt :: #ofs_pkt{}, Port :: ofp_port_no() | drop}].

apply(GroupId, Pkt) ->
    case ets:lookup(group_table, GroupId) of
        [] -> ok;
        [Group] -> apply_group_type(Group#linc_group.type,
                                    Group#linc_group.buckets, Pkt)
    end.

-spec modify(#ofp_group_mod{}) -> ok | {error, Type :: atom(), Code :: atom()}.
modify(#ofp_group_mod{ command = add,
                       group_id = Id,
                       type = Type,
                       buckets = Buckets }) ->
    %% Add new entry to the group table, if entry with given group id is already
    %% present, then return error.
    OFSBuckets = lists:map(fun(B) ->
                                   #ofs_bucket{value = B,
                                               counter = #ofp_bucket_counter{}}
                           end, Buckets),
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
            ets:delete_all_objects(group_table);
        any ->
            %% TODO: Should we support this case at all?
            ok;
        Id ->
            ets:delete(group_table, Id)
    end,
    %% TODO: Remove flows containing given group along with it
    ok.

-spec get_stats(#ofp_group_stats_request{}) ->
                       #ofp_group_stats_reply{}.
get_stats(_R) ->
    #ofp_group_stats_reply{}.

-spec get_desc(#ofp_group_desc_stats_request{}) ->
                      #ofp_group_desc_stats_reply{}.
get_desc(_R) ->
    #ofp_group_desc_stats_reply{}.

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
-spec apply_group_type(ofp_group_type(), [#ofs_bucket{}], #ofs_pkt{}) -> ok.
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
-spec pick_live_bucket([#ofs_bucket{}]) -> #ofs_bucket{} | false.

pick_live_bucket([]) -> false;
pick_live_bucket([Bucket | _]) -> Bucket.

%% @doc Applies set of commands
-spec apply_bucket(#ofs_bucket{}, #ofs_pkt{}) -> ok.

apply_bucket(#ofs_bucket{value = #ofp_bucket{actions = Actions}}, Pkt) ->
    case linc_us3_actions:apply_set(Actions, Pkt) of
        {output, NewPkt, PortNo} ->
            linc_us3_port:send(NewPkt, PortNo);
        {group, NewPkt, GroupId} ->
            ?MODULE:apply(NewPkt, GroupId);
        drop ->
            drop
    end,
    ok.

%%%==============================================================
%%% Stats counters and support
%%%==============================================================

