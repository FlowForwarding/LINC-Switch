%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc OpenFlow Channel receiver module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofc_receiver).

-behaviour(gen_server).

%% API
-export([start_link/2, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("of_protocol/include/of_protocol.hrl").

-record(state, {
          socket :: port(),
          parser :: #parser{}
         }).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the receiver.
-spec start_link(any(), integer()) -> {ok, pid()}.
start_link(Controller, Port) ->
    gen_server:start_link(?MODULE, {Controller, Port}, []).

%% @doc Stop the receiver.
-spec stop(pid()) -> any().
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

init({Controller, Port}) ->
    Opts = [binary, {active, once}],
    case gen_tcp:connect(Controller, Port, Opts) of
        {ok, Socket} ->
            ofc_logic:register_receiver(self(), Socket),
            {ok, Parser} = ofp_parser:new(),
            {ok, #state{socket = Socket, parser = Parser}};
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
                          ofc_logic:message(Message, self())
                  end, Messages),
    {noreply, State#state{parser = NewParser}};
handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, normal, State};
handle_info({tcp_error, Socket, _Reason}, #state{socket = Socket} = State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{socket = Socket}) ->
    gen_tcp:close(Socket),
    ofc_logic:unregister_receiver(self()),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
