-module(ofs_userspace_port_procket).

-export([send/2]).

send(Socket, Frame) ->
    procket:write(Socket, Frame).
