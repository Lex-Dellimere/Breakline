# Cloud

The Breakline cloud: Phoenix 1.8, LiveView and Ash. It signs and publishes site policies,
and site gateways connect out to it over a websocket with mutual TLS.

* `mix setup` installs dependencies, migrates and seeds the dev database
  (Postgres `breakline-pg` on `127.0.0.1:5433`, see the repo's `docker-compose.yml`)
* `mix phx.server` serves the browser UI on http://localhost:4010 and, once the dev
  certificates exist, the gateway endpoint on https://localhost:4011

## End-to-end demo

A local gateway connects to this cloud, applies the seeded site's policy, and the RMM
channel opens and closes as the cloud publishes. All commands start from the repo root;
replace `Nx` with `hostname -s`.

### 1. Cloud keys and certificates (once)

```sh
cd cloud
mix run priv/repo/seeds.exs        # prints: site Parramatta clinic (<site_id>) at policy version N
mix cloud.signer.keygen            # skip if priv/keys/signer_ed25519.json exists
mix cloud.dev.pki                  # dev ca + gateway endpoint certificate in priv/keys/
mix cloud.dev.gateway_cert <site_id>
DEMO_PASSWORD='choose-a-password' mix cloud.dev.demo_password
```

`cloud.dev.gateway_cert` issues the gateway's client certificate, pins its fingerprint on
the site, and writes `gateway/priv/keys/` (certificate, key, ca, `site.json`,
`cloud_signer.public.json`). With those files the gateway's dev config uses the site id,
trusts the cloud's signing key and enables the uplink; its state goes to
`gateway/tmp/dev_uplink/`.

### 2. Start the cloud

```sh
cd cloud
elixir --sname cloud -S mix phx.server
```

The log shows `Running CloudWeb.GatewayEndpoint ... at 127.0.0.1:4011 (https)`.

### 3. Start the gateway

In a second terminal:

```sh
cd gateway
elixir --sname gw -S mix run --no-halt
```

Within a few seconds it logs `uplink joined gateway:<site_id>`, then
`uplink: applied policy N`. Outside the site's weeknight window the state is
`locked (default)`, and:

```sh
dig @127.0.0.1 -p 5300 sis.n-able.com      # status: NXDOMAIN
```

### 4. Open and lock from the cloud

Sign in at http://localhost:4010 as `demo@breakline.test` with the demo password. Opening
access needs a passkey, so first open **Security** and add one (Touch ID, Windows Hello, a
phone or a security key; WebAuthn works over plain http on `localhost` only, so use that
host name, not `127.0.0.1`).

Then open **Sites**, then **Parramatta clinic**. The **Access** panel opens the site for
15, 30 or 60 minutes and lifts the manual locks, each after a passkey prompt that approves
only that one action, and locks it now without one.

```sh
dig @127.0.0.1 -p 5300 sis.n-able.com      # after Open: status NOERROR, within a second
```

**Open now (break-glass)** in the same panel opens the site for 15 minutes to 4 hours after a
passkey prompt; the active break-glass is shown at the top with a Revoke button (no prompt).

To try the MSP side, use **MSP request links** on the site page (admins): pick the seeded
contact and **Send link**. The email lands in the dev mailbox at
http://localhost:4010/dev/mailbox; open its link in a private window (no sign in), request a
window, then approve or reject it under **Requests** (approving asks for your passkey and
publishes).

Locking also works from a shell (opening does not: it needs the passkey ceremony):

```sh
elixir --sname probe --rpc-eval cloud@Nx '
  require Ash.Query
  user = Cloud.Accounts.User |> Ash.Query.filter(email == "demo@breakline.test") |> Ash.read_one!(authorize?: false)
  Cloud.Access.lock_now("<site_id>", user, "demo") |> elem(0) |> IO.inspect()'
dig @127.0.0.1 -p 5300 sis.n-able.com      # status: NXDOMAIN again
```

**Security** can also turn on TOTP as a second sign-in factor. It shows a QR code of the
`otpauth://` link to scan with an authenticator app, and the link and the key as text to
paste or type instead. TOTP only signs in, it never approves.

Every action is recorded in the tenant's audit chain:

```sh
psql -h 127.0.0.1 -p 5433 -U postgres cloud_dev -c \
  "select seq, entry->>'action', entry->>'at' from audit_entries order by tenant_id, seq"
elixir --sname probe --rpc-eval cloud@Nx '
  {:ok, t} = Cloud.Accounts.get_tenant_by_slug("demo", authorize?: false)
  IO.inspect Cloud.Audit.verify(t.id)'
```

### 5. Look at what arrived

```sh
elixir --sname probe --rpc-eval gw@Nx 'IO.inspect Gateway.Uplink.status()'
psql -h 127.0.0.1 -p 5433 -U postgres cloud_dev -c \
  "select gateway_last_seen_at, gateway_status->>'state', gateway_audit_head from sites"
psql -h 127.0.0.1 -p 5433 -U postgres cloud_dev -c \
  "select type, count(*) from gateway_events group by type"
```

Heartbeats arrive every 30 s, events and audit records every few seconds. The site's
`gateway_audit_head` is the head of the gateway's audit chain as the cloud verified and
anchored it.

### 6. Dashboard, timeline and audit export

After sign in you land on http://localhost:4010/dashboard: counters, each site's live state and
why, and its windows for the next 7 days. Each site page links to its timeline
(`/sites/:id/timeline`). On http://localhost:4010/audit pick a period and sites, check the chain
verification and download the json export or the PDF report (the PDF needs the Typst binary,
see "PDF reports" below); then re-check the json file offline from `core/`:

```sh
cd core && mix breakline.audit.verify ~/Downloads/breakline-audit-demo-2026-10-25-2026-11-01.json
echo $?   # 0 intact, 1 broken (the first break is printed), 2 not an export
```

To start over on the gateway side, stop it and `rm -rf gateway/tmp/dev_uplink`. Removing
`gateway/priv/keys/site.json` takes the gateway back to the inbox-only dev setup.

## PDF reports

`/audit/export.pdf` renders the audit export with the Typst CLI, run as a separate process
(D38). Install the pinned binary once:

```sh
mix cloud.typst.install     # typst 0.15.1, sha256-checked, to priv/bin/typst (git-ignored)
```

It needs `tar` with xz support and coreutils `timeout` on the host. The binary is a static
musl build, so it runs on any x86_64 Linux.

In production the binary comes one of two ways:

* run `MIX_ENV=prod mix cloud.typst.install` before `mix release`, so it ships in the release's
  `priv/bin/typst` (used when `TYPST_PATH` is unset); `--archive PATH` installs from an
  already downloaded asset when the build has no network;
* or put it in the container image (for example `COPY` the checksum-verified binary to
  `/usr/local/bin/typst`) and set `TYPST_PATH=/usr/local/bin/typst`.

Without the binary the PDF download answers 503 and the json export still works.

## Tests

```sh
mix test
```

`test/cloud_web/gateway_endpoint_tls_test.exs` runs the gateway endpoint behind a real
Bandit TLS listener with certificates from `openssl`, so `openssl` must be on the path.

Tests tagged `:typst` render real PDFs. They run when `priv/bin/typst` exists and are
excluded otherwise; `test/test_helper.exs` prints a note when that happens. The no-network
render uses `unshare -rn` when the host allows it, and the PDF text check uses `pdftotext`
when it is installed.
