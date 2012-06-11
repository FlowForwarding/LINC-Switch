#!/bin/sh
erlc of_controller.erl -pa ../deps/*/ebin
erl -pa ../deps/*/ebin -eval "of_controller:start()."
