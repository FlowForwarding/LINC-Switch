from ryu.base import app_manager
from ryu.controller import ofp_event
from ryu.controller.handler import CONFIG_DISPATCHER, MAIN_DISPATCHER
from ryu.controller.handler import set_ev_cls
from ryu.ofproto import ofproto_v1_3
from ryu.lib.packet import packet
from ryu.lib.packet import ethernet

from itertools import permutations

class SimpleTapWithTwoPorts(app_manager.RyuApp):
    OFP_VERSIONS = [ofproto_v1_3.OFP_VERSION]

    def __init__(self, *args, **kwargs):
        super(SimpleTapWithTwoPorts, self).__init__(*args, **kwargs)
        self.mac_to_port = {}

    @set_ev_cls(ofp_event.EventOFPSwitchFeatures, CONFIG_DISPATCHER)
    def switch_features_handler(self, ev):
        self.datapath = ev.msg.datapath
        self.ofproto = self.datapath.ofproto
        self.parser = self.datapath.ofproto_parser
        self.logger.info('OFPSwitchFeatures received: '
                          'datapath_id=0x%016x n_buffers=%d '
                          'n_tables=%d auxiliary_id=%d '
                          'capabilities=0x%08x',
                          ev.msg.datapath_id, ev.msg.n_buffers, ev.msg.n_tables,
                          ev.msg.auxiliary_id, ev.msg.capabilities)

    @set_ev_cls(ofp_event.EventOFPPortDescStatsReply, CONFIG_DISPATCHER)
    def port_desc_stats_reply_handler(self, ev):
        if len(ev.msg.body) != 2:
            raise AssertionError("Works only for two ports")
        ports = [p.port_no for p in ev.msg.body]
        [self.add_flow_to_forward_between_two_ports(ingress, egress)
         for (ingress, egress) in permutations(ports, 2)]

    def add_flow_to_forward_between_two_ports(self, ingress, egress):
        actions = [self.parser.OFPActionOutput(port = egress)]
        instructions = [self.parser.OFPInstructionActions(
            self.ofproto.OFPIT_APPLY_ACTIONS, actions)]
        flow_mod = self.parser.OFPFlowMod(
            datapath = self.datapath,
            priority = 0,
            match = self.parser.OFPMatch(in_port = ingress),
            instructions = instructions)
        self.datapath.send_msg(flow_mod)
