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

-export([apply/2]).

-include("linc_us3.hrl").

-spec apply(ofp_group_id(), #ofs_pkt{}) -> #ofs_pkt{}.
apply(GroupId, Pkt) ->
    case ets:lookup(group_table, GroupId) of
        [] ->
            Pkt;
        [Group] ->
            apply_group_type(Group#group.type, Group#group.buckets, Pkt)
    end.

-spec apply_group_type(ofp_group_type(), [#ofs_bucket{}], #ofs_pkt{}) ->
                              #ofs_pkt{}.
apply_group_type(all, Buckets, Pkt) ->
    lists:map(fun(Bucket) ->
                      apply_bucket(Bucket, Pkt)
              end, Buckets);
apply_group_type(select, [Bucket | _Rest], Pkt) ->
    apply_bucket(Bucket, Pkt);
apply_group_type(indirect, [Bucket], Pkt) ->
    apply_bucket(Bucket, Pkt);
apply_group_type(ff, Buckets, Pkt) ->
    case pick_live_bucket(Buckets) of
        false ->
            drop;
        Bucket ->
            apply_bucket(Bucket, Pkt)
    end.

-spec apply_bucket(#ofs_bucket{}, #ofs_pkt{}) -> #ofs_pkt{}.
apply_bucket(#ofs_bucket{value = #ofp_bucket{actions = Actions}}, Pkt) ->
    linc_us3_actions:apply(0, Actions, Pkt).

-spec pick_live_bucket([#ofs_bucket{}]) -> #ofs_bucket{} | false.
pick_live_bucket(Buckets) ->
    %% TODO Implement bucket liveness logic
    case Buckets of
        [] ->
            false;
        _ ->
            hd(Buckets)
    end.
