#!/bin/sh
# runs on the host; each action runs inside the box container.
#   enroll URL CODE --ca-sha256 HEX   the packaged wrapper, as a tech types it
#   start                             the release as the unit runs it (two caps, mdwe)
#   wait-state open|locked            poll the enforcer until it reports that state
#   probe locked|open                 dns and traffic from the clinic pc
#   guard                             the forward rules behind the time guard (open only)
#   session-start / session-cut       a live rmm session, then check the lock cut it
set -eu
RUN=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/.run
GW=$(cat "$RUN/gw.id")
dx() { docker exec "$GW" "$@"; }
rpc() {
  dx sh -c "cd /var/lib/breakline && RELEASE_TMP=/run/breakline-gateway HOME=/var/lib/breakline \
    setpriv --reuid=breakline --regid=breakline --init-groups /opt/breakline-gateway/bin/gateway rpc '$1'"
}

case $1 in
  enroll)
    shift
    # no systemd in the container: the wrapper's restart is stubbed, the release starts below
    dx env BREAKLINE_SYSTEMCTL_BIN=true breakline-gateway enroll "$@"
    ;;
  start)
    dx sh -c '
      printf "#!/bin/sh\necho yes\n" >/usr/local/bin/timedatectl; chmod 0755 /usr/local/bin/timedatectl
      (
        set -a; . /etc/default/breakline-gateway; set +a
        export BREAKLINE_DATA_DIR=/var/lib/breakline RELEASE_TMP=/run/breakline-gateway \
          HOME=/var/lib/breakline ERL_CRASH_DUMP=/var/lib/breakline/erl_crash.dump
        cd /var/lib/breakline
        exec perl -e "syscall(157, 65, 1, 0, 0, 0) == 0 or die \"prctl: \$!\"; exec @ARGV or die" \
          setpriv --reuid=breakline --regid=breakline --init-groups --no-new-privs \
          --bounding-set=-all,+net_admin,+net_bind_service \
          --inh-caps=-all,+net_admin,+net_bind_service \
          --ambient-caps=-all,+net_admin,+net_bind_service \
          /opt/breakline-gateway/bin/gateway start
      ) >/tmp/gateway.log 2>&1 &'
    for _ in $(seq 1 60); do
      if dx dig +time=1 +tries=1 @127.0.0.1 shop.example.test >/dev/null 2>&1; then echo "gateway up"; exit 0; fi
      sleep 1
    done
    dx tail -30 /tmp/gateway.log
    exit 1
    ;;
  wait-state)
    for _ in $(seq 1 60); do
      s=$(rpc 'IO.write(Gateway.Enforcer.status().state)' 2>/dev/null || true)
      if [ "$s" = "$2" ]; then
        rpc 's = Gateway.Enforcer.status(); d = Gateway.Firewall.snapshot()[:desired]; IO.puts("#{s.state} v#{s.policy_version} #{s.mode} locks_at=#{inspect(d && d.locks_at)}")'
        exit 0
      fi
      sleep 0.5
    done
    echo "gateway never reached $2"
    exit 1
    ;;
  probe)
    q() { dx /run/bl/in client dig +time=2 +tries=1 @8.8.8.8 "$1" | awk '/status:/{gsub(",","",$6); print $6}'; }
    a() { dx /run/bl/in client dig +short +time=2 +tries=1 @8.8.8.8 "$1" | head -1; }
    tcp() { dx /traffic/probe.sh tcp "$1" "$2"; }
    dns_rmm=$(q boot.net.anydesk.com)
    dns_web=$(q shop.example.test)
    web=$(tcp 203.0.113.80 443)
    rmm=$(tcp 198.51.100.10 443)
    p2p=$(tcp 203.0.113.99 6568)
    echo "boot.net.anydesk.com=$dns_rmm shop.example.test=$dns_web web:443=$web rmm-ip:443=$rmm anydesk:6568=$p2p"
    case $2 in
      locked) [ "$dns_rmm" = NXDOMAIN ] && [ "$dns_web" = NOERROR ] && [ "$web" = pass ] && [ "$rmm" = drop ] && [ "$p2p" = drop ] ;;
      open) [ "$dns_rmm" = NOERROR ] && [ "$(a boot.net.anydesk.com)" = 198.51.100.10 ] && [ "$web" = pass ] && [ "$rmm" = pass ] && [ "$p2p" = pass ] ;;
    esac || { echo "PROBE FAILED for $2"; exit 1; }
    ;;
  guard)
    n=$(dx sh -c 'nft list chain inet breakline forward | grep -c "meta time" || true')
    echo "forward rules behind the time guard: $n"
    [ "$n" -gt 0 ] || { echo "NO TIME GUARD WHILE OPEN"; exit 1; }
    ;;
  session-start)
    dx sh -c 'setsid /traffic/probe.sh session 198.51.100.10 443 /tmp/session.out </dev/null >/dev/null 2>&1 &'
    sleep 2
    echo "session echoing, $(dx sh -c 'wc -l </tmp/session.out') lines after 2 s"
    ;;
  session-cut)
    a=$(dx sh -c 'wc -l </tmp/session.out')
    sleep 3
    b=$(dx sh -c 'wc -l </tmp/session.out')
    echo "session lines $a then $b three seconds later"
    [ "$a" = "$b" ] || { echo "SESSION STILL FLOWING"; exit 1; }
    ;;
esac
