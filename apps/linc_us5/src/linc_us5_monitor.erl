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
%% @copyright 2014 FlowForwarding.org
%% @doc Module for handling per-flow meters.
-module(linc_us5_monitor).

-behaviour(gen_server).

%% API
-export([manage/9,
         monitor/5,
         batch_start/3,
         batch_end/1,
         sync/1,
         list_monitors/1]).

%% Internal API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% Just for mocking in common tests
-export([send/2]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us5.hrl").

-record(monitor_entry, {
          id         :: {pid(), integer()},
          out_port   :: ofp_port_no(),
          out_group  :: ofp_group_id(),
          flags = [] :: [ofp_multipart_request_flag()],
          table_id   :: ofp_table_id(),
          match      :: ofp_match()
         }).

-record(notification, {
          type       :: ofp_flow_update_event(),   %% Event type of update
          flow_id    :: flow_id(), %% Used for controlling dropping of updates in paused mode 
          client_pid :: pid(),     %% Client pid of the monitoring controller
          updates    :: [ofp_flow_monitor_reply()] %% The actual messages
         }).

-record(state, {
          switch_id      :: integer(),
          paused = false :: boolean(),
          %% Operating client pid and xid of request causing the flow update in batch mode, event
          %% These must be the same throughout the batch
          batch  = off   :: off | {pid(), integer(), ofp_flow_update_event()}, 
          batch_notifs   :: dict(), %% Notifications for each monitoring client pid
          queue_limit    :: integer(), %% Buffer size: monitoring will be paused when exceeded
          buffer         :: queue(),   %% Queued updates to be sent 
          store          :: queue()    %% Withheld add/modify events during paused mode 
         }).

%% Flow update buffer limit. Shall not be less than the expected 
%% number of flow entries, otherwise linc may oscillate between
%% paused and normal state when trying to recover from a pause.
-define(QUEUE_LIMIT, 16#ffff).
-define(TABLE_NAME, linc_monitor_ets).
-define(is_flag_set(Field, Flags), lists:member(Field, Flags)).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------
%% @doc create a new monitor entry. Sends initial notifications if required.
-spec manage(ofp_flow_monitor_command(), integer(), integer(), ofp_port_no(), 
             ofp_group_id(), [ofp_multipart_request_flag()], 
             ofp_table_id(), ofp_match(),#monitor_data{}) -> 
                    ok | {error, {flow_monitor_failed, 
                                  monitor_exists | unknown_monitor}}.
manage(Cmd, SwitchId, MonitorId, Port, Group, Flags, TableId, Match, 
       MonitorData) when Cmd =:= add;
                         Cmd =:= modify;
                         Cmd =:= delete ->
    gen_server:call(server(SwitchId), {Cmd, MonitorId, Port, Group, 
                                       Flags, TableId, Match, MonitorData}).

%% @doc 
%% Check a flow entry for matching monitors. Send notification if any matches
%%      found, accumulating all the required fields. 
%% -type ofp_flow_update_event() :: initial
%%                    | added
%%                    | removed
%%                    | modified
%%                    | abbrev
%%                    | paused
%%                    | resumed.
%% -type ofp_flow_removed_reason() :: idle_timeout
%%                                  | hard_timeout
%%                                  | delete
%%                                  | group_delete
%%                                  | meter_delete.
%% @end 
-spec monitor(integer(), ofp_flow_update_event(), integer(), #monitor_data{}, 
              #flow_entry{}) -> ok.
monitor(SwitchId, Event, TableId, MonitorData, Flow) ->
    gen_server:cast(server(SwitchId), {monitor, Event, TableId, 
                                       MonitorData, Flow}).

%% @doc 
%% Start of an operation thet may result in multiple flow updates 
%% (modify/remove matching flows). Updates must be sent together.
%% @end
-spec batch_start(integer(), ofp_flow_update_event(), #monitor_data{}) -> ok.
batch_start(SwitchId, Event, MonitorData) ->
    gen_server:cast(server(SwitchId), {batch_start, Event, MonitorData}).

%% @doc
%% End of batch, send updates, if any, together
%% @end
-spec batch_end(integer()) -> ok.
batch_end(SwitchId) ->
    gen_server:cast(server(SwitchId), batch_end).

%% @doc
%% Barrier request: sync updates: do not return until all submitted
%% @end
-spec sync(integer()) -> ok.
sync(SwitchId) ->
    gen_server:call(server(SwitchId), sync).

%%% @doc For debuging: list all client pid - monitor id pairs for switch 
-spec list_monitors(integer()) -> [{pid(), integer()}].
list_monitors(SwitchId) ->
    Tid = linc:lookup(SwitchId, ?TABLE_NAME),
    [M#monitor_entry.id || M <- ets:tab2list(Tid)].

%%==============================================================================
%% Internal API functions
%%==============================================================================

start_link(SwitchId) ->
    gen_server:start_link({local, server(SwitchId)}, 
                          ?MODULE, [SwitchId], []).

%%==============================================================================
%% gen_server callbacks
%%==============================================================================

init([SwitchId]) ->
    create_table(SwitchId),
    case application:get_env(linc, monitor_buffer_limit) of
        {ok, QLimit} ->
            ok;
        undefined ->
            QLimit = ?QUEUE_LIMIT
    end,
    ?INFO("Flow monitor started for switch ~p as ~p", [SwitchId, self()]),
    {ok, #state{switch_id = SwitchId,
                buffer = queue:new(),
                store  = queue:new(),
                queue_limit = QLimit}, 0}.

%% Monitor creation
handle_call({add, MonitorId, Port, Group, Flags, TableId, Match, 
             #monitor_data{client_pid = ClientPid}}, 
            _From, #state{switch_id = SwitchId} = State) ->
    Tid = linc:lookup(SwitchId, ?TABLE_NAME),
    case ets:lookup(Tid, MonitorId) of
        [] ->
            Monitor = #monitor_entry{id = {ClientPid, MonitorId},
                                     out_port = Port,
                                     out_group = Group,
                                     flags = Flags,
                                     table_id = TableId,
                                     match = Match},
            ets:insert(Tid, Monitor),
            Updates = 
                case ?is_flag_set(initial, Flags) of
                    true ->
                        monitor_current_flows(SwitchId, Monitor);
                    false ->
                        []
                end,
            ?DEBUG("returning initial flows: ~p", [Updates]),
            {reply, {ok, #ofp_flow_monitor_reply{flags = [],
                                                 updates = Updates}}, State};
        _ ->
            {reply, {error, {flow_monitor_failed, monitor_exists}}, State}
    end;
%% Monitor modification
handle_call({modify, MonitorId, Port, Group, Flags, TableId, Match,
             #monitor_data{client_pid = ClientPid}}, 
            _From, #state{switch_id = SwitchId} = State) ->
    Tid = linc:lookup(SwitchId, ?TABLE_NAME),
    case ets:lookup(Tid, {ClientPid, MonitorId}) of
        [] ->
            ?ERROR("No monitor with Id ~p for client ~p: available monitors: ~p", 
                        [MonitorId, ClientPid, list_monitors(SwitchId)]),
            {reply, {error, {flow_monitor_failed, unknown_monitor}}, State};
        _ ->
            ets:insert(Tid,
                       #monitor_entry{id = {ClientPid, MonitorId},
                                      out_port = Port,
                                      out_group = Group,
                                      flags = Flags,
                                      table_id = TableId,
                                      match = Match}),
            {reply, {ok, #ofp_flow_monitor_reply{flags = [],
                                                 updates = []}}, State, 0}
    end;
%% Monitor deletion
handle_call({delete, MonitorId, _Port, _Group, _Flags, _TableId, _Match,
             #monitor_data{client_pid = ClientPid}}, 
            _From, #state{switch_id = SwitchId} = State) ->
    %% No multiple matches needed, just delete by id
    Tid = linc:lookup(SwitchId, ?TABLE_NAME),
    case ets:lookup(Tid, {ClientPid, MonitorId}) of
        [] ->
            ?ERROR("No monitor with Id ~p for client ~p: available monitors: ~p", 
                        [MonitorId, ClientPid, list_monitors(SwitchId)]),
            {reply, {error, {flow_monitor_failed, unknown_monitor}}, State, 0};
        _ ->
            ets:delete(Tid, {ClientPid, MonitorId}),
            {reply, {ok, #ofp_flow_monitor_reply{flags = [],
                                                 updates = []}}, State, 0}
    end;
%% Empty queue before returning: barrier request received
handle_call(sync, From, State) ->
    case queue_out(State) of
        {continue, State2} ->
            handle_call(sync, From, State2);
        {empty, State2} ->
            {reply, ok, State2}
    end.


%% Monitor event
handle_cast({monitor, Event, TableId, #monitor_data{client_pid = OClientPid, 
                                                    xid        = Xid,
                                                    reason     = Reason}, Flow}, 
            #state{switch_id = SwitchId} = State) ->
    Tid = linc:lookup(SwitchId, ?TABLE_NAME),
    Monitors = lists:keysort(1, ets:tab2list(Tid)),
    ?DEBUG("monitors: ~p", [Monitors]),
    Notifs = match_any(Event, OClientPid, TableId, Flow, Monitors),
    ?DEBUG("matches: ~p", [Notifs]),
    State2 = lists:foldl(
               fun({MClientPid, Abbrev, Instr}, State3) ->
                       add_flow_update(MClientPid, OClientPid, Event, TableId, 
                                           Abbrev, Instr, Reason, Xid, Flow, State3)
               end,
               State,
               Notifs),
    {noreply, State2, 0};
%% Start of a batch operation (modify/remove matching flows): 
handle_cast({batch_start, Command, #monitor_data{client_pid = ClientPid, 
                                               xid        = Xid}}, State) ->
    ?DEBUG("batch started"),
    State2 = submit_batch(State),
    %% Convert ofp_flow_mod:command to ofp_flow_update*.event
    Event = command_to_event(Command),
    {noreply, State2#state{batch = {ClientPid, Xid, Event}, batch_notifs = dict:new()} , 0};
%% Close and submit a batch of flow updates
handle_cast(batch_end, State) ->
    ?DEBUG("batch ended"),
    {noreply, submit_batch(State), 0}.


%% Process queue in spare time
handle_info(timeout, State) ->
    case queue_out(State) of
        {continue, State2} ->
            {noreply, State2, 0};
        {empty, State2} ->
            {noreply, State2}
    end;
handle_info(_Info, State) ->
    {noreply, State, 0}.

terminate(_Reason, #state{switch_id = SwitchId}) ->
    delete_table(SwitchId),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%==============================================================================
%% Internal functions
%%==============================================================================

server(SwitchId) ->
    list_to_atom(lists:concat([?MODULE, '_', SwitchId])). 

%% @doc Create ETS table for monitor entries
-spec create_table(integer()) -> integer().
create_table(SwitchId) ->
    Tid = ets:new(?TABLE_NAME, [ordered_set, public,
                                {keypos, #monitor_entry.id},
                                {read_concurrency, true}]),
    linc:register(SwitchId, ?TABLE_NAME, Tid),
    Tid.

delete_table(SwitchId) ->
    ets:delete(linc:lookup(SwitchId, ?TABLE_NAME)).


%%------------------------------------------------------------------------------
%% Monitor matching
%%------------------------------------------------------------------------------

monitor_current_flows(SwitchId, Monitor) ->
    TableIds = 
        case Monitor#monitor_entry.table_id of
            all ->
                lists:seq(0, ?OFPTT_MAX); 
            Tid ->
                [Tid]
        end,
    lists:flatten(
      [[case match(initial, TableId, true, Flow, Monitor) of
            {_, Abbrev, Instr} ->
                flow_update(SwitchId, initial, TableId, Abbrev, Instr,  
                            idle_timeout, 0, Flow);
            false ->
                ok
        end 
        || Flow <- ets:tab2list(linc_us5_flow:flow_table_ets(
                                  SwitchId, TableId))] 
       || TableId <- TableIds]).

match_any(Event, ClientPid, TableId, Flow, Monitors) ->
    lists:foldl(
      fun(Monitor, Acc) ->
              {MClientPid, _MonId} = Monitor#monitor_entry.id,
              IsOwner = MClientPid =:= ClientPid,
              case match(Event, TableId, IsOwner, Flow, Monitor) of
                  false ->
                      Acc;
                  Value ->
                      accumulate(Value, Acc)
              end
      end,
      [],
      Monitors).

-spec match(ofp_flow_update_event(), integer(), boolean(), #flow_entry{}, 
            #monitor_entry{}) -> {value, boolean(), boolean()} | false.
match(Event, TableId, IsOwner, Flow, 
      #monitor_entry{id = {ClientPid, _MonitorId}, 
                     out_port = MPort,
                     out_group = MGroup,
                     flags = Flags,
                     table_id = MTableId,
                     match = Match}) ->
    case event_match(Event, Flags)
        andalso owner_match(IsOwner, Flags)
        andalso table_match(MTableId, TableId) 
        andalso linc_us5_flow:non_strict_match(Flow, Match#ofp_match.fields)
        andalso linc_us5_flow:port_and_group_match(
                  MPort, MGroup, Flow#flow_entry.instructions) of
        true ->
            Abbrev = case IsOwner of
                         true ->
                             not ?is_flag_set(no_abbrev, Flags);
                         false ->
                             false
                     end,
            ShowInstr = ?is_flag_set(instructions, Flags),
            {ClientPid, Abbrev, ShowInstr};
        false ->
            false
    end.

accumulate({ClientPid, Abbrev, Instr} = Value, Acc) ->
    case lists:keyfind(ClientPid, 1, Acc) of
        {_, Abbrev2, Instr2} ->
            lists:keyreplace(ClientPid, 1, Acc, 
                             {ClientPid, Abbrev and Abbrev2, Instr or Instr2});
        false ->
            [Value | Acc]
    end.

event_match(initial, Flags) ->
    ?is_flag_set(initial, Flags);
event_match(added, Flags) ->
    ?is_flag_set(add, Flags);
event_match(removed, Flags) ->
    ?is_flag_set(removed, Flags);
event_match(modified, Flags) ->
    ?is_flag_set(modify, Flags).

owner_match(true, _) ->
    true;
owner_match(false, Flags) ->
    not ?is_flag_set(only_own, Flags).

table_match(MTabId, TabId) ->
    case MTabId of
        all ->
            true;
        TabId ->
            true;
        _ ->
            false
    end.

%%------------------------------------------------------------------------------
%% Batch handling
%%------------------------------------------------------------------------------

add_flow_update(MClientPid, OClientPid, Event, TableId, Abbrev, Instr, Reason, 
                Xid, Flow, 
                #state{switch_id    = SwitchId,
                       batch        = Batch} = State) ->
    Update = flow_update(SwitchId, Event, TableId, Abbrev, Instr, Reason, 
                         Xid, Flow),
    ?DEBUG("prepared flow update ~p, batch: ~p", [Update, Batch]),

    FlowId = Flow#flow_entry.id, 
    case drop_during_pause(Event, FlowId, State) of
        true ->
            %% In paused mode, modification updates to flow created
            %% during the pause must be dropped
            State;
        false ->
            case Batch of 
                off ->
                    %% No batch on: add to queue
                    Notif = #notification{type       = Event,
                                          flow_id    = FlowId,
                                          client_pid = MClientPid,
                                          updates    = [Update]},
                    queue_in(Notif, State);
                _ ->
                    update_batch(MClientPid, OClientPid, Event, 
                                 Xid, FlowId, Update, State)
            end
    end.

update_batch(MClientPid, OClientPid, Event, Xid, FlowId, Update, 
             #state{batch        = Batch,
                    batch_notifs = BNotifs} = State) ->
    {OClientPid2, Xid2, Event2} = Batch,
    %% Batch mode: check if still the same batch: same 
    %% operating client xid, respectively. We do not compare 
    %% events as modify may cause add + remove events
    case OClientPid =:= OClientPid2 
        andalso Xid =:= Xid2 of
        true ->
            %% Same batch: append
            ?DEBUG("Appending to batch"),
            BNotifs2 = append_to_batch(MClientPid, Event, FlowId, Update, BNotifs),
            State#state{batch_notifs = BNotifs2};
        _ ->
            %% Another batch: submit batch and this update separately
            ?DEBUG("submitting old batch, starting new one"),
            State2 = submit_batch(State),
            ?ERROR("Batch of flow updates terminated unexpectedly:\n"
                   "  prev/current events: ~p, ~p\n"
                   "  client pids of operation: ~p, ~p\n"
                   "  xids: ~p, ~p\n",
                   [Event, Event2, OClientPid, OClientPid2, Xid, Xid2]),
            Notif = #notification{type       = Event,
                                  flow_id    = FlowId,
                                  client_pid = MClientPid,
                                  updates    = [Update]},
            queue_in(Notif, State2)
    end.

submit_batch(#state{batch = off} = State) ->
    State;
submit_batch(#state{batch_notifs = Notifs} = State) ->
    State2 = State#state{batch        = off,
                         batch_notifs = dict:new()},
    case dict:size(Notifs) of
        0 ->
            %% Empty bach: no matches
            State2;
        _ ->
            lists:foldl(fun({_, Notif}, State3) ->
                                queue_in(Notif, State3)
                        end,
                        State2,
                        dict:to_list(Notifs))
    end.

append_to_batch(MClientPid, Event, FlowId, Update, Notifs) ->
    dict:update(MClientPid, 
                fun(#notification{updates = Updates} = Notif) ->
                        %% (Updates reversed when sent to client)
                        Notif#notification{updates = [Update | Updates]}
                end,
                #notification{type       = Event,
                              flow_id    = FlowId,
                              client_pid = MClientPid,
                              updates    = [Update]},
                Notifs).

drop_during_pause(modified, FlowId, #state{paused = true,
                                           store = S}) ->
    Added = queue:filter(find_added(FlowId), S),
    case queue:len(Added) of
        0 ->
            %% Flow created before pause
            false;
        _ ->
            %% In paused mode, drop 'modified' updates of 
            %% flows created during the pause
            ?DEBUG("paused: discarding \'modify\' flow update "
                   "as flow added by ~p", [Added]),
            true
    end;
drop_during_pause(_, _, _) ->
    %% Keep all others
    false.

%%------------------------------------------------------------------------------
%% Flow updates
%%------------------------------------------------------------------------------

flow_update(SwitchId, Event, TableId, Abbrev, Instr, Reason, Xid, 
            Flow) ->
    case Abbrev of
        false ->
            %% No abbrev for any events
            flow_update_full(Event, SwitchId, TableId, Instr, Reason, Flow);
        true ->
            flow_update_abbrev(Xid)
    end.

flow_update_full(Event, SwitchId, TableId, ShowInstructions, Reason, Flow) ->
    Tid = linc:lookup(SwitchId, flow_timers),
    FlowId = Flow#flow_entry.id,
    Now = os:timestamp(),
    {ITo, HTo} = case ets:lookup(Tid, FlowId) of
                     [#flow_timer{id = FlowId, table = TableId, 
                                  expire = Expire, remove = Remove}] ->
                         {calc_remaining(Expire, Now), 
                          calc_remaining(Remove, Now)};
                     _ ->
                         %% Shall not happen
                         {0, 0}
                 end,
    #ofp_flow_update_full{
                   event = Event,
                   table_id = TableId,
                   reason = case Event of
                                removed ->
                                    Reason;
                                _ ->
                                    idle_timeout
                            end,
                   idle_timeout = ITo,
                   hard_timeout = HTo,
                   priority = Flow#flow_entry.priority,
                   cookie = Flow#flow_entry.cookie,
                   match = Flow#flow_entry.match,
                   instructions = case ShowInstructions of
                                      true ->
                                          Flow#flow_entry.instructions;
                                      false ->
                                          []
                                  end}.

flow_update_abbrev(Xid) ->
    #ofp_flow_update_abbrev{
                    event = abbrev,
                    xid = Xid}.

flow_update_paused(Event) when Event =:= paused; 
                               Event =:= resumed ->
    #ofp_flow_update_paused{event = Event}.

calc_remaining(TsTimeout, Now) ->
    max(timer:now_diff(TsTimeout, Now) div 1000000, 0).

%%------------------------------------------------------------------------------
%% Buffer handling
%%------------------------------------------------------------------------------

queue_in(Notif, #state{queue_limit = QLimit,
                       paused = false, 
                       buffer = B} = State) ->
    B2 = queue:in(Notif, B),
    State2 = State#state{buffer = B2},
    case queue:len(B2) >= QLimit of
        true ->
            ?DEBUG("Buffer length exceeds limit (~p): ~p pausing", [QLimit, B2]),
            pause(State2);
        false ->
            %%?DEBUG("queue_in: buffer: ~p", [B2]),
            State2
    end;
queue_in(#notification{type = removed, flow_id = FlowId} = Notif, 
         #state{paused = true, 
                buffer = B,
                store  = S} = State) ->
    B2 = queue:in(Notif, B),
    S2 = queue:filter(remove_adds_and_mods(FlowId), S),
    ?DEBUG("paused: letting through \'removed\' flow update"),
    State#state{buffer = B2, store = S2};
queue_in(Notif, #state{paused = true, 
                       store = S} = State) ->
    %% 'add' or 'modified' type: store
    S2 = queue:in(Notif, S),
    ?DEBUG("paused: storing \'add\' or '\modified\' flow update"),
    State#state{store = S2}.

