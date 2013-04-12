-module(config_test).

-compile([export_all]).

-define(CONTROLLER, "127.0.0.1").
-define(LINC, "127.0.0.1").

test1()->
    IP = ?CONTROLLER,
    Port = "6633",
    Controller = {controller,
                  [{id, ["Controller0"]},
                   {role, ["master"]},
                   {'ip-address', [IP]},
                   {port, [Port]},
                   {protocol, ["tcp"]}]},
    Attributes = [{xmlns, "urn:onf:of111:config:yang"}],
    Config = {'capable-switch', Attributes,
              [{id, ["CapableSwitch0"]},
               {'logical-switches',
                [{'switch', [{id, ["LogicalSwitch0"]},
                             {'datapath-id', ["00:90:FB:37:71:6E:00:00"]},
                             {enabled, ["true"]},
                             {controllers, [Controller]}]}]}]},
    {ok, C} = enetconf_client:connect(?LINC, [{port, 1830},
                                              {user, "linc"},
                                              {password, "linc"}]),
    {ok, RunningConfig} = enetconf_client:get_config(C, running),
    io:format("RunningConfig = ~s~n", [RunningConfig]),
    {ok, Result} = enetconf_client:edit_config(C, running, {xml, Config}),
    io:format("Edit complete...~n"
              "Result = ~s~n", [Result]),
    timer:sleep(1000),
    {ok, NewRunningConfig} = enetconf_client:get_config(C, running),
    io:format("NewRunningConfig = ~s~n", [NewRunningConfig]),
    enetconf_client:close_session(C).
