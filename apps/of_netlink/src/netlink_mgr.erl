%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Grzegorz Stanislawski <grzegorz.stanislawski@erlang-solutions.com>
%%% @doc Linux Netlink interface library module. Netlink Socket Mgr
%%% @end
%%%-----------------------------------------------------------------------------
-module(netlink_mgr).
-behaviour(gen_server).
-include("netlink_rec.hrl").
%-include_lib("procket/include/procket.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-record(state, {
        sock,
        port,
        sock_pid,
        seq = 0,
        dp_id = undefined,
        vp_id = undefined,
        fl_id = undefined,
        pk_id = undefined,
        reqs=[]
         }).

%%%===================================================================
%%% API
%%%===================================================================
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    case netlink_meck:procket_open(0,[{protocol,16},{type,raw},{family,16}]) of
        {error,eperm} -> {stop, {error,eperm}};
        {ok,Sock} ->
            Port=netlink_meck:port_open({fd, Sock, Sock}, [stream, binary]),
            SA=#sockaddr_nl{family = ?AF_NETLINK, pid=0}, % pid=0 means destination is kernel
            ok=netlink_meck:procket_connect(Sock,of_netlink:encode(SA)),
            error_logger:info_msg("[~p] started pid=~p~n",[?MODULE,self()]),
            {ok, #state{sock=Sock, port=Port,
                        sock_pid=0, seq=0
            }}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------

handle_call({sendpkt,Packet},From, State) ->
    error_logger:info_msg("[~p] sendpkt (call):~n~p~n",
        [?MODULE,Packet]),
    NewState=send_packet(Packet,From,State),
    error_logger:info_msg("[~p] sendpkt call from ~p: ~p~nNewState: ~p~n",
        [?MODULE, From, Packet, State]),
    {noreply, NewState};

handle_call({set,ovs_datapath,Id}, From, State) ->
    error_logger:info_msg("[~p] ovs_datapath family id set rq from ~p Id=~p~nwhen in state: ~p~n",
        [?MODULE, From,Id, State]),
    {reply, ok, State#state{dp_id=Id}};

handle_call({set,ovs_vport,Id}, From, State) ->
    error_logger:info_msg("[~p] ovs_vport family id set rq from ~p Id=~p~nwhen in state: ~p~n",
        [?MODULE, From,Id, State]),
    {reply, ok, State#state{vp_id=Id}};

handle_call({set,ovs_flow,Id}, From, State) ->
    error_logger:info_msg("[~p] ovs_flow family id set rq from ~p Id=~p~nwhen in state: ~p~n",
        [?MODULE, From,Id, State]),
    {reply, ok, State#state{fl_id=Id}};

handle_call({set,ovs_packet,Id}, From, State) ->
    error_logger:info_msg("[~p] ovs_packet family id set rq from ~p Id=~p~nwhen in state: ~p~n",
        [?MODULE, From,Id, State]),
    {reply, ok, State#state{pk_id=Id}};

handle_call(stop, From, State) ->
    error_logger:info_msg("[~p] Stop request from  ~p~nwhen in state: ~p~n",
        [?MODULE, From, State]),
    {stop,normal,ok,State};

handle_call(Request, From, State) ->
    error_logger:info_msg("[~p] unhandled call from ~p: ~p~nwhen in state: ~p~n",
        [?MODULE, From,Request, State]),
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------

handle_cast({sendpkt,Pid, Packet},State) ->
    NewState=send_packet(Packet, Pid, State),
    error_logger:info_msg("[~p] sendpkt cast pid=~p: ~p~n NewState: ~p~n",
        [?MODULE, Pid, Packet, NewState]),
    {noreply, NewState};

handle_cast(Request, State) ->
    error_logger:info_msg("[~p] unhandled cast: ~p~nwhen in state: ~p~n",
        [?MODULE, Request, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
handle_info({Port,{data,Data}},State=#state{port=Port,dp_id=Dp,vp_id=Vp,fl_id=Fl,pk_id=Pk}) ->
    error_logger:info_msg("[~p] data from Port msg=~n~p~nwhen in state: ~p~n",
        [?MODULE,Data,State]),
    {noreply, receive_packet(of_netlink:decode(Data,Dp,Vp,Fl,Pk),State)};

handle_info(Request, State) ->
    error_logger:info_msg("[~p] unhandled msg: ~p~nwhen in state: ~p~n",
        [?MODULE, Request, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------

terminate(Reason, State=#state{sock=Sock}) ->
    error_logger:info_msg("[~p] terminate: ~p~nwhen in state: ~p", [?MODULE, Reason, State]),
    netlink_meck:procket_close(Sock),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%%%===================================================================
%%% Internal functions
%%%===================================================================

send_packet(Binary, _, State) when is_binary(Binary)->
    netlink_meck:port_send(State#state.port, Binary),
    State;

send_packet(Packet=#nlmsg{pid=undefined}, From, State=#state{sock_pid=Pid})->
    send_packet(Packet#nlmsg{pid=Pid},From, State);

send_packet(Packet=#nlmsg{seq=undefined},From, State=#state{seq=Seq})->
    send_packet(Packet#nlmsg{seq=Seq},From, State#state{seq=Seq+1});

send_packet(Packet=#nlmsg{request=0,seq=Seq}, From, 
        State=#state{reqs=Reqs})->
%if this is not request we probable shouldn't store sender info as we will not
%get ther reply.
    State1=State#state{reqs=Reqs ++ [{Seq, {From, Packet}}]},
    send_packet(of_netlink:encode(Packet), From, State1);

send_packet(Packet=#nlmsg{request=1,seq=Seq},From, 
        State=#state{reqs=Reqs})->
    State1=State#state{reqs=Reqs ++ [{Seq, {From, Packet}}]},
    send_packet(of_netlink:encode(Packet),From, State1).


receive_packet(Binary,State) when is_binary(Binary) ->
    error_logger:info_msg("[~p] receive_packet cant decode packet=~n~p~n",
            [?MODULE,Binary]),
    State;

receive_packet(Packet=#nlmsg{seq=Seq},State=#state{reqs=Reqs}) ->
    error_logger:info_msg("[~p] data from Port msg=~n~p~n",
            [?MODULE,Packet]),
%    Subs=proplists:get_all_values(Seq,Reqs),
    {From, _}=proplists:get_value(Seq,Reqs,{undefined,undefined}),
    case From of
        undefined            -> ok; %do nothing
        Pid when is_pid(Pid) -> Pid ! {netlink_reply,Packet};
        From                 -> gen_server:reply(From,Packet)
    end,
    NewReqs=proplists:delete(Seq,Reqs),
    State#state{reqs=NewReqs}.
