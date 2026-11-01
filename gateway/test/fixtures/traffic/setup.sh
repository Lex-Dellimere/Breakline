#!/bin/sh
# installs the tools, cuts the container off from docker's network and builds the
# topology. usage: setup.sh router|bridge
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  nftables dnsmasq-base iproute2 dnsutils ncat socat conntrack procps >/dev/null

# apt was the only reason for a network. from here on the only links are the veths
ip route del default
ip -6 route flush default 2>/dev/null || true
ip link set eth0 down

exec /traffic/topology.sh "$1"
