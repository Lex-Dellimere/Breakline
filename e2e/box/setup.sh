#!/bin/sh
# inside the box container: install the .deb as a pilot box would, keep eth0 (the docker
# network, where cloud.test lives) for the uplink, and build the traffic suite's router
# topology: a clinic pc behind lan0 and a fake internet behind wan0.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends /deb/breakline-gateway_*.deb \
  dnsmasq-base iproute2 dnsutils ncat socat procps conntrack >/tmp/apt.log 2>&1 ||
  { tail -20 /tmp/apt.log; exit 1; }

# the internet is the fake one behind wan0; eth0 keeps only its own subnet (the cloud)
ip route del default
ip -6 route flush default 2>/dev/null || true

/traffic/topology.sh router

cat >/etc/default/breakline-gateway <<ENV
BREAKLINE_LAN_INTERFACES=lan0
BREAKLINE_UPSTREAMS=10.20.0.2
BREAKLINE_DEFAULT_MODE=monitor
ENV
install -d -o breakline -g breakline -m 0700 /run/breakline-gateway
echo "box ready"
