#!/bin/bash
# runs inside a throwaway debian:trixie-slim container for deb_docker_test.exs:
# installs the package, starts the release the way the unit would (but without
# systemd as pid 1), and prints "=== name" sections for the test to check.
# expects the .deb in /deb and BREAKLINE_SITE_ID / BREAKLINE_PUBLIC_KEYS in the env.
set -euo pipefail

section() { echo "=== $1"; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# dig, ss and the package's own deps (pulled in by apt from the .deb)
apt-get install -y -qq /deb/breakline-gateway_*.deb bind9-dnsutils iproute2 >/tmp/apt.log 2>&1 ||
  { cat /tmp/apt.log; exit 1; }

section user
getent passwd breakline

section modes
stat -c '%n %U:%G %a' /etc/breakline-gateway /etc/breakline-gateway/cookie \
  /var/lib/breakline /etc/default/breakline-gateway /usr/bin/breakline-gateway \
  /usr/lib/systemd/system/breakline-gateway.service /opt/breakline-gateway/bin/gateway

section cookie_length
wc -c </etc/breakline-gateway/cookie

section cookie_charset
tr -d 'A-Za-z0-9' </etc/breakline-gateway/cookie | wc -c

section cookie_sha
sha256sum </etc/breakline-gateway/cookie | cut -d' ' -f1

section build_cookie
ls /opt/breakline-gateway/releases/COOKIE 2>&1 || true

section opt_writable_or_not_root
find /opt/breakline-gateway \( -perm /022 -o ! -user root \) -print

section conffiles
dpkg-query -W -f='${Conffiles}\n' breakline-gateway

section enabled
ls /etc/systemd/system/multi-user.target.wants/

section verify
if systemd-analyze verify /usr/lib/systemd/system/breakline-gateway.service 2>&1; then
  echo "verify ok"
else
  echo "verify failed"
fi

section security
systemd-analyze security --offline=yes /usr/lib/systemd/system/breakline-gateway.service 2>&1 |
  grep 'Overall exposure level'

# a reinstall keeps the per-box cookie
apt-get install -y -qq --reinstall /deb/breakline-gateway_*.deb >/tmp/apt2.log 2>&1 ||
  { cat /tmp/apt2.log; exit 1; }
section cookie_sha_after_reinstall
sha256sum </etc/breakline-gateway/cookie | cut -d' ' -f1

# no systemd as pid 1 in the container, so ntp sync status comes from a stand-in
printf '#!/bin/sh\necho yes\n' >/usr/local/bin/timedatectl
chmod 0755 /usr/local/bin/timedatectl

cat >/etc/default/breakline-gateway <<EOF
BREAKLINE_SITE_ID=$BREAKLINE_SITE_ID
BREAKLINE_PUBLIC_KEYS=$BREAKLINE_PUBLIC_KEYS
BREAKLINE_LAN_INTERFACES=eth0
BREAKLINE_DEFAULT_MODE=monitor
EOF

# what the unit sets up: RuntimeDirectory, the fixed env, the working directory
install -d -o breakline -g breakline -m 0700 /run/breakline-gateway

(
  set -a
  . /etc/default/breakline-gateway
  set +a
  export BREAKLINE_DATA_DIR=/var/lib/breakline RELEASE_TMP=/run/breakline-gateway \
    HOME=/var/lib/breakline ERL_CRASH_DUMP=/var/lib/breakline/erl_crash.dump
  cd /var/lib/breakline
  # PR_SET_MDWE (prctl 65, refuse exec gain), which is what MemoryDenyWriteExecute=
  # uses on this kernel, then drop to the service user with only the unit's two
  # capabilities, ambient and bounding, and no_new_privs
  exec perl -e 'syscall(157, 65, 1, 0, 0, 0) == 0 or die "prctl: $!"; exec @ARGV or die' \
    setpriv --reuid=breakline --regid=breakline --init-groups --no-new-privs \
    --bounding-set=-all,+net_admin,+net_bind_service \
    --inh-caps=-all,+net_admin,+net_bind_service \
    --ambient-caps=-all,+net_admin,+net_bind_service \
    /opt/breakline-gateway/bin/gateway start
) >/tmp/gateway.log 2>&1 &

ready=no
for _ in $(seq 1 60); do
  if dig +time=1 +tries=1 @127.0.0.1 use-application-dns.net >/dev/null 2>&1; then
    ready=yes
    break
  fi
  sleep 1
done

section ready
echo "$ready"
if [ "$ready" != yes ]; then
  cat /tmp/gateway.log
  exit 1
fi

# the enforcer applies its first state right after boot
sleep 2

section caps
beam=""
for p in /proc/[0-9]*; do
  if [ "$(cat "$p/comm" 2>/dev/null)" = beam.smp ]; then beam="${p#/proc/}"; break; fi
done
grep -E '^(Uid|CapEff|CapBnd|CapAmb|NoNewPrivs)' "/proc/$beam/status"

section listening
ss -Hlntup | awk '{print $1, $5}' | sort

section nft
nft -j list table inet breakline | head -c 200000

section dig_canary
dig +time=2 +tries=2 @127.0.0.1 use-application-dns.net | grep -o 'status: [A-Z]*'

section dig_forwarded
dig +time=3 +tries=2 @127.0.0.1 deb.debian.org | grep -o 'status: [A-Z]*' || echo "status: none"

section dist_remote
ip="$(hostname -I | awk '{print $1}')"
for port in 4369 4370; do
  if timeout 2 bash -c "</dev/tcp/$ip/$port" 2>/dev/null; then
    echo "$ip:$port open"
  else
    echo "$ip:$port closed"
  fi
done
if timeout 2 bash -c "</dev/tcp/127.0.0.1/4370" 2>/dev/null; then
  echo "127.0.0.1:4370 open"
else
  echo "127.0.0.1:4370 closed"
fi

section status
breakline-gateway status 2>&1

section log
cat /tmp/gateway.log
