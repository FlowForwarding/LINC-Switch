-module(linc_us3_port_procket).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-export([send/2,
         close/1]).

%% TODO: Add typespecs to procket to avoid:
%% linc_us3_port_procket.erl:7: Function send/2 has no local return
%% linc_us3_port_procket.erl:11: Function close/1 has no local return
%% warnings in dialyzer.

-spec send(integer(), binary()) -> ok.
send(Socket, Frame) ->
    procket:write(Socket, Frame).

-spec close(integer()) -> ok.
close(Socket) ->
    procket:close(Socket).
