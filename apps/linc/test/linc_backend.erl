%% This module is required by linc_tests.erl where it's used by Meck as
%% a mocked switch backend. Meck can't create mocked modules which are not
%% backed by real ones, hence need for this one.

-module(linc_backend).

-export([start/1,
         stop/1]).

start(_) ->
    ok.

stop(_) ->
    ok.
