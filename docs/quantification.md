# Quantification #
This page describes LINC's resources consumption.

## Adding resources  ##
To add ports and logical switches to the LINC instance you have to edit `rel/files/sys.config` file. You will there comments on how to do this.

## Memory consumptions ##
LINC has three major components that make up memory consumption:
* ports and logical switches,
* flow entries.

### Average values ###
On average a LINC port consumes ~ 11 kb.
Memory consumed by logical switches is not linear. For example a logical switch with 20 ports consumes:
* ~ 1200 kb if we have 10 such switches
* ~ 2200 kb if we have 20 such switches
* ~ 5100 kb if we have 30 such switches

### Measuring ###
There is a script `scripts/mem_usage_test` that helps with estimating memory requirements.

To measure how much memory one port will take use it as follows:
```bash
./scripts/mem_usage_test ports <interval> <max_ports_number>
```
In the test amount of ports indicated by the `interval` will be added to the LINC instance in each iteration until reaching the `max_port_number`. The script produces output file `ports.test` that has three columns:
* number of ports in the LINC instance,
* memory consumed by the LINC instance,
* memory consumed by this LINC instance minus the amount of memory consumed in the previous test.
At the bottom of the file there's a summary line.

To memory how much memory one logical switch witch fixed number of ports invoke the script as follows:

```bash
./scripts/mem_usage_test switches <ports_per_switch> <max_switches>
```
In this test an additional logical switch will be added to the LINC instance in each iteration until reaching the `max_switches`. The test produces an output file that has three columns:
* number of logical switches started in a LINC instance,
* memory consumed by the LINC instance,
* memory consumed by this LINC instance minus the amount of memory consumed in the previous test.
At the bottom of the file there's a summary line.

## Tuning Erlang VM  ##
Each logical switch allocates approximately 280 ETS tables. To change this value you have to edit `rel/files/vm.args` file and change the value of ERL_MAX_ETS_TABLES. You find details in the file.

## TODO  ##
Measure flow entries.
