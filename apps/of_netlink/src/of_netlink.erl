%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Grzegorz Stanislawski <grzegorz.stanislawski@erlang-solutions.com>
%%% @doc Linux Netlink interface library module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_netlink).
-include("netlink_rec.hrl").
%% API
-export([encode/1,decode/5,decode_sockaddr_nl/1]).

%%%===================================================================
%%% External functions
%%%===================================================================
-spec encode(binary() | [] | nlmsg() | genlmsg() | sockaddr_nl()
        | ovsdpmsg() | ovsvpmsg() | ovsflmsg() |ovspkmsg()) -> binary().
encode(Binary) when is_binary(Binary) ->
    Binary;

encode([]) ->
    <<>>;

encode(#sockaddr_nl{family=Family,pid=Pid,groups=Groups}) ->
    <<Family:16/native-integer, 0:16/native-integer, 
      Pid:32/native-integer,Groups:32/native-integer>>;

encode(#genlmsg{cmd=Cmd,version=Ver,payload=Payload}) ->
    Data=encode_genl_nla(Payload,<<>>),
    <<Cmd:8/native-integer,Ver:8/native-integer,
      0:16/native-integer,Data/binary>>;

encode(#ovsdpmsg{cmd=Cmd,version=Ver,ifindex=IfIndex,payload=Payload}) ->
    Data=encode_ovsdp_nla(Payload,<<>>),
    <<Cmd:8/native-integer,Ver:8/native-integer,0:16/native-integer,
      IfIndex:32/native-integer, %this is ovs custom header
      Data/binary>>;

encode(#ovsvpmsg{cmd=Cmd,version=Ver,ifindex=IfIndex,payload=Payload}) ->
    Data=encode_ovsvp_nla(Payload,<<>>),
    <<Cmd:8/native-integer,Ver:8/native-integer,0:16/native-integer,
      IfIndex:32/native-integer, %this is ovs custom header
      Data/binary>>;

encode(#ovsflmsg{cmd=Cmd,version=Ver,ifindex=IfIndex,payload=Payload}) ->
    Data=encode_ovsfl_nla(Payload,<<>>),
    <<Cmd:8/native-integer,Ver:8/native-integer,0:16/native-integer,
      IfIndex:32/native-integer, %this is ovs custom header
      Data/binary>>;

encode(#ovspkmsg{cmd=Cmd,version=Ver,ifindex=IfIndex,payload=Payload}) ->
    Data=encode_ovspk_nla(Payload,<<>>),
    <<Cmd:8/native-integer,Ver:8/native-integer,0:16/native-integer,
      IfIndex:32/native-integer, %this is ovs custom header
      Data/binary>>;

encode(#nlmsg{len=Len,type=Type,request=R,multi=M,ack=A,echo=E,dumpintr=D,
              seq=Seq,pid=Pid,payload=Payload}) ->
    <<FlagsLo:8>> = <<0:3,D:1,E:1,A:1,M:1,R:1>>,
    FlagsHi=0, % flagsHi nod done yet, it depends on payload.
    Data=encode(Payload),
    L= case Len of
        undefined -> 16+size(Data);
        LL        -> LL
    end,
    <<L:32/native-integer,Type:16/native-integer,
      FlagsLo:8/native-integer,FlagsHi:8/native-integer,
      Seq:32/native-integer,Pid:32/native-integer,Data/binary>>.

-spec decode_sockaddr_nl(<<_:96>>) -> sockaddr_nl().
decode_sockaddr_nl(<<Family:16/native-integer, _:16/native-integer,
        Pid:32/native-integer,Groups:32/native-integer>>) ->
    #sockaddr_nl{family=Family,pid=Pid,groups=Groups}.

-spec decode(binary(),undefined | int16(),
                      undefined | int16(),
                      undefined | int16(),
                      undefined | int16()) -> nlmsg().
%netlink error 
decode(<<L:32/native-integer,2:16/native-integer,
         FlagsLo:1/binary,_FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>,_,_,_,_) ->
    <<_:3,D:1,E:1,A:1,M:1,R:1>> = FlagsLo,
    PayloadLen=L-16,
    %chop trailing 0's
    <<Data1:PayloadLen/binary,_/binary>>=Data,
    <<ErrCode:32/native-integer,Original/binary>> = Data1,
%    Payload={error,ErrCode,decode(Original)},
    Payload={error,ErrCode,Original},
    #nlmsg{len=L,type=?NETLINK_GENERIC,request=R,multi=M,ack=A,echo=E,
           dumpintr=D,seq=Seq,pid=Pid,payload=Payload};

decode(<<L:32/native-integer,?NETLINK_GENERIC:16/native-integer,
         FlagsLo:1/binary, _FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>,_,_,_,_) ->
    <<_:3,D:1,E:1,A:1,M:1,R:1>> = FlagsLo,
    PayloadLen=L-16,
    %chop trailing 0's
    <<Data1:PayloadLen/binary,_/binary>>=Data,
    Payload=decode_genl(Data1),
    #nlmsg{len=L,type=?NETLINK_GENERIC,request=R,multi=M,ack=A,echo=E,
           dumpintr=D,seq=Seq,pid=Pid,payload=Payload};

% ovs_datapath familyid packets
decode(<<L:32/native-integer,Dp:16/native-integer,
         FlagsLo:1/binary, _FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>,Dp,_,_,_) ->
    <<_:3,D:1,E:1,A:1,M:1,R:1>> = FlagsLo,
    PayloadLen=L-16,
    %chop trailing 0's
    <<Data1:PayloadLen/binary,_/binary>>=Data,
    Payload=decode_ovs_datapath(Data1),
    #nlmsg{len=L,type=Dp,request=R,multi=M,ack=A,echo=E,
           dumpintr=D,seq=Seq,pid=Pid,payload=Payload};

% ovs_vport familyid packets
decode(<<L:32/native-integer,Vp:16/native-integer,
         FlagsLo:1/binary, _FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>,_,Vp,_,_) ->
    <<_:3,D:1,E:1,A:1,M:1,R:1>> = FlagsLo,
    PayloadLen=L-16,
    %chop trailing 0's
    <<Data1:PayloadLen/binary,_/binary>>=Data,
    Payload=decode_ovs_vport(Data1),
    #nlmsg{len=L,type=Vp,request=R,multi=M,ack=A,echo=E,
           dumpintr=D,seq=Seq,pid=Pid,payload=Payload};

% ovs_flow familyid packets
decode(<<L:32/native-integer,Fl:16/native-integer,
         FlagsLo:1/binary, _FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>,_,_,Fl,_) ->
    <<_:3,D:1,E:1,A:1,M:1,R:1>> = FlagsLo,
    PayloadLen=L-16,
    %chop trailing 0's
    <<Data1:PayloadLen/binary,_/binary>>=Data,
    Payload=decode_ovs_flow(Data1),
    #nlmsg{len=L,type=Fl,request=R,multi=M,ack=A,echo=E,
           dumpintr=D,seq=Seq,pid=Pid,payload=Payload};

