-module(ofconfig_test).

-compile([export_all]).

-define(CONTROLLER, "127.0.0.1").
-define(LINC, "127.0.0.1").

-define(PROLOG, {prolog, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"}).

-define(SAMPLE_CONFIG_XML,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rpc message-id=\"1\"xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\"><edit-config><target><running/></target><config><capable-switch xmlns=\"urn:onf:of111:config:yang\"><id>CapableSwitch0</id><logical-switches><switch><id>LogicalSwitch0</id><datapath-id>00:90:FB:37:71:6E:00:00</datapath-id><enabled>true</enabled><controllers><controller><id>Controller0</id><role>master</role><ip-address>127.0.0.1</ip-address><port>6633</port><protocol>tcp</protocol></controller></controllers></switch></logical-switches></capable-switch></config></edit-config></rpc>").

-include_lib("xmerl/include/xmerl.hrl").

test_copy_config()->
    Config = create_config_modification(),
    {ok, C} = enetconf_client:connect(?LINC, [{port, 1830},
                                              {user, "linc"},
                                              {password, "linc"}]),
    {ok, StartupConfigBefore} = enetconf_client:get_config(C, startup),
    io:format("Startup config before = ~s~n", [StartupConfigBefore]),
    {ok, EditResult} = enetconf_client:edit_config(C, running, {xml, Config}),
    io:format("Edit complete...~n"
              "Result = ~s~n", [EditResult]),
    {ok, CopyResult}= enetconf_client:copy_config(C, running, startup),
    io:format("Copy running to startup complete...~n"
              "Result = ~s~n", [CopyResult]),
    timer:sleep(1000),
    {ok, StartupConfigAfter} = enetconf_client:get_config(C, startup),
    io:format("Startup config after = ~s~n", [StartupConfigAfter]),
    enetconf_client:close_session(C).

create_config_modification() ->
    IP = ?CONTROLLER,
    Port = "6633",
    Controller = {controller,
                  [{id, ["Controller0"]},
                   {role, ["master"]},
                   {'ip-address', [IP]},
                   {port, [Port]},
                   {protocol, ["tcp"]}]},
    Attributes = [{xmlns, "urn:onf:of111:config:yang"}],
    {'capable-switch', Attributes,
     [{id, ["CapableSwitch0"]},
      {'logical-switches',
       [{'switch', [{id, ["LogicalSwitch0"]},
                    {'datapath-id', ["00:90:FB:37:71:6E:00:FF"]},
                    {enabled, ["true"]},
                    {controllers, [Controller]}]}]}]}.
