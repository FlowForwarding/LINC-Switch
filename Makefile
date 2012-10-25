.PHONY: rel compile get-deps test clean deep-clean

rel: compile
	@./rebar generate -f
	@./scripts/post_generate_hook

compile: get-deps
	@./rebar compile

get-deps:
	@./rebar get-deps

test: compile
	@./rebar skip_deps=true eunit

clean:
	@./rebar clean

deep-clean: clean
	@./rebar delete-deps

setup_dialyzer:
	dialyzer --build_plt --apps erts kernel stdlib mnesia compiler syntax_tools runtime_tools crypto tools inets ssl webtool public_key observer
	dialyzer --add_to_plt deps/*/ebin

dialyzer: compile
	dialyzer apps/*/ebin
