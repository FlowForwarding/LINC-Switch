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
    Payload=decode_nla(Data, []),
    #genlmsg{cmd=Cmd,version=Ver,payload=Payload}.

decode_nla(<<>>,NlaList) ->
    NlaList;
decode_nla(<<Len:16/native-integer,Rest/binary>>,NlaList) ->
    PayloadLen=Len-4,
    HdrPadLen=0, % should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    PayloadPadLen=nla_align(PayloadLen) -PayloadLen,
    % Len:16/native-integer already eaten
    <<Type:14/native-integer,O:1,N:1, _HdrPad:HdrPadLen/binary,
      Payload:PayloadLen/binary, PayloadPad:PayloadPadLen/binary,
      Tail/binary>> = Rest,
    PL=PayloadLen*8,
    Data=case Type of
            ?CTRL_ATTR_UNSPEC      -> Payload;
            ?CTRL_ATTR_FAMILY_ID   -> <<A:PL/native-integer>> = Payload,A;
            ?CTRL_ATTR_FAMILY_NAME -> L=PayloadLen-1,
                                      <<A:L/binary,0>>=Payload, 
                                      binary_to_list(A);
            ?CTRL_ATTR_VERSION     -> <<A:PL/native-integer>> = Payload,A;
            ?CTRL_ATTR_HDRSIZE     -> <<A:PL/native-integer>> = Payload,A;
            ?CTRL_ATTR_MAXATTR     -> <<A:PL/native-integer>> = Payload,A;
            ?CTRL_ATTR_OPS        -> Payload;
            ?CTRL_ATTR_MCAST_GROUPS-> Payload
    end,
    decode_nla(Tail, NlaList ++ [#nla_attr{type=Type,n=N,o=O,data=Data}]).


encode_nla([],Acc) ->
    Acc;

encode_nla([Nla=#nla_attr{type = ?CTRL_ATTR_FAMILY_NAME,data = Data }
           |Rest],Acc) when is_list(Data)->
    encode_nla([Nla#nla_attr{data=list_to_binary(Data)}|Rest],Acc);

encode_nla([Nla=#nla_attr{type = ?CTRL_ATTR_FAMILY_NAME,data = <<>> }
           |Rest],Acc) ->
    encode_nla([Nla#nla_attr{data= <<0>>}|Rest],Acc);

encode_nla([#nla_attr{type = ?CTRL_ATTR_FAMILY_NAME,n=N, o=O,data = Data }
           |Rest],Acc) when is_binary(Data)->
    Payload=case binary:at(Data,size(Data)-1) == 0 of
        true -> Data;
        false -> <<Data/binary,0>>
    end,
    PayloadLen=size(Payload),
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?CTRL_ATTR_FAMILY_NAME:14/native-integer,O:1,N:1 ,0:(HdrPadLen*8),
              Payload/binary, 0:(PayloadPadLen*8)>>,
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);


encode_nla([#nla_attr{type = ?CTRL_ATTR_FAMILY_ID,n=N, o=O,data = Data }
           |Rest],Acc) ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    PayloadLen=2, % 16bit integer
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              ?CTRL_ATTR_FAMILY_ID:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Data:(PayloadLen*8)/native-integer, 0:(PayloadPadLen*8)>>,
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);


encode_nla([#nla_attr{type = Type,n=N, o=O,data = Data }
           |Rest],Acc) 
        when Type==?CTRL_ATTR_VERSION; Type==?CTRL_ATTR_HDRSIZE;
             Type==?CTRL_ATTR_MAXATTR ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    PayloadLen=4, % 64bit integer
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              Type:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Data:(PayloadLen*8)/native-integer, 0:(PayloadPadLen*8)>>,
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>);

encode_nla([#nla_attr{type = Type,n=N, o=O,data = Data }
           |Rest],Acc) 
        when Type==?CTRL_ATTR_OPS; Type==?CTRL_ATTR_MCAST_GROUPS;
             Type==?CTRL_ATTR_UNSPEC ->
    %should be nla_align(?NLA_HDRLEN), where -define(NLA_HDRLEN,4).
    HdrPadLen = 0,
    PayloadLen=size(Data),
    PayloadPadLen=nla_align(PayloadLen)-PayloadLen,
    Len= 4 + HdrPadLen + PayloadLen,
    NlaBin= <<Len:16/native-integer,
              Type:14/native-integer,O:1,N:1, 0:(HdrPadLen*8),
              Data/binary, 0:(PayloadPadLen*8)>>,
    encode_nla(Rest,<<Acc/binary,NlaBin/binary>>).




