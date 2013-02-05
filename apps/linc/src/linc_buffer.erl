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
%% @doc Module for handling flows.
-module(linc_buffer).

%% API
-export([initialize/1,
         terminate/1,
         save_buffer/2,
         get_buffer/2]).

%% Internal
-export([expire_buffers/1]).

-record(linc_buffer, {id :: non_neg_integer(),
                      expires :: erlang:timestamp(),
                      packet :: term()}).

-record(linc_buffer_id, {key :: key,
                         id_num :: non_neg_integer()}).

-define(MAX_ID, 16#FFFFFFFF-1).
-define(INTERVAL, 1). % In seconds
-define(MAX_AGE, 2).  % In seconds

-record(state, {linc_buffers :: ets:tid(),
                linc_buffer_id :: ets:tid(),
                tref :: timer:tref()}).

%%%===================================================================
%%% API
%%%===================================================================

-spec initialize(integer()) -> #state{}.
initialize(SwitchId) ->
    LincBuffers = ets:new(linc_buffers,
                          [public,
                           {keypos, #linc_buffer.id}]),
    LincBufferId = ets:new(linc_buffer_id,
                           [public,
                            {keypos, #linc_buffer_id.key}]),
    linc:register(SwitchId, linc_buffers, LincBuffers),
    linc:register(SwitchId, linc_buffer_id, LincBufferId),
    ets:insert(LincBufferId, #linc_buffer_id{key=key, id_num=0}),
    {ok,Tref} = timer:apply_interval(timer:seconds(?INTERVAL),
                                     ?MODULE, expire_buffers, [SwitchId]),
    #state{linc_buffers = LincBuffers,
           linc_buffer_id = LincBufferId,
           tref=Tref}.

terminate(#state{linc_buffers = LincBuffers,
                 linc_buffer_id = LincBufferId,
                 tref=Tref}) ->
    timer:cancel(Tref),
    ets:delete(LincBuffers),
    ets:delete(LincBufferId).

%% @doc Save a packet.
%% @end
-spec save_buffer(integer(), term()) -> non_neg_integer().
save_buffer(SwitchId, Packet) ->
    Id = next_id(SwitchId),
    ets:insert(linc:lookup(SwitchId, linc_buffers),
               #linc_buffer{id = Id,
                            expires = expiration_time(),
                            packet = Packet}),
    Id.

%% @doc Retreive a packet. If the packet has already been expired 
%% not_found is returned.
-spec get_buffer(integer(), non_neg_integer()) -> term() | not_found.
get_buffer(SwitchId, BufferId) ->
    case ets:lookup(linc:lookup(SwitchId, linc_buffers),BufferId) of
        [#linc_buffer{packet=Packet}] ->
            Packet;
        [] ->
            not_found
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
next_id(SwitchId) ->
    ets:update_counter(linc:lookup(SwitchId, linc_buffer_id), key,
                       {#linc_buffer_id.id_num, 1, ?MAX_ID, 0}).

expiration_time() ->
    {Mega,Secs,Micro} = os:timestamp(),
    case Secs+?MAX_AGE of
        S when S>999999 ->
            {Mega+1,S-999999,Micro};
        S ->
            {Mega,S,Micro}
    end.

expire_buffers(SwitchId) ->
    Now = os:timestamp(),
    LincBuffers = linc:lookup(SwitchId, linc_buffers),
    ets:foldl(fun (#linc_buffer{id=Id,expires=Expires}, Acc) when Expires<Now ->
                      ets:delete(LincBuffers, Id),
                      Acc;
                  (_Buffer, Acc) ->
                      Acc
              end, ok, LincBuffers).
