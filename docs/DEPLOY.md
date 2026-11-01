# Deploying the cloud

How to run `cloud/` for monitor-only pilots: one VM, one Postgres, one release. It is
written for any provider; nothing here depends on one.

## Shape

```
 browsers ──443──► Caddy (TLS, reverse proxy) ──► release :4000  (CloudWeb.Endpoint, http)
 gateways ──4011──────────────────────────────► release :4011  (CloudWeb.GatewayEndpoint, mutual TLS)
                                                    │
                                                    └──► Postgres 17 (local socket or 127.0.0.1)
```

- **One VM in an Australian region (Sydney).** Pilot data (site names, audit entries,
  approver emails) stays in Australia. 2 vCPU, 4 GB RAM and 40 GB disk are plenty for a
  pilot. Take the provider's disk encryption and its snapshot feature if it has them.
- **Debian 13 (trixie)**, with `postgresql-17` and `caddy` from Debian's own archive,
  plus `openssl` and coreutils (`timeout`, used by the PDF renderer).
- **The release as a systemd service** (`breakline-cloud`), as its own unprivileged user.
- **Caddy terminates 443 for browsers only** and proxies to `PORT` (4000) on loopback.
- **Port 4011 goes straight to the release, never through a proxy** (T10). The gateway
  endpoint does mutual TLS itself: the box's certificate in that TLS session is its
  identity. A TLS-terminating proxy, load balancer or CDN in front of 4011 would see the
  certificate instead of the app, and enrolment and the gateway socket would stop working.
  A plain TCP forward (layer 4, no TLS) is fine, but it hides the client ip from the
  enrolment rate limit.

## Build

Build on Debian 13 with the same Erlang/OTP and Elixir as development (OTP 27, Elixir
1.18), so the release's ERTS links against the same glibc and OpenSSL as the VM. The
release carries its own ERTS; the VM needs no Erlang.

```sh
cd cloud
mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix cloud.typst.install        # pinned typst 0.15.1, sha256-checked (D38)
MIX_ENV=prod mix release
tar -C _build/prod/rel -czf cloud-release.tar.gz cloud
```

`mix cloud.typst.install` puts the checksum-verified binary in the release's
`priv/bin/typst`, which is used when `TYPST_PATH` is unset. Without network on the build
host, download the asset elsewhere and pass `--archive PATH`. To keep the binary outside
the release instead, install it with the same task, copy it to `/usr/local/bin/typst` and
set `TYPST_PATH=/usr/local/bin/typst`. Without any binary the PDF download answers 503 and
the json export still works.

`ash_admin` stays a normal dependency: the domains use its DSL extension, so leaving it out
of prod would not compile. It is only routed in dev (`dev_routes`), so prod never serves
`/admin`.

## Install

As root on the VM:

```sh
adduser --system --group --home /opt/breakline-cloud breakline-cloud
mkdir -p /opt/breakline-cloud /etc/breakline-cloud
tar -C /opt/breakline-cloud --strip-components=1 -xzf cloud-release.tar.gz
chown -R root:root /opt/breakline-cloud
chown root:breakline-cloud /etc/breakline-cloud && chmod 0750 /etc/breakline-cloud

# postgres: a role and a database owned by it
sudo -u postgres createuser --pwprompt breakline
sudo -u postgres createdb -O breakline breakline
```

`/etc/systemd/system/breakline-cloud.service`:

```ini
[Unit]
Description=Breakline cloud
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=breakline-cloud
Group=breakline-cloud
EnvironmentFile=/etc/breakline-cloud/env
# the release writes its runtime files here instead of under /opt
RuntimeDirectory=breakline-cloud
Environment=RELEASE_TMP=/run/breakline-cloud
ExecStartPre=/opt/breakline-cloud/bin/migrate
ExecStart=/opt/breakline-cloud/bin/server
ExecStop=/opt/breakline-cloud/bin/cloud stop
Restart=on-failure
RestartSec=5
# 4011 is above 1024, so no capability is needed
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

`bin/migrate` runs `Cloud.Release.migrate/0`, which runs every migration of the
AshPostgres repo (`Cloud.Repo`), including the extension migration that installs
`citext` and the `ash_*` sql functions, so the database role needs to be its owner on the
first run. Running it before every start is safe: applied migrations are skipped.

`/etc/caddy/Caddyfile`:

```
cloud.example.com.au {
	reverse_proxy 127.0.0.1:4000
}
```

Caddy gets and renews the browser certificate itself and sends `X-Forwarded-Proto`, which
the endpoint's `force_ssl` honours. Host firewall: allow 22 (preferably from your own ips
only), 80 and 443 (Caddy) and 4011 (gateways) inbound, and nothing else. The release
listens on all interfaces for `PORT`, so 4000 must stay closed from outside. Erlang
distribution (epmd on 4369 and the node's own port, used by `bin/cloud rpc` and `stop`)
must stay closed too; add `ERL_EPMD_ADDRESS=127.0.0.1` to the env file so epmd only
listens on loopback.

## The gateway endpoint's certificate (port 4011)

Port 4011 has its own server certificate from an **offline private CA**, not from a
public CA and not Caddy's. A box pins this CA with `--ca-sha256` when it enrols and
trusts nothing else on 4011 afterwards (`server_ca.pem` on the box).

**The CA's private key never touches the server.** Create it on an offline machine (an
air-gapped laptop or a live USB), keep it on encrypted removable media in two places, and
bring only the CA certificate and the server certificate and key to the VM. Whoever holds
the CA key can impersonate the cloud to every enrolled box (though not sign policies: that
is the signer key).

On the offline machine, with `NAME` the host name gateways dial:

```sh
NAME=gw.example.com.au
umask 077
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out gateway-ca.key
openssl req -x509 -new -sha256 -key gateway-ca.key -out gateway-ca.pem -days 3650 \
  -subj "/CN=Breakline gateway CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out gateway-tls.key