queue_out(#state{paused = Paused,
                 buffer = B} = State) ->
    case queue:out(B) of
        {{value, #notification{client_pid = ClientPid, 
                               updates    = Updates}}, B2} ->
            ?DEBUG("submitting updates ~p", [Updates]),
            case is_list(Updates) of
                true ->
                    send(ClientPid, lists:reverse(Updates));
                false ->
                    %% pause/resume
                    send(ClientPid, Updates)
            end,
            {continue, State#state{buffer = B2}};
        {empty, B2} ->
            ?DEBUG("queue empty"),
            case Paused of
                true ->
                    ?DEBUG("resuming"),
                    {empty, resume(State#state{buffer = B2})};
                false ->
                    {empty, State#state{buffer = B2}}
            end
    end.

pause(#state{paused    = false,
             switch_id = SwitchId,
             buffer    = B} = State) ->
    %% Send OFPFME_PAUSED to all clients owning monitors
    ClientPids = get_subscribed_clients(SwitchId),
    B2 =
        lists:foldl(fun(ClientPid, B3) ->
                            queue:in(#notification{type = paused,
                                                   client_pid = ClientPid,
                                                   updates = 
                                                       flow_update_paused(paused)}, 
                                     B3)
                    end,
                    B,
                    ClientPids),
    State#state{paused = true,
                buffer = B2}.

resume(#state{paused      = true,
              queue_limit = QLimit,
              switch_id   = SwitchId,
              buffer      = B, 
              store       = S} = State) ->
    %% Send OFPFME_RESUMED and all stored notifs to all clients owning monitors 
    %% FIXME: what if this pauses buffer
    ClientPids = get_subscribed_clients(SwitchId),
    {Send, Keep} = 
        case queue:len(S) of
            L when L >= QLimit ->
                ?ERROR("Monitor buffer reached its limit again "
                       "upon resume: increase buffer limit! "
                       "Current value (~p) exceeds stored flow "
                       "updates: ~p", [QLimit, L]),
                queue:split(max(QLimit - ClientPids - 1, 0), S);
            _ ->
                {S, queue:new()}
        end,

    B2 = 
        lists:foldl(fun(ClientPid, B3) ->
                            queue:in(#notification{type = resumed,
                                                   client_pid = ClientPid,
                                                   updates = 
                                                       flow_update_paused(resumed)},
                                     B3)
                    end,
                    B,
                    ClientPids),
    B3 = queue:join(B2, Send),
    %% Provoke checking the buffer
    self() ! timeout,
    ?DEBUG("queued \'resumed\' flow update, adding withheld updates: "
           "~p, ~nnew buffer: ~p", [Send, B3]),
    State#state{paused = false,
                buffer = B3,
                store  = Keep}.

