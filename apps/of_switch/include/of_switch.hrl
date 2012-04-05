%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
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
