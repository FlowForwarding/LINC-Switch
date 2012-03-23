%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc Receiver module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofc_receiver).

-behaviour(gen_server).

%% API
-export([start_link/2]).
-export([send/2, set_version/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("of_protocol/include/of_protocol.hrl").

-record(state, {
          parent :: pid(),
          version :: integer(),
          socket,
          parser :: #parser{}
         }).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the receiver.
-spec start_link(pid(), any()) -> {ok, pid()}.
start_link(Parent, Controller) ->
    {ok, Pid} = gen_server:start_link(?MODULE, {Parent, Controller}, []),
    ofc_logic:register_receiver(Pid),
    {ok, Pid}.

send(Receiver, Message) ->
    gen_server:cast(Receiver, {send, Message}).

set_version(Receiver, Version) ->
    gen_server:cast(Receiver, {version, Version}).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

init({Parent, Controller}) ->
    Opts = [binary, {active, once}],
    {ok, Socket} = gen_tcp:connect(Controller, 6633, Opts),
    {ok, Parser} = ofp_parser:new_parser(),
    {ok, #state{parent = Parent, socket = Socket, parser = Parser}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({send, Message}, State = #state{socket = Socket}) ->
    case of_protocol:encode(Message) of
        {ok, EncodedMessage} ->
            gen_tcp:send(Socket, EncodedMessage);
        {error, _ } ->
            ok
    end,
    {noreply, State};
handle_cast({version, Version}, State) ->
    {noreply, State#state{version = Version}};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({tcp, Socket, Data}, State = #state{parent = Parent,
                                                version = Version,
                                                socket = Socket,
                                                parser = Parser}) ->
    inet:setopts(Socket, [{active, once}]),
    {ok, NewParser, Messages} = ofp_parser:parse(Parser, Data),
    lists:foreach(fun(Message) ->
                          case Version of
                              undefined ->
                                  Parent ! {message, self(), Message};
                              _ ->
                                  ofc_logic ! {message, self(), Message}
                          end
                  end, Messages),
    {noreply, State#state{parser = NewParser}};
handle_info({tcp_closed, Socket}, State = #state{socket = Socket}) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{socket = Socket}) ->
    gen_tcp:close(Socket),
    ofc_logic:unregister_receiver(self()),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
