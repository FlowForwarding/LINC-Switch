-module(ofs_userspace_port_procket).

-export([send/2,
         close/1]).

-spec send(integer(), binary()) -> ok.
send(Socket, Frame) ->
    procket:write(Socket, Frame).

-spec close(integer()) -> ok.
close(Socket) ->
    procket:close(Socket).
