%%%-----------------------------------------------------------------------------
%%% Use is subject to License terms.
%%% @copyright (C) 2012 FlowForwarding.org
%%% @doc OpenFlow Channel receiver module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(linc_receiver).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-behaviour(gen_server).

%% API
-export([start_link/3, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("linc_us3.hrl").

-record(state, {
          socket :: port(),
          parser :: #ofp_parser{}
         }).

-define(SUPERVISOR, linc_receiver_sup).
-define(RECONNECT_TIMEOUT, timer:seconds(1)).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the receiver.
-spec start_link(atom(), any(), integer()) -> {ok, pid()}.
start_link(Id, Controller, Port) ->
    gen_server:start_link(?MODULE, {Id, Controller, Port}, []).

%% @doc Stop the receiver.
-spec stop(pid()) -> any().
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

init({Id, Controller, Port}) ->
    Opts = [binary, {active, once}],
    case gen_tcp:connect(Controller, Port, Opts) of
        {ok, Socket} ->
            linc_logic:register_receiver(self(), Socket),
            {ok, Parser} = ofp_parser:new(),

            Hello = #ofp_message{xid = 1, body = #ofp_hello{}},
            {ok, HelloBin} = of_protocol:encode(Hello),
            ok = gen_tcp:send(Socket, HelloBin),

            {ok, #state{socket = Socket, parser = Parser}};
        {error, econnrefused} ->
            timer:apply_after(?RECONNECT_TIMEOUT,
                              supervisor, restart_child, [?SUPERVISOR, Id]),
            ignore;
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({tcp, Socket, Data}, #state{socket = Socket,
                                        parser = Parser} = State) ->
    inet:setopts(Socket, [{active, once}]),
    {ok, NewParser, Messages} = ofp_parser:parse(Parser, Data),
    lists:foreach(fun(Message) ->
                          linc_logic:message(Message, self())
                  end, Messages),
    {noreply, State#state{parser = NewParser}};
handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, normal, State};
handle_info({tcp_error, Socket, _Reason}, #state{socket = Socket} = State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{socket = Socket}) ->
    linc_logic:unregister_receiver(self()),
    gen_tcp:close(Socket),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
