.PHONY: all compile rel test clean deep-clean

all: compile

compile: rebar
	./rebar get-deps compile

rel: compile
	./rebar generate -f

test: compile
	./rebar skip_deps=true apps=of_protocol,of_channel,of_switch eunit

clean: rebar
	./rebar clean

deep-clean: clean
	./rebar delete-deps

rebar:
	wget -q http://cloud.github.com/downloads/basho/rebar/rebar && chmod u+x rebar
