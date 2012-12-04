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
-module(linc_us4_buffer).

%% API
-export([initialize/0,
         terminate/1,
         save_buffer/1,
         get_buffer/1]).

%% Internal
-export([expire_buffers/0]).

-include("linc_us4.hrl").

-record(linc_buffer, {id :: non_neg_integer(),
                      expires :: erlang:timestamp(),
                      packet :: #ofs_pkt{}}).

-record(linc_buffer_id, {key :: key,
                         id_num :: non_neg_integer()}).

-define(MAX_ID, 16#FFFFFFFF-1).
-define(INTERVAL, 1). % In seconds
-define(MAX_AGE, 2).  % In seconds

-record(state, {tref}).

%%%===================================================================
%%% API
%%%===================================================================

-spec initialize() -> #state{}.
initialize() ->
    linc_buffers = ets:new(linc_buffers,
                           [named_table,
                            public,
                            {keypos, #linc_buffer.id}]),

    linc_buffer_id = ets:new(linc_buffer_id,
                             [named_table,
                              public,
                              {keypos, #linc_buffer_id.key}]),

    ets:insert(linc_buffer_id, #linc_buffer_id{key=key, id_num=0}),

    {ok,Tref} = timer:apply_interval(timer:seconds(?INTERVAL),
                                     ?MODULE, expire_buffers, []),
    #state{tref=Tref}.

terminate(#state{tref=Tref}) ->
    timer:cancel(Tref),
    ets:delete(linc_buffers),
    ets:delete(linc_buffer_id).

%% @doc Save a packet.
%% @end
-spec save_buffer(#ofs_pkt{}) -> non_neg_integer().
save_buffer(Packet) ->
    Id = next_id(),
    ets:insert(linc_buffers, #linc_buffer{id = Id,
                                          expires = expiration_time(),
                                          packet = Packet}),
    Id.

%% @doc Retreive a packet. If the packet has already been expired 
%% not_found is returned.
-spec get_buffer(non_neg_integer()) -> #ofs_pkt{} | not_found.
get_buffer(BufferId) ->
    case ets:lookup(linc_buffers,BufferId) of
        [#linc_buffer{packet=Packet}] ->
            Packet;
        [] ->
            not_found
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
next_id() ->
    ets:update_counter(linc_buffer_id, key, {#linc_buffer_id.id_num, 1, ?MAX_ID, 0}).

expiration_time() ->
    {Mega,Secs,Micro} = os:timestamp(),
    case Secs+?MAX_AGE of
        S when S>999999 ->
            {Mega+1,S-999999,Micro};
        S ->
            {Mega,S,Micro}
    end.

expire_buffers() ->
    Now = os:timestamp(),
    ets:foldl(fun (#linc_buffer{id=Id,expires=Expires}, Acc) when Expires<Now ->
                      ets:delete(linc_buffers,Id),
                      Acc;
                  (_Buffer, Acc) ->
                      Acc
              end, ok, linc_buffers).