openssl req -new -sha256 -key gateway-tls.key -subj "/CN=$NAME" -out gateway-tls.csr
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$NAME" > gateway-tls.ext
openssl x509 -req -sha256 -in gateway-tls.csr -CA gateway-ca.pem -CAkey gateway-ca.key \
  -CAcreateserial -days 825 -extfile gateway-tls.ext -out gateway-tls.pem
```

Copy `gateway-ca.pem`, `gateway-tls.pem` and `gateway-tls.key` to `/etc/breakline-cloud/`
(`gateway-tls.key` mode 0640, root:breakline-cloud). `gateway-ca.key` stays offline.

The `--ca-sha256` value is the sha256 of the CA certificate's DER-encoded
SubjectPublicKeyInfo, the same hash kubeadm's `--discovery-token-ca-cert-hash` uses:

```sh
openssl x509 -in gateway-ca.pem -pubkey -noout | openssl pkey -pubin -outform der | sha256sum
```

The site page computes the same value from `GATEWAY_TLS_CA` and puts it in the enrolment
command, so nobody has to type it; compute it by hand once to check they agree.

- **Renewing the server certificate** (every 825 days or sooner): sign a new one with the
  same CA, replace `gateway-tls.pem` and `.key`, restart. The pin is the CA's key, so
  enrolled boxes are unaffected.
- **Replacing the CA** changes the pin. Every enrolled box keeps the old `server_ca.pem`
  and can no longer connect until it is enrolled again. Only do it if the CA key is lost
  or exposed.

## Secrets and environment

All configuration is read from the environment at boot (`config/runtime.exs`). Put it in
`/etc/breakline-cloud/env`, owned by root, group `breakline-cloud`, mode 0640. **Never
commit any of it**; keep a copy in your password manager or an encrypted offline store.
Generate each random secret on the VM or the offline machine, never on a shared machine.

| variable | what | how to provision |
|---|---|---|
| `DATABASE_URL` | `ecto://breakline:<password>@localhost/breakline` | the role's password from `createuser --pwprompt` |
| `POOL_SIZE` | optional, default 10 | |
| `ECTO_IPV6` | optional, `true` to reach Postgres over ipv6 | |
| `SECRET_KEY_BASE` | signs and encrypts cookies, and is the fallback key for notification targets | `openssl rand -base64 48` (or `mix phx.gen.secret`) |
| `TOKEN_SIGNING_SECRET` | signs ash_authentication tokens | `openssl rand -base64 48` |
| `NOTIFICATIONS_KEY` | root key for the AES-256-GCM encryption of webhook urls (T17) | `openssl rand -base64 32`. Set it: without it the webhooks are encrypted with `SECRET_KEY_BASE`, and rotating that would make them unreadable |
| `WEBAUTHN_RP_ID` | passkey relying party id, the browser host name, e.g. `cloud.example.com.au` | **fixed for good**: changing it invalidates every registered passkey |
| `WEBAUTHN_ORIGIN` | `https://cloud.example.com.au` exactly as the browser shows it | |
| `WEBAUTHN_RP_NAME` | optional, default `Breakline` | |
| `PHX_HOST` | the browser host name, for generated urls | |
| `PORT` | browser endpoint port behind Caddy, default 4000 | |
| `GATEWAY_PORT` | gateway endpoint port, default 4011 | |
| `GATEWAY_URL` | the url boxes enrol at, e.g. `https://gw.example.com.au:4011` | its host must be in the server certificate |
| `GATEWAY_SERVER_NAME` | optional, the name in the server certificate when it is not `GATEWAY_URL`'s host | |
| `GATEWAY_TLS_CERT`, `GATEWAY_TLS_KEY` | the 4011 server certificate and key | from the offline CA above |
| `GATEWAY_TLS_CA` | the offline CA's certificate (public) | from the offline CA above. It replaces the old `GATEWAY_CLIENT_CA`: gateway client certificates are self-signed and pinned, no CA signs them |
| `SIGNER_KEY_PATH` | the Ed25519 key that signs every policy (`Cloud.Signer.File`), e.g. `/etc/breakline-cloud/signer_ed25519.json` | `mix cloud.signer.keygen --path signer_ed25519.json` from a checkout, on the offline machine; copy the private file (mode 0640, root:breakline-cloud). This is the most sensitive secret: it can sign "open" for every site (T8). A KMS or HSM backed signer replaces the file later |
| `TYPST_PATH` | optional, the Typst binary when it is not the release's own | |
| `DNS_CLUSTER_QUERY` | leave unset: one node | |
| `RELEASE_COOKIE` | the Erlang distribution cookie: whoever has it can run any code in the node | `openssl rand -hex 32`. Set it: the build-time `releases/COOKIE` is world-readable in the tarball, so also `chmod 0600 /opt/breakline-cloud/releases/COOKIE` |

