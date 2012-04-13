.PHONY: all compile rel test test_protocol test_switch clean deep-clean

all: compile

compile: rebar
	./rebar get-deps compile

rel: compile
	./rebar generate -f

test: compile
	./rebar skip_deps=true apps=of_protocol,of_switch eunit

test_protocol: compile
	./rebar skip_deps=true apps=of_protocol eunit

test_switch: compile
	./rebar skip_deps=true apps=of_switch eunit

clean: rebar
	./rebar clean

deep-clean: clean
	./rebar delete-deps

rebar:
	wget -q http://cloud.github.com/downloads/basho/rebar/rebar
	chmod u+x rebar
