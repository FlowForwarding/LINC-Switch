from ryu.base import app_manager
from ryu.controller import ofp_event
from ryu.controller.handler import CONFIG_DISPATCHER, MAIN_DISPATCHER
from ryu.controller.handler import set_ev_cls
from ryu.ofproto import ofproto_v1_3
from ryu.lib.packet import packet
from ryu.lib.packet import ethernet

import time, threading
import sys

class SimpleTapWithQueuesChecking(app_manager.RyuApp):
    """
    This works for a sys.config file for LINC-Switch like the following:
    [{linc,
    [{of_config,enabled},
    {capable_switch_ports,
    [{port,1,[{interface,"eth2"}]},{port,2,[{interface,"eth3"}]}]},
    {capable_switch_queues, [
    {queue, 1, [{min_rate, 0}, {max_rate, 800}]},
    {queue, 2, [{min_rate, 0}, {max_rate, 200}]}]},
    {logical_switches,
    [{switch,0,
    [{backend,linc_us4},
    {controllers,[{"Switch0-Controller","localhost",6633,tcp}]},
    {controllers_listener,disabled},
    {queues_status,enabled},
    {ports,[{port,1,{queues,[]}},{port,2,{queues,[1,2]}}]}]}]}]},
    {enetconf,
    [{capabilities,[{base,{1,1}},{startup,{1,0}},{'writable-running',{1,0}}]},
    {callback_module,linc_ofconfig},
    {sshd_ip,any},
    {sshd_port,1830},
    {sshd_user_passwords,[{"linc","linc"}]}]},
    {epcap,
    [{verbose, false},
    {stats_interval, 10},
    {buffer_size, 73400320}]},
    {lager,
    [{handlers,
    [{lager_console_backend,debug},
    {lager_file_backend,
    [{"log/error.log",error,10485760,"$D0",5},
    {"log/debug.log",debug,10485760,"$D0",5},
    {"log/console.log",info,10485760,"$D0",5}]}]}]},
    {sasl,
    [{sasl_error_logger,{file,"log/sasl-error.log"}},
    {errlog_type,error},
    {error_logger_mf_dir,"log/sasl"},
    {error_logger_mf_maxbytes,1048576000000},
    {error_logger_mf_maxfiles,5}]},
    {sync,[{excluded_modules,[procket]}]}].
    """
    OFP_VERSIONS = [ofproto_v1_3.OFP_VERSION]
    port_without_queues = 1
    port_with_queues = 2
    ssh_queue = 1
    udp_queue = 2

    def __init__(self, *args, **kwargs):
        super(SimpleTapWithQueuesChecking, self).__init__(self, *args, **kwargs)
        # Nornally we would read queues ID's from queue_config_reply but it's
        # not implemented in LINC and queues list is always empty
        self.queues = [1,2]

    @set_ev_cls(ofp_event.EventOFPSwitchFeatures, CONFIG_DISPATCHER)
    def switch_features_handler(self, ev):
        self.datapath = ev.msg.datapath
        self.ofproto = self.datapath.ofproto
        self.parser = self.datapath.ofproto_parser
        # Get queue config always returns no queues for LINC
        # self.send_queue_get_config_requets()

    @set_ev_cls(ofp_event.EventOFPPortDescStatsReply, CONFIG_DISPATCHER)
    def port_desc_stats_reply_handler(self, ev):
        if len(ev.msg.body) != 2:
            raise AssertionError("Works only for two ports")
        self.match_on_scp_and_forward_through_queue(self.port_without_queues,
                                                    self.port_with_queues,
                                                    self.ssh_queue)
        self.match_on_udp_forward_through_queue(self.port_without_queues,
                                                self.port_with_queues,
                                                self.udp_queue)
        self.forward_between_ports(self.port_without_queues,
                                   self.port_with_queues)
        self.forward_between_ports(self.port_with_queues,
                                   self.port_without_queues)
        self.schedule_queue_stats_request(self.port_with_queues, self.ofproto.OFPQ_ALL)

    # def send_queue_get_config_requets(self):
    #     request = self.parser.OFPQueueGetConfigRequest(self.datapath, 1)
    #     self.datapath.send_msg(request)

    @set_ev_cls(ofp_event.EventOFPQueueGetConfigReply, MAIN_DISPATCHER)
    def queue_get_config_reply_handler(self, ev):
        msg = ev.msg
        self.logger.info('OFPQueueGetConfigReply received: port=%s queues=%s',
                         msg.port, msg.queues)
        if len(msg.queues) != 2:
            raise AssertionError("Works only for two queues attached to port no 2")

    def schedule_queue_stats_request(self, port, queue_id):
        threading.Timer(10, self.send_queue_stats_request, [port, queue_id]).start()

    def send_queue_stats_request(self, port, queue_id):
        request = self.parser.OFPQueueStatsRequest(self.datapath,
                                                   flags = 0,
                                                   port_no = port,
                                                   queue_id = queue_id)
        self.datapath.send_msg(request)


    @set_ev_cls(ofp_event.EventOFPQueueStatsReply, MAIN_DISPATCHER)
    def queue_stats_reply_handler(self, ev):
        for qstat in ev.msg.body:
            self.logger.info("QueueId: %d, tx_bytes: %d, tx_packets: %d",
                             qstat.queue_id, qstat.tx_bytes, qstat.tx_packets)
        self.logger.info("=========================================")
        self.schedule_queue_stats_request(2, self.ofproto.OFPQ_ALL)

    def match_on_scp_and_forward_through_queue(self, ingress, egress, queue_id):
        actions = self.set_queue_and_output_actions(queue_id, egress)
        inst = self.apply_actions_instructions(actions)
        flow_mod = self.parser.OFPFlowMod(
            datapath = self.datapath,
            priority = 10,
            match = self.parser.OFPMatch(in_port = ingress,
                                         tcp_dst = 22,
                                         ip_proto = 6,
                                         eth_type = 0x0800),
            instructions = inst)
        self.datapath.send_msg(flow_mod)

    def match_on_udp_forward_through_queue(self, ingress, egress, queue_id):
        actions = self.set_queue_and_output_actions(queue_id, egress)
        inst = self.apply_actions_instructions(actions)
        flow_mod = self.parser.OFPFlowMod(
            datapath = self.datapath,
            priority = 10,
            match = self.parser.OFPMatch(in_port = ingress,
                                         ip_proto = 17,
                                         eth_type = 0x0800),
                                         instructions = inst)
        self.datapath.send_msg(flow_mod)

    def forward_between_ports(self, ingress, egress):
        actions = self.parser.OFPActionOutput(egress),
        inst = self.apply_actions_instructions(actions)
        flow_mod = self.parser.OFPFlowMod(
            datapath = self.datapath,
            priority = 5,
            match = self.parser.OFPMatch(in_port = ingress),
            instructions = inst)
        self.datapath.send_msg(flow_mod)

    def set_queue_and_output_actions(self, queue_id, port):
        return [self.parser.OFPActionSetQueue(queue_id),
                self.parser.OFPActionOutput(port)]

    def apply_actions_instructions(self, actions):
        return [self.parser.OFPInstructionActions(
            self.ofproto.OFPIT_APPLY_ACTIONS, actions)]
