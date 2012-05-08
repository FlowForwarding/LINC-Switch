-module(ofs_userspace_port_procket).

-export([send/2,
         close/1]).

send(Socket, Frame) ->
    procket:write(Socket, Frame).

close(Socket) ->
    procket:close(Socket).
