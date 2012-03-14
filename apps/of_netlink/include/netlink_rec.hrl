%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Grzegorz Stanislawski <grzegorz.stanislawski@erlang-solutions.com>
%%%-----------------------------------------------------------------------------


-define(NLA_ALIGNTO,4).
-define(AF_NETLINK,16).
-define(PF_NETLINK,?AF_NETLINK).

%%------------------------------------------------------------------------------
%% Types
%%------------------------------------------------------------------------------
-type bit() :: 0|1 .
%% @type bit() = 0 |1.
%%   bit flag holder
%% @end
%%------------------------------------------------------------------------------


%% struct sockaddr_nl
-record(sockaddr_nl, {
        family = ?AF_NETLINK :: integer(), %16b, + pad 16b
        pid    = 0           :: integer(), %32b
        groups = 0           ::integer()   %32b
        }).

-type sockaddr_nl() :: #sockaddr_nl{}.
%% @type sockaddr_nl() :: #sockaddr_nl{}.
%%   holds structure used in procket:connect.
%%   Needs to be encoded to binary (with of_netlink:encode()) before using .

%% struct nla_attr with payload
-record(nla_attr, {
        type :: integer(),
        n    :: bit(),
        o    :: bit(),
        data :: binary()
        }).

%% struct genlmsghdr
-record(genlmsg, {
        cmd :: byte(),
        version :: byte(),
%       reserved :: binary()
        payload :: list(#nla_attr{})
        }).

%% ovs_datapath rec == genlmsg + ovs_header struct
-record(ovsdpmsg, {
        cmd :: byte(),
        version :: byte(),
        ifindex :: integer(), %might should have rec here if protocol specific header would be more complex
        payload :: list(#nla_attr{})
        }).
%% ovs_vport rec == genlmsg + ovs_header struct
-record(ovsvpmsg, {
        cmd :: byte(),
        version :: byte(),
        ifindex :: integer(), %might should have rec here if protocol specific header would be more complex
        payload :: list(#nla_attr{})
        }).
%% ovs_flow rec == genlmsg + ovs_header struct
-record(ovsflmsg, {
        cmd :: byte(),
        version :: byte(),
        ifindex :: integer(), %might should have rec here if protocol specific header would be more complex
        payload :: list(#nla_attr{})
        }).
%% ovs_packet rec == genlmsg + ovs_header struct
-record(ovspkmsg, {
        cmd :: byte(),
        version :: byte(),
        ifindex :: integer(), %might should have rec here if protocol specific header would be more complex
        payload :: list(#nla_attr{})
        }).

%% struct nlmsghdr
-record(nlmsg, {
        len   = undefined  :: integer() | undefined,
        type    :: integer(),
%        flags:
        request =1 :: bit(),
        multi   =0 :: bit(),
        ack     =1 :: bit(),
        echo    =0 :: bit(),
        dumpintr=0 :: bit(),
%this flags mean different things depending on content of payload
%        flag0100:: bool(),
%        flag0200:: bool(),
%        flag0400:: bool(),
%        flag0800:: bool(),
        seq     = undefined :: undefined | integer(),
        pid     = undefined :: undefined | integer(),
        payload :: #genlmsg{}
        }).


%netlink types = nlmsgheader.type
-define(NETLINK_ROUTE,           0). %  Routing/device hook
-define(NETLINK_UNUSED,          1). %  Unused number
-define(NETLINK_USERSOCK,        2). %  Reserved for user mode socket protocols
-define(NETLINK_FIREWALL,        3). %  Firewalling hook
-define(NETLINK_SOCK_DIAG,       4). %  socket monitoring
-define(NETLINK_NFLOG,           5). %  netfilter/iptables ULOG
-define(NETLINK_XFRM,            6). %  ipsec
-define(NETLINK_SELINUX,         7). %  SELinux event notifications
-define(NETLINK_ISCSI,           8). %  Open-iSCSI
-define(NETLINK_AUDIT,           9). %  auditing
-define(NETLINK_FIB_LOOKUP,      10).
-define(NETLINK_CONNECTOR,       11).
-define(NETLINK_NETFILTER,       12). %  netfilter subsystem
-define(NETLINK_IP6_FW,          13).
-define(NETLINK_DNRTMSG,         14). %  DECnet routing messages
-define(NETLINK_KOBJECT_UEVENT,  15). %  Kernel messages to userspace
-define(NETLINK_GENERIC,         16).
-define(NETLINK_DM,              17). % not used
-define(NETLINK_SCSITRANSPORT,   18). %  SCSI Transports
-define(NETLINK_ECRYPTFS,        19).
-define(NETLINK_RDMA,            20).
-define(NETLINK_CRYPTO,          21). %  Crypto layer
-define(NETLINK_INET_DIAG,?NETLINK_SOCK_DIAG).

%% genlmsghdr commands enum
-define(CTRL_CMD_UNSPEC, 0).
-define(CTRL_CMD_NEWFAMILY, 1).
-define(CTRL_CMD_DELFAMILY, 2).
-define(CTRL_CMD_GETFAMILY, 3).
-define(CTRL_CMD_NEWOPS, 4).
-define(CTRL_CMD_DELOPS, 5).
-define(CTRL_CMD_GETOPS, 6).
-define(CTRL_CMD_NEWMCAST_GRP, 7).
-define(CTRL_CMD_DELMCAST_GRP, 8).
-define(CTRL_CMD_GETMCAST_GRP, 9).   % unused
-define(CTRL_CMD_MAX, 10).   % unused
%% genl nlattr type enum
-define(CTRL_ATTR_UNSPEC, 0).
-define(CTRL_ATTR_FAMILY_ID, 1).
-define(CTRL_ATTR_FAMILY_NAME, 2).
-define(CTRL_ATTR_VERSION, 3).
-define(CTRL_ATTR_HDRSIZE, 4).
-define(CTRL_ATTR_MAXATTR, 5).
-define(CTRL_ATTR_OPS, 6).
-define(CTRL_ATTR_MCAST_GROUPS, 7).
-define(CTRL_ATTR_MAX, 8).

%%ovs_datapath_cmd enum 
-define(OVS_DP_CMD_UNSPEC,0).
-define(OVS_DP_CMD_NEW,1).
-define(OVS_DP_CMD_DEL,2).
-define(OVS_DP_CMD_GET,3).
-define(OVS_DP_CMD_SET,4).
%%  ovs_datapath_attr enum
-define(OVS_DP_ATTR_UNSPEC,0).
-define(OVS_DP_ATTR_NAME,1).       % name of dp_ifindex netdev
-define(OVS_DP_ATTR_UPCALL_PID,2). % Netlink PID to receive upcalls
-define(OVS_DP_ATTR_STATS,3).

%%ovs_vport_cmd  enum
-define(OVS_VPORT_CMD_UNSPEC,0).
-define(OVS_VPORT_CMD_NEW,1).
-define(OVS_VPORT_CMD_DEL,2).
-define(OVS_VPORT_CMD_GET,3).
-define(OVS_VPORT_CMD_SET,4).
%% enum ovs_vport_type
-define(OVS_VPORT_TYPE_UNSPEC,0).
-define(OVS_VPORT_TYPE_NETDEV,1).   % network device
-define(OVS_VPORT_TYPE_INTERNAL,1). % network device implemented by datapath
%%enum ovs_vport_attr
-define(OVS_VPORT_ATTR_UNSPEC,0).
-define(OVS_VPORT_ATTR_PORT_NO,1).    % u32 port number within datapath
-define(OVS_VPORT_ATTR_TYPE,2).       % u32 OVS_VPORT_TYPE_* constant.
-define(OVS_VPORT_ATTR_NAME,3).       % string name, up to IFNAMSIZ bytes long
-define(OVS_VPORT_ATTR_OPTIONS,4).    % nested attributes, varies by vport type
-define(OVS_VPORT_ATTR_UPCALL_PID,5). % u32 Netlink PID to receive upcalls
-define(OVS_VPORT_ATTR_STATS,6).      % struct ovs_vport_stats

%% enum ovs_flow_cmd
-define(OVS_FLOW_CMD_UNSPEC,0).
-define(OVS_FLOW_CMD_NEW,1).
-define(OVS_FLOW_CMD_DEL,2).
-define(OVS_FLOW_CMD_GET,3).
-define(OVS_FLOW_CMD_SET,4).
%enum ovs_flow_attr
-define(OVS_FLOW_ATTR_UNSPEC,0).
-define(OVS_FLOW_ATTR_KEY,1).       % Sequence of OVS_KEY_ATTR_* attributes.
-define(OVS_FLOW_ATTR_ACTIONS,2).   % Nested OVS_ACTION_ATTR_* attributes.
-define(OVS_FLOW_ATTR_STATS,3).     % struct ovs_flow_stats.
-define(OVS_FLOW_ATTR_TCP_FLAGS,4). % 8-bit OR'd TCP flags.
-define(OVS_FLOW_ATTR_USED,5).      % u64 msecs last used in monotonic time.
-define(OVS_FLOW_ATTR_CLEAR,6).     % Flag to clear stats, tcp_flags, used.

% enum ovs_packet_cmd {
-define(OVS_PACKET_CMD_UNSPEC,0).
 % Kernel-to-user notifications.
-define(OVS_PACKET_CMD_MISS,1).    % Flow table miss.
-define(OVS_PACKET_CMD_ACTION,2).  % OVS_ACTION_ATTR_USERSPACE action.
 % Userspace commands.
-define(OVS_PACKET_CMD_EXECUTE,3). % Apply actions to a packet.

% enum ovs_packet_attr {
-define(OVS_PACKET_ATTR_UNSPEC,0).
-define(OVS_PACKET_ATTR_PACKET,1).      % Packet data.
-define(OVS_PACKET_ATTR_KEY,2).         % Nested OVS_KEY_ATTR_* attributes.
-define(OVS_PACKET_ATTR_ACTIONS,3).     % Nested OVS_ACTION_ATTR_* attributes.
-define(OVS_PACKET_ATTR_USERDATA,4).    % u64 OVS_ACTION_ATTR_USERSPACE arg.
