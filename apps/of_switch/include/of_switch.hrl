%%%-----------------------------------------------------------------------------
%%% Use is subject to License terms.
%%% @copyright (C) 2012 FlowForwarding.org
%%% @doc Header file for OpenFlow switch application.
%%% @end
%%%-----------------------------------------------------------------------------

-record(connection, {
          pid :: pid(),
          socket :: port(),
          version :: integer(),
          role = equal :: role()
         }).

-type connection() :: #connection{}.
-type role() :: master | slave | equal.

%%%-----------------------------------------------------------------------------
%%% Logging macros
%%%-----------------------------------------------------------------------------

-define(DEBUG(Msg),
        lager:debug(Msg)).
-define(DEBUG(Msg, Args),
        lager:debug(Msg, Args)).

-define(INFO(Msg),
        lager:info(Msg)).
-define(INFO(Msg, Args),
        lager:info(Msg, Args)).

-define(WARNING(Msg),
        lager:warning(Msg)).
-define(WARNING(Msg, Args),
        lager:warning(Msg, Args)).

-define(ERROR(Msg),
        lager:error(Msg)).
-define(ERROR(Msg, Args),
        lager:error(Msg, Args)).
