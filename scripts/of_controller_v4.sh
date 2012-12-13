#!/bin/sh
erlc of_controller_v4.erl -pa ../deps/*/ebin -pa ../apps/*/ebin
erl -pa ../deps/*/ebin -eval "of_controller_v4:start()."
