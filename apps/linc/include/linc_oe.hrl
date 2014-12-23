-record(och_sigtype, {value :: binary()}).
-type och_sigtype() :: #och_sigtype{}.

-record(och_sigid, {
          grid_type = <<0:8>> :: binary(),
          channel_spacing = <<0:8>> :: binary(),
          channel_number = <<0:16>> :: binary(),
          spectral_width = <<0:16>> :: binary()
         }).
-type och_sigid() :: #och_sigid{}.



