%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc Module for handling the connection to the Controller.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofc_connection).

-behaviour(gen_fsm).

%% API
-export([start_link/1]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

-include_lib("of_protocol/include/of_protocol.hrl").

-record(state, {
          receiver :: pid()
         }).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the receiver.
-spec start_link(any()) -> {ok, pid()}.
start_link(Controller) ->
    gen_fsm:start_link(?MODULE, Controller, []).

%%%-----------------------------------------------------------------------------
%%% gen_fsm callbacks
%%%-----------------------------------------------------------------------------

init(Controller) ->
    {ok, Pid} = ofc_receiver:start_link(self(), Controller),
    ofc_receiver:send(Pid, #hello{header = #header{xid = 1}}),
    {ok, hello, #state{receiver = Pid}}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, ok, StateName, State}.

handle_info({message, Receiver, Hello = #hello{}}, hello,
            State = #state{receiver = Receiver}) ->
    case decide_on_version(Hello) of
        failed ->
            ofc_receiver:send(Receiver, #error_msg{header = #header{xid = 2},
                                                   type = hello_failed,
                                                   code = incompatible}),
            {stop, hello_failed, State};
        {NextState, Version} ->
            ofc_receiver:set_version(Receiver, Version),
            {next_state, NextState, State}
    end;

handle_info({message, Receiver, #error_msg{}}, wait,
            State = #state{receiver = Receiver}) ->
    {stop, hello_failed, State};
handle_info({message, Receiver, Message}, wait,
            State = #state{receiver = Receiver}) ->
    ofc_logic ! {message, Receiver, Message},
    {next_state, forward, State};
handle_info({message, Receiver, Message}, forward,
            State = #state{receiver = Receiver}) ->
    ofc_logic ! {message, Receiver, Message},
    {next_state, loop, State};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVersion, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

decide_on_version(#hello{header = #header{version = ReceivedVersion}}) ->
    %% TODO: Get supported version from switch configuration.
    SupportedVersions = [3],
    ProposedVersion = lists:max(SupportedVersions),
    if
        ProposedVersion > ReceivedVersion ->
            case lists:member(ReceivedVersion, SupportedVersions) of
                true ->
                    {forward, ReceivedVersion};
                false ->
                    failed
            end;
        ProposedVersion < ReceivedVersion ->
            {wait, ProposedVersion};
        true ->
            {forward, ProposedVersion}
    end.
