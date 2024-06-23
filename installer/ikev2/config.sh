#!/bin/bash

VPNHOST="vpn.mydomain.com"
VPNHOSTIP=$(dig -4 +short "${VPNHOST}")
VPNDNS="1.1.1.1,1.0.0.1"
TZONE=$(cat /etc/timezone)
LANG="en_US.UTF-8"

ETH0=$(ip route get 1.1.1.1 | grep -oP ' dev \K\S+')
LSB_RELEASE=$(lsb_release -rs)
SSHPORT=$(lsof -i -P -n -sTCP:LISTEN | awk '/sshd/ {print $9}' |  awk -F '*:' '{print $NF}' | head -n 1)
VPNIPPOOL="10.101.0.0/16"