`PHX_SERVER=true` is set by `bin/server`.

Generate the CA and the signer key on the offline machine; generate the rest on the VM:

```sh
umask 077
{
  echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')"
  echo "TOKEN_SIGNING_SECRET=$(openssl rand -base64 48 | tr -d '\n')"
  echo "NOTIFICATIONS_KEY=$(openssl rand -base64 32 | tr -d '\n')"
  echo "RELEASE_COOKIE=$(openssl rand -hex 32)"
} >> /etc/breakline-cloud/env
```

## Backups

- **Postgres, nightly:** `pg_dump -Fc breakline` from a systemd timer, encrypted (for
  example with `age` to a key that is not on the VM) and copied off the VM to storage in
  Australia. Keep 30 days. The database holds the audit chains and their heads, so a backup
  is also evidence: keep it where the cloud's own credentials cannot delete it.
- **Provider disk snapshots**, daily, as a second line. They are not a substitute: a
  snapshot of a running Postgres is only crash-consistent.
- **Secrets**, separately and once (they rarely change): the env file, the signer key, the
  4011 certificate and key, and, offline, the CA key. Losing the signer key means every
  gateway must be told a new public key (re-enrol). Losing `NOTIFICATIONS_KEY` makes the
  stored webhook urls unreadable; the channels must be entered again.
- **Restore test** before the first pilot and after every major change: restore the dump
  into a scratch database, start a release against it and run `Cloud.Audit.verify/1` for
  each tenant.

The gateways keep enforcing their last policy while the cloud is down (T7), so a restore
does not open anything; boxes reconnect and get the current version.

## What the operator does by hand

- Create the VM, its DNS records (`cloud.` for browsers, `gw.` for 4011, which may be the
  same address) and the host firewall.
- Create the offline CA, the 4011 certificate and the signer key; keep the CA key offline
  and diarise the certificate renewal (825 days).
- Write `/etc/breakline-cloud/env`, install the release and the unit, `systemctl enable
  --now breakline-cloud`.
- Create the first tenant and its admin. Register the admin at `/register`, then write
  `/etc/breakline-cloud/first_admin.exs` (the service's `/tmp` is private, so not there):

  ```elixir
  require Ash.Query
  {:ok, t} = Cloud.Accounts.create_tenant(%{name: "Example Clinics", slug: "example"}, authorize?: false)
  u = Cloud.Accounts.User |> Ash.Query.filter(email == "admin@example.com.au") |> Ash.read_one!(authorize?: false)
  Cloud.Accounts.create_membership!(u.id, t.id, :admin, authorize?: false)
  ```

  and run it in the running node, then delete it:

  ```sh
  sudo -u breakline-cloud sh -c 'set -a; . /etc/breakline-cloud/env; exec /opt/breakline-cloud/bin/cloud rpc "Code.eval_file(\"/etc/breakline-cloud/first_admin.exs\")"'
  rm /etc/breakline-cloud/first_admin.exs
  ```

  The admin then adds a passkey on the security page; enrolling a gateway and opening
  access need it.
- Configure outbound email. The release still uses the Swoosh local adapter (nothing is
  sent): request links, password resets and email notifications need an adapter wired in
  `config/runtime.exs` before a pilot uses them.
- Deploy: build, copy, unpack into a fresh directory, swap, `systemctl restart
  breakline-cloud` (migrations run first). Keep the previous release to roll back to; a
  migration that already ran is not undone by that.
- Watch: `journalctl -u breakline-cloud`, disk space, the nightly backup's success, and the
  certificate dates (`openssl x509 -enddate -noout -in /etc/breakline-cloud/gateway-tls.pem`).

## Enrolling a box

On the site page an admin clicks **Enrol gateway**, confirms with a passkey and copies the
command onto the box:

```sh
sudo breakline-gateway enroll https://gw.example.com.au:4011 ABCD-...-WXYZ --ca-sha256 <hex>
```

The code is valid for 30 minutes and once. The box writes its identity and the enrolment
under its data directory (`gateway/README.md`, "Enrolment") and the package restarts the
gateway. Enrolling a box for a site that already has one replaces it: the old box is
disconnected and can no longer connect.
