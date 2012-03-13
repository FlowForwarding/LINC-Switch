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

%% nlattr type enum
-define(CTRL_ATTR_UNSPEC, 0).
-define(CTRL_ATTR_FAMILY_ID, 1).
-define(CTRL_ATTR_FAMILY_NAME, 2).
-define(CTRL_ATTR_VERSION, 3).
-define(CTRL_ATTR_HDRSIZE, 4).
-define(CTRL_ATTR_MAXATTR, 5).
-define(CTRL_ATTR_OPS, 6).
-define(CTRL_ATTR_MCAST_GROUPS, 7).
-define(CTRL_ATTR_MAX, 8).

