#!/bin/sh
# builds the traffic test topology inside the throwaway container.
#
#   topology.sh router   client --lan0 [gateway] wan0-- upstream
#   topology.sh bridge   client --lan0 [br0 gateway] wan0-- upstream, one subnet
#
# the container's own namespace is the gateway. client and upstream are network
# namespaces held open by a sleeping process (ip netns add needs a mount, which the
# container may not do); their pids are in /run/bl/<name>.pid and /run/bl/in runs a
# command inside one. upstream is the fake internet: dnsmasq plus listeners, with the
# documentation ranges and the public resolver ips routed to its loopback.
set -eu

topology=$1
bl=/run/bl
mkdir -p $bl

cat > $bl/in <<'IN'
#!/bin/sh
ns=$1
shift
exec nsenter -t "$(cat /run/bl/$ns.pid)" -n -- "$@"
IN
chmod +x $bl/in

for ns in client upstream; do
  unshare -n sleep infinity &
  echo $! > $bl/$ns.pid
done

# wait until both sleepers are in their own namespace
for ns in client upstream; do
  until [ "$(readlink /proc/"$(cat $bl/$ns.pid)"/ns/net)" != "$(readlink /proc/self/ns/net)" ]; do
    sleep 0.05
  done
done

at() { $bl/in "$@"; }

ip link add lan0 type veth peer name c0
ip link add wan0 type veth peer name u0
ip link set c0 netns "$(cat $bl/client.pid)"
ip link set u0 netns "$(cat $bl/upstream.pid)"

for ns in client upstream; do at $ns ip link set lo up; done
at client ip link set c0 up
at upstream ip link set u0 up
ip link set lo up
ip link set lan0 up
ip link set wan0 up

case $topology in
  router)
    ip addr add 10.10.0.1/24 dev lan0
    ip addr add fd00:10::1/64 dev lan0 nodad
    ip addr add 10.20.0.1/24 dev wan0
    ip addr add fd00:20::1/64 dev wan0 nodad
    ip route add default via 10.20.0.2
    ip -6 route add default via fd00:20::2

    at client ip addr add 10.10.0.2/24 dev c0
    at client ip addr add fd00:10::2/64 dev c0 nodad
    at client ip route add default via 10.10.0.1
    at client ip -6 route add default via fd00:10::1

    at upstream ip addr add 10.20.0.2/24 dev u0
    at upstream ip addr add fd00:20::2/64 dev u0 nodad
    at upstream ip route add 10.10.0.0/24 via 10.20.0.1
    at upstream ip -6 route add fd00:10::/64 via fd00:20::1
    dns=10.20.0.2
    ;;
  bridge)
    ip link add br0 type bridge
    ip link set lan0 master br0
    ip link set wan0 master br0
    ip link set br0 up
    ip addr add 10.30.0.1/24 dev br0
    ip addr add fd00:30::1/64 dev br0 nodad
    ip route add default via 10.30.0.3
    ip -6 route add default via fd00:30::3

    at client ip addr add 10.30.0.2/24 dev c0
    at client ip addr add fd00:30::2/64 dev c0 nodad
    at client ip route add default via 10.30.0.3
    at client ip -6 route add default via fd00:30::3

    # upstream is the site's router as well as the internet
    at upstream ip addr add 10.30.0.3/24 dev u0
    at upstream ip addr add fd00:30::3/64 dev u0 nodad
    dns=10.30.0.3
    ;;
  *)
    echo "unknown topology $topology" >&2
    exit 1
    ;;
esac

# the fake internet: these destinations are local to upstream
for net in 198.51.100.0/24 203.0.113.0/24 192.0.2.0/24 8.8.8.8/32 1.1.1.1/32; do
  at upstream ip route add local $net dev lo
done
for net in 2001:db8::/32 2001:4860:4860::8888/128 2606:4700:4700::1111/128; do
  at upstream ip -6 route add local $net dev lo
done
# a resolver that is not the gateway, bound where a client might send its queries
at upstream ip addr add 8.8.8.8/32 dev lo
at upstream ip addr add 2001:4860:4860::8888/128 dev lo nodad

# the real upstream: catalog names, a vanity cname into a catalog domain and a
# non-catalog name, all on documentation addresses
at upstream dnsmasq --conf-file=/dev/null --no-resolv --no-hosts --bind-interfaces \
  --listen-address=$dns --pid-file=$bl/dnsmasq.pid --local-ttl=300 \
  --host-record=boot.net.anydesk.com,198.51.100.10,2001:db8::10 \
  --host-record=relay-01.net.anydesk.com,198.51.100.11,2001:db8::11 \
  --host-record=live.screenconnect.com,198.51.100.20,2001:db8::20 \
  --host-record=instance-abc-relay.screenconnect.com,198.51.100.21,2001:db8::21 \
  --cname=remote.vanity.test,instance-abc-relay.screenconnect.com \
  --host-record=shop.example.test,203.0.113.80,2001:db8::80

# the rogue resolver answers everything with 192.0.2.66, so any answer from it
# means a query got past the gateway
at upstream dnsmasq --conf-file=/dev/null --no-resolv --no-hosts --bind-interfaces \
  --listen-address=8.8.8.8 --listen-address=2001:4860:4860::8888 \
  --pid-file=$bl/rogue.pid --address=/#/192.0.2.66 --address=/#/2001:db8:bad::66

# echo listeners on tcp, sinks that log every datagram on udp
for port in 80 443 853 5938 6568; do
  at upstream setsid ncat -lk -e /bin/cat $port </dev/null >/dev/null 2>&1 &
done
for port in 443 853 5938; do
  at upstream setsid socat -u UDP6-RECV:$port,ipv6only=0 OPEN:$bl/udp-$port.log,creat,append \
    </dev/null >/dev/null 2>&1 &
done

# no systemd in here: the gateway asks timedatectl whether the clock is synced
printf '#!/bin/sh\necho yes\n' > /usr/local/bin/timedatectl
chmod +x /usr/local/bin/timedatectl

# wait for the listeners
for port in 80 443 853 5938 6568; do
  until at upstream ss -Hltn "sport = :$port" | grep -q .; do sleep 0.05; done
done
for port in 443 853 5938; do
  until at upstream ss -Hlun "sport = :$port" | grep -q .; do sleep 0.05; done
done
echo "topology $topology ready"
