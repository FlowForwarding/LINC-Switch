%%%-------------------------------------------------------------------
%%% @author Konrad Kaplita <konrad.kaplita@erlang-solutions.com>
%%% @copyright (C) 2012, Konrad Kaplita
%%% @doc
%%%
%%% @end
%%% Created :  4 Apr 2012 by Konrad Kaplita <konrad.kaplita@erlang-solutions.com>
%%%-------------------------------------------------------------------
-module(ofs_userspace_physical_port).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init(list()) -> {ok, #state{}} |
                      {ok, #state{}, timeout()} |
                      ignore |
                      {stop, Reason :: term()}.
init([]) ->
    {ok, #state{}}.

-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()}, #state{}) ->
                         {reply, Reply :: term(), #state{}} |
                         {reply, Reply :: term(), #state{}, timeout()} |
                         {noreply, #state{}} |
                         {noreply, #state{}, timeout()} |
                         {stop, Reason :: term() , Reply :: term(), #state{}} |
                         {stop, Reason :: term(), #state{}}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(Msg :: term(), #state{}) -> {noreply, #state{}} |
                                              {noreply, #state{}, timeout()} |
                                              {stop, Reason :: term(), #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(Info :: term(), #state{}) -> {noreply, #state{}} |
                                               {noreply, #state{}, timeout()} |
                                               {stop, Reason :: term(), #state{}}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(Reason :: term(), #state{}) -> none().
terminate(_Reason, _State) ->
    ok.

-spec code_change(Vsn :: term() | {down, Vsn :: term()}, #state{}, Extra :: term()) ->
                         {ok, #state{}} |
                         {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
