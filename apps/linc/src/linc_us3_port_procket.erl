%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc 

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
