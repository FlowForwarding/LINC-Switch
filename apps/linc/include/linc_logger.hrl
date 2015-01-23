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
%% @doc Header file for OpenFlow switch application with logger macros.

%%------------------------------------------------------------------------------
%% Logging macros
%%------------------------------------------------------------------------------

-define(DEBUG(Msg),
        lager:debug([{linc, x}], Msg)).
-define(DEBUG(Msg, Args),
        lager:debug([{linc, x}], Msg, Args)).

-define(INFO(Msg),
        lager:info([{linc, x}],Msg)).
-define(INFO(Msg, Args),
        lager:info([{linc, x}],Msg, Args)).

-define(WARNING(Msg),
        lager:warning([{linc, x}],Msg)).
-define(WARNING(Msg, Args),
        lager:warning([{linc, x}],Msg, Args)).

-define(ERROR(Msg),
        lager:error([{linc, x}],Msg)).
-define(ERROR(Msg, Args),
        lager:error([{linc, x}],Msg, Args)).