% ovs_packets familyid packets
decode(<<L:32/native-integer,Pk:16/native-integer,
         FlagsLo:1/binary, _FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>,_,_,_,Pk) ->
    <<_:3,D:1,E:1,A:1,M:1,R:1>> = FlagsLo,
    PayloadLen=L-16,
    %chop trailing 0's
    <<Data1:PayloadLen/binary,_/binary>>=Data,
    Payload=decode_ovs_packet(Data1),
    #nlmsg{len=L,type=Pk,request=R,multi=M,ack=A,echo=E,
           dumpintr=D,seq=Seq,pid=Pid,payload=Payload};

%default leave paload undecoded
decode(<<L:32/native-integer,Type:16/native-integer,
         FlagsLo:1/binary,_FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>,_,_,_,_) ->
    <<_:3,D:1,E:1,A:1,M:1,R:1>> = FlagsLo,
    PayloadLen=L-16,
    %chop trailing 0's
    <<Data1:PayloadLen/binary,_/binary>>=Data,
    #nlmsg{len=L,type=Type,request=R,multi=M,ack=A,echo=E,
           dumpintr=D,seq=Seq,pid=Pid,payload=Data1}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

%%%-------------------------------------------------------------------
%%% Generic Netlink message decoder
%%%-------------------------------------------------------------------
-spec decode_genl(binary()) -> {'error','no_genl'} | genlmsg().
decode_genl(<<>>) ->
    {error,no_genl};
decode_genl(<<Cmd:8/native-integer,Ver:8/native-integer,_:16/native-integer,
              Data/binary>>) ->
    Payload=decode_genl_nla(Data, []),
    #genlmsg{cmd=Cmd,version=Ver,payload=Payload}.

%%%-------------------------------------------------------------------
%%% OVS Datapath message decoder
%%%-------------------------------------------------------------------
%stub
-spec decode_ovs_datapath(binary()) -> ovsdpmsg().
decode_ovs_datapath(<<Cmd:8/native-integer,Ver:8/native-integer,_:16/native-integer,
                      IfIndex:32/native-integer, %this is ovs custom header
                      Data/binary>>) ->
    Payload=decode_ovsdp_nla(Data, []),
    #ovsdpmsg{cmd=Cmd,version=Ver,ifindex=IfIndex,payload=Payload}.

%stub
-spec decode_ovs_vport(binary()) -> ovsvpmsg().
decode_ovs_vport(<<Cmd:8/native-integer,Ver:8/native-integer,_:16/native-integer,
                      IfIndex:32/native-integer, %this is ovs custom header
                   Data/binary>>) ->
    Payload=decode_ovsvp_nla(Data, []),
    #ovsvpmsg{cmd=Cmd,version=Ver,ifindex=IfIndex,payload=Payload}.

%stub
-spec decode_ovs_flow(binary()) -> ovsflmsg().
decode_ovs_flow(<<Cmd:8/native-integer,Ver:8/native-integer,_:16/native-integer,
                  IfIndex:32/native-integer, %this is ovs custom header
                  Data/binary>>) ->
    Payload=decode_ovsfl_nla(Data, []),
    #ovsflmsg{cmd=Cmd,version=Ver,ifindex=IfIndex,payload=Payload}.

%stub
-spec decode_ovs_packet(binary()) -> ovspkmsg().
decode_ovs_packet(<<Cmd:8/native-integer,Ver:8/native-integer,_:16/native-integer,
                    IfIndex:32/native-integer, %this is ovs custom header
                    Data/binary>>) ->
    Payload=decode_ovspk_nla(Data, []),
    #ovspkmsg{cmd=Cmd,version=Ver,ifindex=IfIndex,payload=Payload}.

%%%-------------------------------------------------------------------
%%% attributes decoder helper functions
%%%-------------------------------------------------------------------
-spec nla_align(non_neg_integer()) -> non_neg_integer().
%nla_align(Len) -> (Len + ?NLA_ALIGNTO - 1) band bnot(?NLA_ALIGNTO - 1).
% reimplemented to make dialyzer happy
nla_align(Len) ->((Len + ?NLA_ALIGNTO - 1) div ?NLA_ALIGNTO)*?NLA_ALIGNTO.

-spec decode_nla_common(binary()) -> {int14(),bit(),bit(),int16(),binary(),binary()}.
decode_nla_common(<<Len:16/native-integer, Type:14/native-integer,O:1,N:1, Rest/binary>>) ->
    PayloadLen=Len-4,
    HdrPadLen=0, % should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    PayloadPadLen=nla_align(PayloadLen) -PayloadLen,
    % Len:16/native-integer already eaten
    <<_HdrPad:HdrPadLen/binary,
      Payload:PayloadLen/binary, _PayloadPad:PayloadPadLen/binary,
      Tail/binary>> = Rest,
    {Type,N,O,PayloadLen,Payload,Tail}.

