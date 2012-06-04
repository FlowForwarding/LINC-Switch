#!/bin/bash

sudo tunctl -t tap-out
sudo ifconfig tap-out promisc 0.0.0.0 up
sudo brctl addif br-out tap-out
