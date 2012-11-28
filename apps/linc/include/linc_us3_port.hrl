-record(state, {port :: port(),
                port_ref :: pid(),
                socket :: integer(),
                ifindex :: integer(),
                epcap_pid :: pid(),
                interface :: string(),
                ofs_port_no :: ofp_port_no(),
                rate_bps :: integer(),
                throttling_ets :: ets:tid()}).