-spec decode_nla_binary(binary()) -> {nla_attr(),binary()}.
decode_nla_binary(Nla) ->
    {Type,N,O,_PayloadLen,Payload,Tail}=decode_nla_common(Nla),
    {#nla_attr{type=Type,n=N,o=O,data=Payload},Tail}.

-spec decode_nla_string(binary()) -> {nla_attr(),binary()}.
decode_nla_string(Nla) ->
    {Type,N,O,PayloadLen,Payload,Tail}=decode_nla_common(Nla),
    L=PayloadLen-1,
    <<A:L/binary,0>>=Payload,
    {#nla_attr{type=Type,n=N,o=O,data=binary_to_list(A)},Tail}.

-spec decode_nla_integer(binary()) -> {nla_attr(),binary()}.
decode_nla_integer(Nla) ->
    {Type,N,O,PayloadLen,Payload,Tail}=decode_nla_common(Nla),
    PL=PayloadLen*8,
    <<A:PL/native-integer>> = Payload,
    {#nla_attr{type=Type,n=N,o=O,data=A},Tail}.

%%%-------------------------------------------------------------------
%%% Generic NetLink attributes decoder
%%%-------------------------------------------------------------------
-spec decode_genl_nla(binary(),[]|[nla_attr()]) -> [nla_attr()].
decode_genl_nla(<<>>,NlaList) ->
    NlaList;
decode_genl_nla(Nla= <<_Len:16/native-integer,?CTRL_ATTR_UNSPEC:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_binary(Nla),
    decode_genl_nla(Tail, NlaList ++ [Attr]);
decode_genl_nla(Nla= <<_Len:16/native-integer,?CTRL_ATTR_FAMILY_ID:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_genl_nla(Tail, NlaList ++ [Attr]);
decode_genl_nla(Nla= <<_Len:16/native-integer,?CTRL_ATTR_FAMILY_NAME:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_string(Nla),
    decode_genl_nla(Tail, NlaList ++ [Attr]);
decode_genl_nla(Nla= <<_Len:16/native-integer,?CTRL_ATTR_VERSION:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_genl_nla(Tail, NlaList ++ [Attr]);
decode_genl_nla(Nla= <<_Len:16/native-integer,?CTRL_ATTR_HDRSIZE:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_genl_nla(Tail, NlaList ++ [Attr]);
decode_genl_nla(Nla= <<_Len:16/native-integer,?CTRL_ATTR_MAXATTR:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_genl_nla(Tail, NlaList ++ [Attr]);
decode_genl_nla(     <<Len:16/native-integer,?CTRL_ATTR_OPS:14/native-integer,O:1,N:1,Rest/binary>>,NlaList) ->
    L=Len-4,
    <<This:L/binary,Tail/binary>>=Rest, 
    Attr=#nla_attr{type=?CTRL_ATTR_OPS,n=N,o=O,data=decode_nla_nested_ops(This,[])},
    decode_genl_nla(Tail, NlaList ++ [Attr]);
decode_genl_nla(     <<Len:16/native-integer,?CTRL_ATTR_MCAST_GROUPS:14/native-integer,O:1,N:1,Rest/binary>>,NlaList) ->
    L=Len-4,
    <<This:L/binary,Tail/binary>>=Rest,
    Attr=#nla_attr{type=?CTRL_ATTR_MCAST_GROUPS,n=N,o=O,data=decode_nla_nested_mcast(This,[])},
    decode_genl_nla(Tail, NlaList ++ [Attr]).

-spec decode_nla_nested_ops(binary(),[]|[{'nested_ops',int16(),nla_attr(),nla_attr()}]) -> [{'nested_ops',int16(),nla_attr(),nla_attr()}].
decode_nla_nested_ops(<<>>,Acc) ->
    Acc;
decode_nla_nested_ops(<<Len:16/native-integer,Num:16/native-integer,Rest/binary>>,Acc) ->
    L=Len-4,
    <<ThisElem:L/binary,NextElem/binary>>= Rest,
    {Attr1,ThisElem1}=decode_nla_integer(ThisElem),
    {Attr2,<<>>}=decode_nla_integer(ThisElem1),
%    {Attr2,ThisElem2}=decode_nla_integer(ThisElem1),
    decode_nla_nested_ops(NextElem, Acc ++ [{nested_ops,Num,Attr1,Attr2}]).
%NLA_PUT_U32(skb, CTRL_ATTR_OP_ID, ops->cmd);
%NLA_PUT_U32(skb, CTRL_ATTR_OP_FLAGS, ops->flags);

%mcast_groups
-spec decode_nla_nested_mcast(binary(),[]|[{'nested_mcast',int16(),nla_attr(),nla_attr()}]) -> [{'nested_mcast',int16(),nla_attr(),nla_attr()}].
decode_nla_nested_mcast(<<>>,Acc) ->
    Acc;
decode_nla_nested_mcast(<<Len:16/native-integer,Num:16/native-integer,Rest/binary>>,Acc) ->
    L=Len-4,
    <<ThisElem:L/binary,NextElem/binary>>= Rest,
    {Attr1,ThisElem1}=decode_nla_integer(ThisElem),
    {Attr2,<<>>}=decode_nla_string(ThisElem1),
%    {Attr2,ThisElem2}=decode_nla_string(ThisElem1),
    decode_nla_nested_mcast(NextElem, Acc ++ [{nested_mcast,Num,Attr1,Attr2}]).
%NLA_PUT_U32(skb, CTRL_ATTR_MCAST_GRP_ID, grp->id);
%NLA_PUT_STRING(skb, CTRL_ATTR_MCAST_GRP_NAME,grp->name);

%%%-------------------------------------------------------------------
%%% OVS Datapath attributes decoder
%%%-------------------------------------------------------------------
-spec decode_ovsdp_nla(binary(),[]|[nla_attr()]) -> [nla_attr()].
decode_ovsdp_nla(<<>>,NlaList) ->
    NlaList;
decode_ovsdp_nla(Nla= <<_Len:16/native-integer,?OVS_DP_ATTR_UNSPEC:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_binary(Nla),
    decode_ovsdp_nla(Tail, NlaList ++ [Attr]);
decode_ovsdp_nla(Nla= <<_Len:16/native-integer,?OVS_DP_ATTR_NAME:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_string(Nla),
    decode_ovsdp_nla(Tail, NlaList ++ [Attr]);
decode_ovsdp_nla(Nla= <<_Len:16/native-integer,?OVS_DP_ATTR_UPCALL_PID:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_ovsdp_nla(Tail, NlaList ++ [Attr]);
decode_ovsdp_nla(Nla= <<_Len:16/native-integer,?OVS_DP_ATTR_STATS:14/native-integer,_O:1,_N:1,_Rest/binary>>,NlaList) ->
    {Attr,Tail}=decode_nla_binary(Nla),
%    {#nla_attr{type=3,data=Data},Tail}=decode_nla_stats(Nla),
%    <<N_hit:64/native-integer,N_mis:64/native-integer,N_lost:64/native-integer,N_flows:64/native-integer>>=Data.
    decode_ovsdp_nla(Tail, NlaList ++ [Attr]).

%%%-------------------------------------------------------------------
%%% OVS vPort attributes decoder
%%%-------------------------------------------------------------------
-spec decode_ovsvp_nla(binary(),[]|[nla_attr()]) -> [nla_attr()].
decode_ovsvp_nla(<<>>,NlaList) ->
    NlaList;
decode_ovsvp_nla(Nla= <<_Len:16/native-integer,
        ?OVS_VPORT_ATTR_UNSPEC:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_binary(Nla),
    decode_ovsvp_nla(Tail, NlaList ++ [Attr]);

% u32 port number within datapath
decode_ovsvp_nla(Nla= <<_Len:16/native-integer,
        ?OVS_VPORT_ATTR_PORT_NO:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_ovsvp_nla(Tail, NlaList ++ [Attr]);

% u32 OVS_VPORT_TYPE_* constant.
decode_ovsvp_nla(Nla= <<_Len:16/native-integer,
        ?OVS_VPORT_ATTR_TYPE:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_ovsvp_nla(Tail, NlaList ++ [Attr]);

% string name, up to IFNAMSIZ bytes long
decode_ovsvp_nla(Nla= <<_Len:16/native-integer,
        ?OVS_VPORT_ATTR_NAME:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_string(Nla),
    decode_ovsvp_nla(Tail, NlaList ++ [Attr]);

% nested attributes, varies by vport type
decode_ovsvp_nla(     <<Len:16/native-integer,
        ?OVS_VPORT_ATTR_OPTIONS:14/native-integer,O:1,N:1,Rest/binary>>,
        NlaList) ->
%    {Attr,Tail}=decode_nla_integer(Nla),
%    decode_ovsvp_nla(Tail, NlaList ++ [Attr]);
    L=Len-4,
    <<This:L/binary,Tail/binary>>=Rest, 
    Attr=#nla_attr{type=?OVS_VPORT_ATTR_OPTIONS,n=N,o=O,
            data=decode_nla_nested_vportopts(This,[])},
    decode_ovsvp_nla(Tail, NlaList ++ [Attr]);

% u32 Netlink PID to receive upcalls
decode_ovsvp_nla(Nla= <<_Len:16/native-integer,
        ?OVS_VPORT_ATTR_UPCALL_PID:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_ovsvp_nla(Tail, NlaList ++ [Attr]);

% struct ovs_vport_stats
decode_ovsvp_nla(Nla= <<_Len:16/native-integer,
        ?OVS_VPORT_ATTR_STATS:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_binary(Nla),
%    {#nla_attr{type=3,data=Data},Tail}=decode_nla_stats(Nla),
%    <<N_hit:64/native-integer,N_mis:64/native-integer,N_lost:64/native-integer,N_flows:64/native-integer>>=Data.
    decode_ovsvp_nla(Tail, NlaList ++ [Attr]).

decode_nla_nested_vportopts(<<>>,Acc) ->    Acc;
decode_nla_nested_vportopts(<<Len:16/native-integer,Num:16/native-integer,Rest/binary>>,Acc) ->
    L=Len-4,
    <<ThisElem:L/binary,NextElem/binary>>= Rest,
    Attr=decode_genl_nla(ThisElem,[]),
%    {Attr1,ThisElem1}=decode_nla_integer(ThisElem),
%    {Attr2,<<>>}=decode_nla_integer(ThisElem1),
    decode_nla_nested_vportopts(NextElem, Acc ++ [{nested_vportopts,Num,Attr}]).

%%%-------------------------------------------------------------------
%%% OVS Flow attributes decoder
%%%-------------------------------------------------------------------
-spec decode_ovsfl_nla(binary(),[]|[nla_attr()]) -> [nla_attr()].
decode_ovsfl_nla(<<>>,NlaList) ->
    NlaList;
decode_ovsfl_nla(Nla= <<_Len:16/native-integer,
        ?OVS_FLOW_ATTR_UNSPEC:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_binary(Nla),
    decode_ovsfl_nla(Tail, NlaList ++ [Attr]);

% Sequence of OVS_KEY_ATTR_* attributes.
decode_ovsfl_nla(     <<Len:16/native-integer,
        ?OVS_FLOW_ATTR_KEY:14/native-integer,O:1,N:1,Rest/binary>>,
        NlaList) -> %nested
    L=Len-4,
    <<This:L/binary,Tail/binary>>=Rest, 
    Attr=#nla_attr{type=?OVS_FLOW_ATTR_KEY,n=N,o=O,
            data=decode_nla_nested_flowkeys(This,[])},
    decode_ovsfl_nla(Tail, NlaList ++ [Attr]);

% Nested OVS_ACTION_ATTR_* attributes.
decode_ovsfl_nla(     <<Len:16/native-integer,
        ?OVS_FLOW_ATTR_ACTIONS:14/native-integer,O:1,N:1,Rest/binary>>,
        NlaList) -> %nested
    L=Len-4,
    <<This:L/binary,Tail/binary>>=Rest, 
    Attr=#nla_attr{type=?OVS_FLOW_ATTR_ACTIONS,n=N,o=O,
            data=decode_nla_nested_flowactions(This,[])},
    decode_ovsfl_nla(Tail, NlaList ++ [Attr]);

% struct ovs_flow_stats.
decode_ovsfl_nla(Nla= <<_Len:16/native-integer,
        ?OVS_FLOW_ATTR_STATS:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_binary(Nla),
%    {#nla_attr{type=3,data=Data},Tail}=decode_nla_stats(Nla),
%    <<N_hit:64/native-integer,N_mis:64/native-integer,N_lost:64/native-integer,N_flows:64/native-integer>>=Data.
    decode_ovsfl_nla(Tail, NlaList ++ [Attr]);

% 8-bit OR'd TCP flags.
decode_ovsfl_nla(Nla= <<_Len:16/native-integer,
        ?OVS_FLOW_ATTR_TCP_FLAGS:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_ovsfl_nla(Tail, NlaList ++ [Attr]);

% u64 msecs last used in monotonic time.
decode_ovsfl_nla(Nla= <<_Len:16/native-integer,
        ?OVS_FLOW_ATTR_USED:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_ovsfl_nla(Tail, NlaList ++ [Attr]);

% Flag to clear stats, tcp_flags, used.
decode_ovsfl_nla(Nla= <<_Len:16/native-integer,
        ?OVS_FLOW_ATTR_CLEAR:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_ovsfl_nla(Tail, NlaList ++ [Attr]).

decode_nla_nested_flowkeys(<<>>,Acc) ->    Acc;
decode_nla_nested_flowkeys(<<Len:16/native-integer,Num:16/native-integer,Rest/binary>>,Acc) ->
    L=Len-4,
    <<ThisElem:L/binary,NextElem/binary>>= Rest,
    Attr=decode_genl_nla(ThisElem,[]),
%    {Attr1,ThisElem1}=decode_nla_integer(ThisElem),
%    {Attr2,<<>>}=decode_nla_integer(ThisElem1),
    decode_nla_nested_flowkeys(NextElem, Acc ++ [{nested_flowkeys,Num,Attr}]).

decode_nla_nested_flowactions(<<>>,Acc) ->    Acc;
decode_nla_nested_flowactions(<<Len:16/native-integer,Num:16/native-integer,Rest/binary>>,Acc) ->
    L=Len-4,
    <<ThisElem:L/binary,NextElem/binary>>= Rest,
    Attr=decode_genl_nla(ThisElem,[]),
%    {Attr1,ThisElem1}=decode_nla_integer(ThisElem),
%    {Attr2,<<>>}=decode_nla_integer(ThisElem1),
    decode_nla_nested_flowactions(NextElem, Acc ++ [{nested_flowactions,Num,Attr}]).

%%%-------------------------------------------------------------------
%%% OVS Packet attributes decoder
%%%-------------------------------------------------------------------
-spec decode_ovspk_nla(binary(),[]|[nla_attr()]) -> [nla_attr()].
decode_ovspk_nla(<<>>,NlaList) ->
    NlaList;
decode_ovspk_nla(Nla= <<_Len:16/native-integer,
        ?OVS_PACKET_ATTR_UNSPEC:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_binary(Nla),
    decode_ovspk_nla(Tail, NlaList ++ [Attr]);

% Packet data.
decode_ovspk_nla(Nla= <<_Len:16/native-integer,
        ?OVS_PACKET_ATTR_PACKET:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_binary(Nla),
    decode_ovspk_nla(Tail, NlaList ++ [Attr]);

% Nested OVS_KEY_ATTR_* attributes.
decode_ovspk_nla(     <<Len:16/native-integer,
        ?OVS_PACKET_ATTR_KEY:14/native-integer,O:1,N:1,Rest/binary>>,
        NlaList) -> %nested
    L=Len-4,
    <<This:L/binary,Tail/binary>>=Rest, 
    Attr=#nla_attr{type=?OVS_PACKET_ATTR_KEY,n=N,o=O,
            data=decode_nla_nested_flowkeys(This,[])},
    decode_ovspk_nla(Tail, NlaList ++ [Attr]);

%  Nested OVS_ACTION_ATTR_* attributes.
decode_ovspk_nla(     <<Len:16/native-integer,
        ?OVS_PACKET_ATTR_ACTIONS:14/native-integer,O:1,N:1,Rest/binary>>,
        NlaList) -> %nested
    L=Len-4,
    <<This:L/binary,Tail/binary>>=Rest, 
    Attr=#nla_attr{type=?OVS_PACKET_ATTR_ACTIONS,n=N,o=O,
            data=decode_nla_nested_flowactions(This,[])},
    decode_ovspk_nla(Tail, NlaList ++ [Attr]);


%  u64 OVS_ACTION_ATTR_USERSPACE arg.
decode_ovspk_nla(Nla= <<_Len:16/native-integer,
        ?OVS_PACKET_ATTR_USERDATA:14/native-integer,_O:1,_N:1,_Rest/binary>>,
        NlaList) ->
    {Attr,Tail}=decode_nla_integer(Nla),
    decode_ovspk_nla(Tail, NlaList ++ [Attr]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% encoders
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%-------------------------------------------------------------------
%%% attributes ecoder helper functions
%%%-------------------------------------------------------------------
-spec encode_nla_string(nla_attr()) -> binary().
encode_nla_string(Nla=#nla_attr{data = []}) ->
    encode_nla_string(Nla#nla_attr{data = <<0>>});

encode_nla_string(Nla=#nla_attr{data = Data}) when is_list(Data) ->
    encode_nla_string(Nla#nla_attr{data = list_to_binary(Data)});

encode_nla_string(Nla=#nla_attr{data = <<>>}) ->
    encode_nla_string(Nla#nla_attr{data = <<0>>});

encode_nla_string(    #nla_attr{type = Type, n=N, o=O, data = Data}) when is_binary(Data) ->
    Payload=case binary:at(Data,size(Data)-1) == 0 of
        true -> Data;
        false -> <<Data/binary,0>>
    end,
    PayloadLen=size(Payload),
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    <<Len:16/native-integer, Type:14/native-integer,O:1,N:1 ,0:(HdrPadLen*8),
      Payload/binary, 0:(PayloadPadLen*8)>>.

-spec encode_nla_integer( integer(), nla_attr()) -> binary().
encode_nla_integer(PayloadLen,    #nla_attr{type = Type, n=N, o=O, data = Data}) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    HPL=HdrPadLen*8,
    PL=PayloadLen*8,
    PPL=PayloadPadLen*8,
    <<Len:16/native-integer, Type:14/native-integer,O:1,N:1, 0:HPL,
      Data:PL/native-integer, 0:PPL>>.

-spec encode_nla_int8(nla_attr()) -> binary().
-spec encode_nla_int16(nla_attr()) -> binary().
-spec encode_nla_int32(nla_attr()) -> binary().
-spec encode_nla_int64(nla_attr()) -> binary().
encode_nla_int8(Nla=#nla_attr{})  ->    encode_nla_integer(1,Nla).
encode_nla_int16(Nla=#nla_attr{}) ->    encode_nla_integer(2,Nla).
encode_nla_int32(Nla=#nla_attr{}) ->    encode_nla_integer(4,Nla).
encode_nla_int64(Nla=#nla_attr{}) ->    encode_nla_integer(8,Nla).

-spec encode_nla_binary(nla_attr()) -> binary().
encode_nla_binary(#nla_attr{type = Type, n=N, o=O, data = Payload}) ->
    PayloadLen=size(Payload),
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    <<Len:16/native-integer, Type:14/native-integer,O:1,N:1 ,0:(HdrPadLen*8),
      Payload/binary, 0:(PayloadPadLen*8)>>.

%%%-------------------------------------------------------------------
%%% Generic NetLink attributes encoder
%%%-------------------------------------------------------------------
-spec encode_genl_nla( <<>> | [] | [nla_attr()]
        | [{nested_ops,int16(),nla_attr(),nla_attr()}]
        | [{nested_mcast,int16(),nla_attr(),nla_attr()}],binary()) -> binary().
encode_genl_nla([],Acc) ->  Acc;
encode_genl_nla(<<>>,Acc) -> Acc;

encode_genl_nla([Nla=#nla_attr{type = ?CTRL_ATTR_UNSPEC} |Rest],Acc) ->
    Bin=encode_nla_binary(Nla),
    encode_genl_nla(Rest,<<Acc/binary,Bin/binary>>);

encode_genl_nla([Nla=#nla_attr{type = ?CTRL_ATTR_FAMILY_NAME} |Rest],Acc) ->
    Bin=encode_nla_string(Nla),
    encode_genl_nla(Rest,<<Acc/binary,Bin/binary>>);

encode_genl_nla([Nla=#nla_attr{type = ?CTRL_ATTR_FAMILY_ID} |Rest],Acc) ->
    NlaBin= encode_nla_int16(Nla),
    encode_genl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_genl_nla([Nla=#nla_attr{type = ?CTRL_ATTR_VERSION} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_genl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_genl_nla([Nla=#nla_attr{type = ?CTRL_ATTR_HDRSIZE} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_genl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_genl_nla([Nla=#nla_attr{type = ?CTRL_ATTR_MAXATTR} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_genl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_genl_nla([#nla_attr{type = ?CTRL_ATTR_OPS,n=N, o=O,data = Data }
           |Rest],Acc)  ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    Payload=encode_genl_nla(Data,<<>>),
    PayloadLen=size(Payload),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?CTRL_ATTR_OPS:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_genl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_genl_nla([#nla_attr{type = ?CTRL_ATTR_MCAST_GROUPS,n=N, o=O,data = Data }
           |Rest],Acc) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    Payload=encode_genl_nla(Data,<<>>),
    PayloadLen=size(Payload),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?CTRL_ATTR_MCAST_GROUPS:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_genl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_genl_nla([{nested_ops,Num,Attr1,Attr2}|Rest],Acc) ->
    Bin1=encode_nla_int32(Attr1),
    Bin2=encode_nla_int32(Attr2),
    Payload= <<Bin1/binary,Bin2/binary>>,
    Len=4+size(Payload),
    NlaBin= <<Len:16/native-integer,Num:16/native-integer,Payload/binary>>,
    encode_genl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_genl_nla([{nested_mcast,Num,Attr1,Attr2}|Rest],Acc) ->
    Bin1=encode_nla_int32(Attr1),
    Bin2=encode_nla_string(Attr2),
    Payload= <<Bin1/binary,Bin2/binary>>,
    Len=4+size(Payload),
    NlaBin= <<Len:16/native-integer,Num:16/native-integer,Payload/binary>>,
    encode_genl_nla(Rest,<<Acc/binary,NlaBin/binary>>).

%%%-------------------------------------------------------------------
%%% OVS Datapath attributes encoder
%%%-------------------------------------------------------------------
-spec encode_ovsdp_nla( <<>> | [] | [nla_attr()],binary()) -> binary().

encode_ovsdp_nla([],Acc) -> Acc;
%encode_ovsdp_nla(<<>>,Acc) -> Acc;

encode_ovsdp_nla([Nla=#nla_attr{type = ?OVS_DP_ATTR_UNSPEC} |Rest],Acc) ->
    Bin=encode_nla_binary(Nla),
    encode_ovsdp_nla(Rest,<<Acc/binary,Bin/binary>>);

encode_ovsdp_nla([Nla=#nla_attr{type = ?OVS_DP_ATTR_NAME} |Rest],Acc) ->
    Bin=encode_nla_string(Nla),
    encode_ovsdp_nla(Rest,<<Acc/binary,Bin/binary>>);

encode_ovsdp_nla([Nla=#nla_attr{type = ?OVS_DP_ATTR_UPCALL_PID} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_ovsdp_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_ovsdp_nla([Nla=#nla_attr{type = ?OVS_DP_ATTR_STATS} |Rest],Acc) ->
%    {#nla_attr{type=3,data=Data},Tail}=decode_nla_stats(Nla),
%    Data= <<N_hit:64/native-integer,N_mis:64/native-integer,N_lost:64/native-integer,N_flows:64/native-integer>>,
    Bin=encode_nla_binary(Nla),
    encode_ovsdp_nla(Rest,<<Acc/binary,Bin/binary>>).

%%%-------------------------------------------------------------------
%%% OVS vPort attributes encoder
%%%-------------------------------------------------------------------
-spec encode_ovsvp_nla( <<>> | [] | [nla_attr()]
    | [{nested_vportopts,int16(),nla_attr()}],binary()) -> binary().

encode_ovsvp_nla([],Acc) -> Acc;
encode_ovsvp_nla(<<>>,Acc) -> Acc;

encode_ovsvp_nla([Nla=#nla_attr{type = ?OVS_VPORT_ATTR_UNSPEC} |Rest],Acc) ->
    Bin=encode_nla_binary(Nla),
    encode_ovsvp_nla(Rest,<<Acc/binary,Bin/binary>>);

% u32 port number within datapath
encode_ovsvp_nla([Nla=#nla_attr{type = ?OVS_VPORT_ATTR_PORT_NO} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_ovsvp_nla(Rest,<<Acc/binary,NlaBin/binary>>);

% u32 OVS_VPORT_TYPE_* constant.
encode_ovsvp_nla([Nla=#nla_attr{type = ?OVS_VPORT_ATTR_TYPE} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_ovsvp_nla(Rest,<<Acc/binary,NlaBin/binary>>);

% string name, up to IFNAMSIZ bytes long
encode_ovsvp_nla([Nla=#nla_attr{type = ?OVS_VPORT_ATTR_NAME} |Rest],Acc) ->
    Bin=encode_nla_string(Nla),
    encode_ovsvp_nla(Rest,<<Acc/binary,Bin/binary>>);

% nested attributes, varies by vport type
encode_ovsvp_nla([#nla_attr{type = ?OVS_VPORT_ATTR_OPTIONS,n=N, o=O,data = Data }
           |Rest],Acc) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    Payload=encode_ovsvp_nla(Data,<<>>),
    PayloadLen=size(Payload),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?OVS_VPORT_ATTR_OPTIONS:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_ovsvp_nla(Rest,<<Acc/binary,NlaBin/binary>>);

% u32 Netlink PID to receive upcalls
encode_ovsvp_nla([Nla=#nla_attr{type = ?OVS_VPORT_ATTR_UPCALL_PID} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_ovsvp_nla(Rest,<<Acc/binary,NlaBin/binary>>);

% struct ovs_vport_stats
encode_ovsvp_nla([Nla=#nla_attr{type = ?OVS_VPORT_ATTR_STATS} |Rest],Acc) ->
    Bin=encode_nla_binary(Nla),
    encode_ovsvp_nla(Rest,<<Acc/binary,Bin/binary>>);

encode_ovsvp_nla([{nested_vportopts,Num,Attr}|Rest],Acc) ->
    Payload=encode_ovsvp_nla(Attr,<<>>),
    Len=4+size(Payload),
    NlaBin= <<Len:16/native-integer,Num:16/native-integer,Payload/binary>>,
    encode_ovsvp_nla(Rest,<<Acc/binary,NlaBin/binary>>).

%%%-------------------------------------------------------------------
%%% OVS Flow attributes encoder
%%%-------------------------------------------------------------------
-spec encode_ovsfl_nla( <<>> | [] | [nla_attr()],binary()) -> binary().

encode_ovsfl_nla([],Acc) -> Acc;
%encode_ovsfl_nla(<<>>,Acc) -> Acc;

encode_ovsfl_nla([Nla=#nla_attr{type = ?OVS_FLOW_ATTR_UNSPEC} |Rest],Acc) ->
    Bin=encode_nla_binary(Nla),
    encode_ovsfl_nla(Rest,<<Acc/binary,Bin/binary>>);

% Sequence of OVS_KEY_ATTR_* attributes.
encode_ovsfl_nla([#nla_attr{type = ?OVS_FLOW_ATTR_KEY,n=N, o=O,data = Data }
           |Rest],Acc) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    Payload=encode_ovs_nla(Data,<<>>),
    PayloadLen=size(Payload),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?OVS_FLOW_ATTR_KEY:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_ovsfl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

% Nested OVS_ACTION_ATTR_* attributes.
encode_ovsfl_nla([#nla_attr{type = ?OVS_FLOW_ATTR_ACTIONS,n=N, o=O,data = Data }
           |Rest],Acc) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    Payload=encode_ovs_nla(Data,<<>>),
    PayloadLen=size(Payload),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?OVS_FLOW_ATTR_ACTIONS:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_ovsfl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

% struct ovs_flow_stats.
encode_ovsfl_nla([Nla=#nla_attr{type = ?OVS_FLOW_ATTR_STATS} |Rest],Acc) ->
    Bin=encode_nla_binary(Nla),
    encode_ovsfl_nla(Rest,<<Acc/binary,Bin/binary>>);

% 8-bit OR'd TCP flags.
encode_ovsfl_nla([Nla=#nla_attr{type = ?OVS_FLOW_ATTR_TCP_FLAGS} |Rest],Acc) ->
    NlaBin= encode_nla_int8(Nla),
    encode_ovsfl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

% u64 msecs last used in monotonic time.
encode_ovsfl_nla([Nla=#nla_attr{type = ?OVS_FLOW_ATTR_USED} |Rest],Acc) ->
    NlaBin= encode_nla_int64(Nla),
    encode_ovsfl_nla(Rest,<<Acc/binary,NlaBin/binary>>);

% Flag to clear stats, tcp_flags, used.
encode_ovsfl_nla([Nla=#nla_attr{type = ?OVS_FLOW_ATTR_CLEAR} |Rest],Acc) ->
    NlaBin= encode_nla_int64(Nla),
    encode_ovsfl_nla(Rest,<<Acc/binary,NlaBin/binary>>).


%%%-------------------------------------------------------------------
%%% OVS Packet attributes encoder
%%%-------------------------------------------------------------------
-spec encode_ovspk_nla( <<>> | [] | [nla_attr()],binary()) -> binary().

encode_ovspk_nla([],Acc) -> Acc;
%encode_ovspk_nla(<<>>,Acc) -> Acc;

encode_ovspk_nla([Nla=#nla_attr{type = ?OVS_PACKET_ATTR_UNSPEC} |Rest],Acc) ->
    Bin=encode_nla_binary(Nla),
    encode_ovspk_nla(Rest,<<Acc/binary,Bin/binary>>);

% Packet data.
encode_ovspk_nla([Nla=#nla_attr{type = ?OVS_PACKET_ATTR_PACKET} |Rest],Acc) ->
    Bin=encode_nla_binary(Nla),
    encode_ovspk_nla(Rest,<<Acc/binary,Bin/binary>>);

% Nested OVS_KEY_ATTR_* attributes.
encode_ovspk_nla([#nla_attr{type = ?OVS_PACKET_ATTR_KEY,n=N, o=O,data = Data }
           |Rest],Acc) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    Payload=encode_ovs_nla(Data,<<>>),
    PayloadLen=size(Payload),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?OVS_PACKET_ATTR_KEY:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_ovspk_nla(Rest,<<Acc/binary,NlaBin/binary>>);

% Nested OVS_ACTION_ATTR_* attributes.
encode_ovspk_nla([#nla_attr{type = ?OVS_PACKET_ATTR_ACTIONS,n=N, o=O,data = Data }
           |Rest],Acc) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    Payload=encode_ovs_nla(Data,<<>>),
    PayloadLen=size(Payload),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?OVS_PACKET_ATTR_ACTIONS:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_ovspk_nla(Rest,<<Acc/binary,NlaBin/binary>>);


%  u64 OVS_ACTION_ATTR_USERSPACE arg.
encode_ovspk_nla([Nla=#nla_attr{type = ?OVS_PACKET_ATTR_USERDATA} |Rest],Acc) ->
    NlaBin= encode_nla_int64(Nla),
    encode_ovspk_nla(Rest,<<Acc/binary,NlaBin/binary>>).

%%%-------------------------------------------------------------------
%%% OVS common encodes for Flow and Packet attributes encoder
%%%-------------------------------------------------------------------
-spec encode_ovs_nla( [{nested_flowkeys,   int16(),[] | [nla_attr()]}]
                    | [{nested_flowactions,int16(),[] | [nla_attr()]}],binary()) -> binary().

encode_ovs_nla([{nested_flowkeys,Num,Attr}|Rest],Acc) ->
    Payload=encode_nla_nested_flowkeys(Attr,<<>>),
    Len=4+size(Payload),
    NlaBin= <<Len:16/native-integer,Num:16/native-integer,Payload/binary>>,
    encode_ovsvp_nla(Rest,<<Acc/binary,NlaBin/binary>>);
encode_ovs_nla([{nested_flowactions,Num,Attr}|Rest],Acc) ->
    Payload=encode_nla_nested_flowactions(Attr,<<>>),
    Len=4+size(Payload),
    NlaBin= <<Len:16/native-integer,Num:16/native-integer,Payload/binary>>,
    encode_ovsvp_nla(Rest,<<Acc/binary,NlaBin/binary>>).

%stub flow keys
-spec encode_nla_nested_flowkeys([] | [{nested_flowkeys,int16(),nla_attr()}],binary()) -> binary().
encode_nla_nested_flowkeys([],Acc) ->
    Acc;
encode_nla_nested_flowkeys([{nested_flowkeys,_,_}|Rest],Acc) ->
    encode_nla_nested_flowkeys(Rest,Acc).
%stub flow actions
-spec encode_nla_nested_flowactions([] | [{nested_flowactions,int16(),nla_attr()}],binary()) -> binary().
encode_nla_nested_flowactions([],Acc) ->
    Acc;
encode_nla_nested_flowactions([{nested_flowactions,_,_}|Rest],Acc) ->
    encode_nla_nested_flowactions(Rest,Acc).
