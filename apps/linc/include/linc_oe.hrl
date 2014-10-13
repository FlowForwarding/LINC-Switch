-record(och_sigtype, {value :: binary()}).
-type och_sigtype() :: #och_sigtype{}.

-record(och_sigid, {
          grid_type :: binary(),
          channel_spacing :: binary(),
          channel_number :: binary(),
          spectral_width :: binary()
         }).
-type och_sigid() :: #och_sigid{}.



