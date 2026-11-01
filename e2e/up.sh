#!/bin/sh
# full-stack check, setup: a throwaway docker network with postgres 17, the cloud prod release
# and a pilot box installed from the .deb, with a clinic pc and a fake internet behind it.
# everything generated (pki, secrets, ids) goes to e2e/.run, which is git-ignored.
# needs: docker, the cloud release (MIX_ENV=prod mix release in cloud/) and the .deb
# (mix gateway.package.deb in gateway/). only the browser port is published, on 127.0.0.1.
set -eu
E=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$E/.." && pwd)
RUN=$E/.run
REL=$ROOT/cloud/_build/prod/rel/cloud
DEB=$(ls "$ROOT"/gateway/_build/prod/breakline-gateway_*_amd64.deb 2>/dev/null | head -1)

[ -x "$REL/bin/cloud" ] || { echo "no cloud release: cd cloud && MIX_ENV=prod mix release" >&2; exit 1; }
[ -n "$DEB" ] || { echo "no .deb: cd gateway && mix gateway.package.deb" >&2; exit 1; }

"$E/down.sh" >/dev/null
umask 077
mkdir -p "$RUN/pki" "$RUN/secrets" "$RUN/deb"
cp "$DEB" "$RUN/deb/"

# the 4011 ca, made the way docs/DEPLOY.md says. its key is never mounted anywhere
if [ ! -s "$RUN/pki/gateway-tls.pem" ]; then
  (
    cd "$RUN/pki"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out gateway-ca.key 2>/dev/null
    openssl req -x509 -new -sha256 -key gateway-ca.key -out gateway-ca.pem -days 3650 \
      -subj "/CN=Breakline gateway CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out gateway-tls.key 2>/dev/null
    openssl req -new -sha256 -key gateway-tls.key -subj "/CN=cloud.test" -out gateway-tls.csr
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:cloud.test\n' >gateway-tls.ext
    openssl x509 -req -sha256 -in gateway-tls.csr -CA gateway-ca.pem -CAkey gateway-ca.key \
      -CAcreateserial -days 825 -extfile gateway-tls.ext -out gateway-tls.pem 2>/dev/null
    # read by the cloud container's root-run release only
    chmod 0644 gateway-ca.pem gateway-tls.pem gateway-tls.key
  )
fi

S=$RUN/secrets
if [ ! -s "$S/cookie" ]; then
  for s in secret_key_base token_signing_secret; do openssl rand -base64 48 | tr -d '\n' >"$S/$s"; done
  openssl rand -base64 32 | tr -d '\n' >"$S/notifications_key"
  openssl rand -hex 32 >"$S/cookie"
  openssl rand -base64 24 | tr -d '\n/+=' >"$S/demo_password"
  openssl rand -hex 16 >"$S/pg_password"
  (cd "$ROOT/cloud" && mix cloud.signer.keygen --path "$S/signer_ed25519.json" >/dev/null)
fi

net="bl-e2e-$(openssl rand -hex 4)"
docker network create "$net" >/dev/null
echo "$net" >"$RUN/net"

docker run -d --rm --network "$net" --network-alias pg \
  -e POSTGRES_USER=breakline -e POSTGRES_DB=breakline \
  -e POSTGRES_PASSWORD="$(cat "$S/pg_password")" postgres:17 >"$RUN/pg.id"

cat >"$RUN/cloud.env" <<EOF
DATABASE_URL=ecto://breakline:$(cat "$S/pg_password")@pg/breakline
SECRET_KEY_BASE=$(cat "$S/secret_key_base")
TOKEN_SIGNING_SECRET=$(cat "$S/token_signing_secret")
NOTIFICATIONS_KEY=$(cat "$S/notifications_key")
RELEASE_COOKIE=$(cat "$S/cookie")
WEBAUTHN_RP_ID=localhost
WEBAUTHN_ORIGIN=http://localhost:4050
PHX_HOST=localhost
PHX_SERVER=true
PORT=4050
GATEWAY_PORT=4051
GATEWAY_URL=https://cloud.test:4051
GATEWAY_TLS_CERT=/e2e/pki/gateway-tls.pem
GATEWAY_TLS_KEY=/e2e/pki/gateway-tls.key
GATEWAY_TLS_CA=/e2e/pki/gateway-ca.pem
SIGNER_KEY_PATH=/e2e/secrets/signer_ed25519.json
RELEASE_TMP=/tmp/cloud
LANG=C.UTF-8
EOF

docker run -d --rm --init --network "$net" --network-alias cloud.test \
  -p 127.0.0.1:4050:4050 \
  -v "$REL:/opt/cloud:ro" \
  -v "$RUN/pki/gateway-tls.pem:/e2e/pki/gateway-tls.pem:ro" \
  -v "$RUN/pki/gateway-tls.key:/e2e/pki/gateway-tls.key:ro" \
  -v "$RUN/pki/gateway-ca.pem:/e2e/pki/gateway-ca.pem:ro" \
  -v "$S/signer_ed25519.json:/e2e/secrets/signer_ed25519.json:ro" \
  --env-file "$RUN/cloud.env" \
  debian:trixie-slim sh -c '
    apt-get update -qq >/dev/null &&
    apt-get install -y -qq --no-install-recommends libssl3t64 libstdc++6 libtinfo6 openssl ca-certificates >/dev/null &&
    mkdir -p /tmp/cloud &&
    until /opt/cloud/bin/migrate >/tmp/migrate.log 2>&1; do sleep 1; done &&
    exec /opt/cloud/bin/server' >"$RUN/cloud.id"

for _ in $(seq 1 120); do
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4050/ 2>/dev/null | grep -q 200 && break
  sleep 2
done

# seed through the release: copied in rather than bind-mounted, so edits always land
C=$(cat "$RUN/cloud.id")
docker cp "$E/seed.exs" "$C:/tmp/seed.exs"
docker cp "$S/demo_password" "$C:/tmp/demo_password"
docker exec "$C" sh -c 'RELEASE_TMP=/tmp/cloud /opt/cloud/bin/cloud rpc "Code.eval_file(\"/tmp/seed.exs\")"' 2>&1 |
  grep "^SITE=" >"$RUN/seed.out"

docker run -d --rm --init --network "$net" --cap-add NET_ADMIN --cap-add SYS_ADMIN \
  --sysctl net.ipv4.ip_forward=1 --sysctl net.ipv6.conf.all.forwarding=1 \
  -v "$RUN/deb:/deb:ro" -v "$E/box:/box:ro" -v "$ROOT/gateway/test/fixtures/traffic:/traffic:ro" \
  debian:trixie-slim sh -c '/box/setup.sh >/tmp/setup.log 2>&1; echo "setup exit $?" >>/tmp/setup.log; sleep infinity' \
  >"$RUN/gw.id"
GW=$(cat "$RUN/gw.id")
for _ in $(seq 1 180); do docker exec "$GW" grep -q "setup exit" /tmp/setup.log 2>/dev/null && break; sleep 1; done
docker exec "$GW" tail -1 /tmp/setup.log
echo "up: network $net, $(cat "$RUN/seed.out")"
