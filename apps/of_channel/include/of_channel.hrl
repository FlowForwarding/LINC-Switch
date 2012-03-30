-record(connection, {
          pid :: pid(),
          socket :: port(),
          version :: integer(),
          role = equal :: role()
         }).

-type connection() :: #connection{}.
-type role() :: master | slave | equal.