get_subscribed_clients(SwitchId) ->
    Tid = linc:lookup(SwitchId, ?TABLE_NAME),
    lists:usort(lists:sort([ClientId || 
                               #monitor_entry{id = {ClientId, _}} <- 
                                   ets:tab2list(Tid)])).
multipart_message(Updates) ->
    #ofp_message{version = ?VERSION,
                 type    = ofp_multipart_reply,
                 xid     = 0,
                 %% ofp_message_body() == ofp_multipart_reply() == ofp_flow_monitor_reply()
                 body    = #ofp_flow_monitor_reply{flags = [],
                                                   updates = Updates}
                }.

send(ClientPid, Updates) ->
    Msg = multipart_message(Updates),
    ofp_client:send(ClientPid, Msg).

remove_adds_and_mods(FlowId) ->
    fun(#notification{type    = Type,
                      flow_id = FlowId2}) when Type =:= added;
                                               Type =:= modified -> 
            FlowId2 =/= FlowId;
       (_) -> 
            true
    end.

find_added(FlowId) ->
    fun(#notification{type    = added,
                      flow_id = FlowId2}) -> FlowId2 =:= FlowId;
       (_)                                -> false
    end.

command_to_event(add) -> added;
command_to_event(modify) -> modified;
command_to_event(modify_strict) -> modified;
command_to_event(delete) -> removed;
command_to_event(delete_strict) -> removed.
