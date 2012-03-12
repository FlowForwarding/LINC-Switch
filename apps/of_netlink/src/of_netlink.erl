%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Grzegorz Stanislawski <grzegorz.stanislawski@erlang-solutions.com>
%%% @doc Linux Netlink interface library module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_netlink).
-include("netlink_rec.hrl").
%% API
-export([encode/1,decode/1,decode_sockaddr_nl/1]).

%%%===================================================================
%%% External functions
%%%===================================================================
encode(Binary) when is_binary(Binary) ->
    Binary;

encode([]) ->
    <<>>;

encode(List=[#nla_attr{}|_]) ->
    encode_nla(List,<<>>);

encode(#sockaddr_nl{family=Family,pid=Pid,groups=Groups}) ->
    <<Family:16/native-integer, 0:16/native-integer, 
      Pid:32/native-integer,Groups:32/native-integer>>;

encode(#genlmsg{cmd=Cmd,version=Ver,payload=Payload}) ->
    Data=encode(Payload),
    <<Cmd:8/native-integer,Ver:8/native-integer,
      0:16/native-integer,Data/binary>>;

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

decode_sockaddr_nl(<<Family:16/native-integer, _:16/native-integer,
        Pid:32/native-integer,Groups:32/native-integer>>) ->
    #sockaddr_nl{family=Family,pid=Pid,groups=Groups}.

%netlink error 
decode(<<L:32/native-integer,2:16/native-integer,
         FlagsLo:1/binary,FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>) ->
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
         FlagsLo:1/binary, FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>) ->
    <<_:3,D:1,E:1,A:1,M:1,R:1>> = FlagsLo,
    PayloadLen=L-16,
    %chop trailing 0's
    <<Data1:PayloadLen/binary,_/binary>>=Data,
    Payload=decode_genl(Data1),
    #nlmsg{len=L,type=?NETLINK_GENERIC,request=R,multi=M,ack=A,echo=E,
           dumpintr=D,seq=Seq,pid=Pid,payload=Payload};

%default leave paload undecoded
decode(<<L:32/native-integer,Type:16/native-integer,
         FlagsLo:1/binary,FlagsHi:8/native-integer,
         Seq:32/native-integer,Pid:32/native-integer,Data/binary>>) ->
    <<_:3,D:1,E:1,A:1,M:1,R:1>> = FlagsLo,
    PayloadLen=L-16,
    %chop trailing 0's
    <<Data1:PayloadLen/binary,_/binary>>=Data,
    #nlmsg{len=L,type=Type,request=R,multi=M,ack=A,echo=E,
           dumpintr=D,seq=Seq,pid=Pid,payload=Data1}.


%%%===================================================================
%%% Internal functions
%%%===================================================================
nla_align(Len) ->
    (Len + ?NLA_ALIGNTO - 1) band bnot(?NLA_ALIGNTO - 1).

decode_genl(<<>>) ->
    {error,no_genl};
decode_genl(<<Cmd:8/native-integer,Ver:8/native-integer,
              _:16/native-integer,Data/binary>>) ->
    Payload=decode_genl_nla(Data, []),
    #genlmsg{cmd=Cmd,version=Ver,payload=Payload}.

decode_nla_common(<<Len:16/native-integer, Type:14/native-integer,O:1,N:1, Rest/binary>>) ->
    PayloadLen=Len-4,
    HdrPadLen=0, % should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    PayloadPadLen=nla_align(PayloadLen) -PayloadLen,
    % Len:16/native-integer already eaten
    <<_HdrPad:HdrPadLen/binary,
      Payload:PayloadLen/binary, PayloadPad:PayloadPadLen/binary,
      Tail/binary>> = Rest,
    {Type,N,O,PayloadLen,Payload,Tail}.

decode_nla_binary(Nla) ->
    {Type,N,O,PayloadLen,Payload,Tail}=decode_nla_common(Nla),
    {#nla_attr{type=Type,n=N,o=O,data=Payload},Tail}.

decode_nla_string(Nla) ->
    {Type,N,O,PayloadLen,Payload,Tail}=decode_nla_common(Nla),
    L=PayloadLen-1,
    <<A:L/binary,0>>=Payload,
    {#nla_attr{type=Type,n=N,o=O,data=binary_to_list(A)},Tail}.

decode_nla_integer(Nla) ->
    {Type,N,O,PayloadLen,Payload,Tail}=decode_nla_common(Nla),
    PL=PayloadLen*8,
    <<A:PL/native-integer>> = Payload,
    {#nla_attr{type=Type,n=N,o=O,data=A},Tail}.


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
decode_genl_nla(Nla= <<Len:16/native-integer,?CTRL_ATTR_OPS:14/native-integer,O:1,N:1,Rest/binary>>,NlaList) ->
    L=Len-4,
    <<This:L/binary,Tail/binary>>=Rest, 
    Attr=#nla_attr{type=?CTRL_ATTR_OPS,n=N,o=O,data=decode_nla_nested_ops(This,[])},
    decode_genl_nla(Tail, NlaList ++ [Attr]);
decode_genl_nla(Nla= <<Len:16/native-integer,?CTRL_ATTR_MCAST_GROUPS:14/native-integer,O:1,N:1,Rest/binary>>,NlaList) ->
    L=Len-4,
    <<This:L/binary,Tail/binary>>=Rest,
    Attr=#nla_attr{type=?CTRL_ATTR_MCAST_GROUPS,n=N,o=O,data=decode_nla_nested_mcast(This,[])},
    decode_genl_nla(Tail, NlaList ++ [Attr]).

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

encode_nla_string(Nla=#nla_attr{data = Data}) when is_list(Data) ->
    encode_nla_string(Nla#nla_attr{data = list_to_binary(Data)});

encode_nla_string(Nla=#nla_attr{data = <<>>}) ->
    encode_nla_string(Nla#nla_attr{data = <<0>>});

encode_nla_string(Nla=#nla_attr{type = Type, n=N, o=O, data = Data}) when is_binary(Data) ->
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

encode_nla_integer(PayloadLen,Nla=#nla_attr{type = Type, n=N, o=O, data = Data}) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    <<Len:16/native-integer, Type:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
      Data:(PayloadLen*8)/native-integer, 0:(PayloadPadLen*8)>>.

encode_nla_int8(Nla=#nla_attr{})  ->    encode_nla_integer(1,Nla).
encode_nla_int16(Nla=#nla_attr{}) ->    encode_nla_integer(2,Nla).
encode_nla_int32(Nla=#nla_attr{}) ->    encode_nla_integer(4,Nla).

encode_nla([],Acc) ->
    Acc;

encode_nla([Nla=#nla_attr{type = ?CTRL_ATTR_FAMILY_NAME} |Rest],Acc) ->
    Bin=encode_nla_string(Nla),
    encode_nla(Rest,<<Acc/binary,Bin/binary>>);

encode_nla([Nla=#nla_attr{type = ?CTRL_ATTR_FAMILY_ID} |Rest],Acc) ->
    NlaBin= encode_nla_int16(Nla),
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_nla([Nla=#nla_attr{type = ?CTRL_ATTR_VERSION} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_nla([Nla=#nla_attr{type = ?CTRL_ATTR_HDRSIZE} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_nla([Nla=#nla_attr{type = ?CTRL_ATTR_MAXATTR} |Rest],Acc) ->
    NlaBin= encode_nla_int32(Nla),
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_nla([#nla_attr{type = ?CTRL_ATTR_OPS,n=N, o=O,data = Data }
           |Rest],Acc)  ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    Payload=encode_nla(Data,<<>>),
    PayloadLen=size(Payload),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?CTRL_ATTR_OPS:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_nla([#nla_attr{type = ?CTRL_ATTR_MCAST_GROUPS,n=N, o=O,data = Data }
           |Rest],Acc) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    Payload=encode_nla(Data,<<>>),
    PayloadLen=size(Payload),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?CTRL_ATTR_MCAST_GROUPS:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_nla([#nla_attr{type = ?CTRL_ATTR_UNSPEC,n=N, o=O,data = Data }
           |Rest],Acc) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    PayloadLen=size(Data),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?CTRL_ATTR_UNSPEC:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Data/binary, 0:(PayloadPadLen*8)>>,
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_nla([{nested_ops,Num,Attr1,Attr2}|Rest],Acc) ->
    Bin1=encode_nla_int32(Attr1),
    Bin2=encode_nla_int32(Attr2),
    Payload= <<Bin1/binary,Bin2/binary>>,
    Len=4+size(Payload),
    NlaBin= <<Len:16/native-integer,Num:16/native-integer,Payload/binary>>,
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_nla([{nested_mcast,Num,Attr1,Attr2}|Rest],Acc) ->
    Bin1=encode_nla_int32(Attr1),
    Bin2=encode_nla_string(Attr2),
    Payload= <<Bin1/binary,Bin2/binary>>,
    Len=4+size(Payload),
    NlaBin= <<Len:16/native-integer,Num:16/native-integer,Payload/binary>>,
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>).

