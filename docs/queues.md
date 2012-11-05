## Experimental support for queues.

### Port configuration spec

``` erlang
[{PortId :: integer(),
  [{rate, {integer(), bps | kbps | kibps | mbps | mibps | gbps | gibps}} |
   {queues, [{QueueId :: integer(), [{min_rate, integer()} |
                                     {max_rate, integer()}]}]}]}]
```

### Example setup

``` erlang
{queues,
 [
  {1, [
       {rate, {100, mbps}},
       {queues, []}
      ]},
  {2, [
       {rate, {1, gbps}},
       {queues, [{1, [{min_rate, 250},
                      {max_rate, 500}]}]}
      ]}
 ]}
```