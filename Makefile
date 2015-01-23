.PHONY: rel compile get-deps update-deps test clean deep-clean

rel: compile
	@./rebar generate -f
	@./scripts/post_generate_hook

offline:
	@./rebar compile
	@./rebar generate -f
	@./scripts/post_generate_hook

compile: get-deps update-deps
	@./rebar compile

get-deps:
	@./rebar get-deps

update-deps:
	@./rebar update-deps

test: compile
	@./rebar skip_deps=true apps="linc,linc_us5" eunit

test_us3: compile
	@./rebar skip_deps=true apps="linc,linc_us3" eunit

test_us4: compile
	@./rebar skip_deps=true apps="linc,linc_us4" eunit

test_us4_oe: compile
	@./rebar skip_deps=true apps="linc,linc_us4_oe" eunit

clean:
	@./rebar clean

deep-clean: clean
	@./rebar delete-deps

setup_dialyzer:
	dialyzer --build_plt --apps erts kernel stdlib mnesia compiler syntax_tools runtime_tools crypto tools inets ssl webtool public_key observer
	dialyzer --add_to_plt deps/*/ebin

dialyzer: compile
	dialyzer apps/*/ebin

dev_prepare: compile
	./scripts/pre_develop_hook

dev:
	erl -env ERL_MAX_ETS_TABLES 3000 -pa apps/*/ebin apps/*/test \
	deps/*/ebin -config rel/files/sys.config -args_file rel/files/vm.args \
	 -eval "lists:map(fun application:start/1, [kernel, stdlib, asn1, \
		crypto, public_key, ssl, compiler, syntax_tools, runtime_tools, \
		xmerl, mnesia, goldrush, lager, netlink, linc, of_protocol, \
		of_config, sync])"
