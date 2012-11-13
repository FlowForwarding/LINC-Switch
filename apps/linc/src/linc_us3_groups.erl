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

%%%
%%% API implementation
%%%

create() ->
    ok.

destroy() ->
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
modify(_M) ->
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

%%%
%%% Tool Functions
%%%

%% @doc Chooses a bucket of actions from list of buckets according to the
%% group type. Executes actions. Returns [{packet, portnum|'drop'}]
%% (see 5.4.1 of OF1.2 spec)
-spec apply_group_type(ofp_group_type(), [#ofs_bucket{}], #ofs_pkt{}) -> ok.
                              % [{#ofs_pkt{}, Port :: integer() | drop}].

apply_group_type(all, Buckets, Pkt = #ofs_pkt{ in_port = InPort }) ->
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
