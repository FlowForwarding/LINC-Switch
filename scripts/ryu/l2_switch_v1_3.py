"""Simple layer-2 learning switch logic using OpenFlow Protocol v1.3."""

from ryu.base.app_manager import RyuApp
from ryu.controller.ofp_event import EventOFPSwitchFeatures
from ryu.controller.ofp_event import EventOFPPacketIn
from ryu.controller.handler import set_ev_cls
from ryu.controller.handler import CONFIG_DISPATCHER
from ryu.controller.handler import MAIN_DISPATCHER
from ryu.ofproto.ofproto_v1_2 import OFPG_ANY
from ryu.ofproto.ofproto_v1_3 import OFP_VERSION
from ryu.lib.mac import haddr_to_bin

class L2Switch(RyuApp):
    OFP_VERSIONS = [OFP_VERSION]

    def __init__(self, *args, **kwargs):
        super(L2Switch, self).__init__(*args, **kwargs)

    @set_ev_cls(EventOFPSwitchFeatures, CONFIG_DISPATCHER)
    def switch_features_handler(self, ev):
        """Handle switch features reply to install table miss flow entries."""
        datapath = ev.msg.datapath
        [self.install_table_miss(datapath, n) for n in [0, 1]]

    def create_match(self, parser, fields):
        """Create OFP match struct from the list of fields."""
        match = parser.OFPMatch()
        for a in fields:
            match.append_field(*a)
        return match

    def create_flow_mod(self, datapath, priority,
                        table_id, match, instructions):
        """Create OFP flow mod message."""
        ofproto = datapath.ofproto
        flow_mod = datapath.ofproto_parser.OFPFlowMod(datapath, 0, 0, table_id,
                                                      ofproto.OFPFC_ADD, 0, 0,
                                                      priority,
                                                      ofproto.OFPCML_NO_BUFFER,
                                                      ofproto.OFPP_ANY,
                                                      OFPG_ANY, 0,
                                                      match, instructions)
        return flow_mod
    
    def install_table_miss(self, datapath, table_id):
        """Create and install table miss flow entries."""
        parser = datapath.ofproto_parser
        ofproto = datapath.ofproto
        empty_match = parser.OFPMatch()
        output = parser.OFPActionOutput(ofproto.OFPP_CONTROLLER,
                                        ofproto.OFPCML_NO_BUFFER)
        write = parser.OFPInstructionActions(ofproto.OFPIT_WRITE_ACTIONS,
                                             [output])
        instructions = [write]
        flow_mod = self.create_flow_mod(datapath, 0, table_id,
                                        empty_match, instructions)
        datapath.send_msg(flow_mod)

    @set_ev_cls(EventOFPPacketIn, MAIN_DISPATCHER)
    def _packet_in_handler(self, ev):
        """Handle packet_in events."""
        msg = ev.msg
        datapath = msg.datapath
        ofproto = datapath.ofproto
        table_id = msg.table_id
        fields = msg.match.fields

        # Extract fields
        for f in fields:
            if f.header == ofproto.OXM_OF_IN_PORT:
                in_port = f.value
            elif f.header == ofproto.OXM_OF_ETH_SRC:
                eth_src = f.value
            elif f.header == ofproto.OXM_OF_ETH_DST:
                eth_dst = f.value

        # Install flow entries
        if table_id == 0:
            print "installing new source mac received from port", in_port
            self.install_src_entry(datapath, in_port, eth_src)
            self.install_dst_entry(datapath, in_port, eth_src)

        # Flood
        self.flood(datapath, msg.data)

    def install_src_entry(self, datapath, in_port, eth_src):
        """Install flow entry matching on eth_src in table 0."""
        parser = datapath.ofproto_parser
        ofproto = datapath.ofproto
        match = self.create_match(parser,
                                  [(ofproto.OXM_OF_IN_PORT, in_port),
                                   (ofproto.OXM_OF_ETH_SRC, eth_src)])
        goto = parser.OFPInstructionGotoTable(1)
        flow_mod = self.create_flow_mod(datapath, 123, 0, match, [goto])
        datapath.send_msg(flow_mod)

    def install_dst_entry(self, datapath, in_port, eth_src):
        """Install flow entry matching on eth_dst in table 1."""
        parser = datapath.ofproto_parser
        ofproto = datapath.ofproto
        match = self.create_match(parser, [(ofproto.OXM_OF_ETH_DST, eth_src)])
        output = parser.OFPActionOutput(in_port, ofproto.OFPCML_NO_BUFFER)
        write = parser.OFPInstructionActions(ofproto.OFPIT_WRITE_ACTIONS,
                                             [output])
        flow_mod = self.create_flow_mod(datapath, 123, 1, match, [write])
        datapath.send_msg(flow_mod)

    def flood(self, datapath, data):
        """Send a packet_out with output to all ports."""
        parser = datapath.ofproto_parser
        ofproto = datapath.ofproto
        output_all = parser.OFPActionOutput(ofproto.OFPP_ALL,
                                            ofproto.OFPCML_NO_BUFFER)
        packet_out = parser.OFPPacketOut(datapath, 0xffffffff,
                                         ofproto.OFPP_CONTROLLER,
                                         [output_all], data)
        datapath.send_msg(packet_out)
