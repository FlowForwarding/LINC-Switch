%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc OpenFlow Channel module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofc_logic).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([register_receiver/1, unregister_receiver/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("of_protocol/include/of_protocol.hrl").

-record(receiver, {
          pid :: pid(),
          role = equal :: role()
         }).

-record(state, {
          receivers = [] :: [#receiver{}]
         }).

-type role() :: master | slave | equal.

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the OF Channel gen_server.
-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Register receiver.
-spec register_receiver(pid()) -> any().
register_receiver(Pid) ->
    gen_server:cast(?MODULE, {register, Pid}).

%% @doc Unregister receiver.
-spec unregister_receiver(pid()) -> any().
unregister_receiver(Pid) ->
    gen_server:cast(?MODULE, {unregister, Pid}).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

init([]) ->
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({register, Pid}, State = #state{receivers = Receivers}) ->
    Receiver = #receiver{pid = Pid},
    {noreply, State#state{receivers = [Receiver | Receivers]}};
handle_cast({unregister, Pid}, State = #state{receivers = Receivers}) ->
    NewReceivers = lists:keydelete(Pid, #receiver.pid, Receivers),
    {noreply, State#state{receivers = NewReceivers}};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({message, From, #echo_request{header = #header{xid = Xid},
                                          data = Data}}, State) ->
    ofc_receiver:send(From, #echo_reply{header = #header{xid = Xid},
                                        data = Data}),
    {noreply, State};
handle_info({message, From, Message},
            State = #state{receivers = Receivers}) ->
    _Receiver = lists:keyfind(From, #receiver.pid, Receivers),
    %% TODO: Do something about that message.
    error_logger:info_msg("Received message from controller (~p): ~p~n",
                          [From, Message]),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
