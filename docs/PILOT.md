# Pilot box runbook

For the MSP tech installing a Breakline pilot box at a client site. Pilots run in
**monitor mode**: the box logs every remote-access (RMM) lookup it would block, and blocks
nothing.

The box runs Debian 13 (trixie) and the `breakline-gateway` package. The package installs
the gateway as a locked-down systemd service, running as the `breakline` user.

## 1. Before you go: what to tell the client and the MSP

Agree on these in writing before the box goes on site.

**Tell the client:**
- What it does in monitor mode: it watches DNS lookups and records any for the MSP's
  remote-access tools, and for DNS-over-HTTPS services. It blocks nothing and changes
  nothing for staff.
- What is recorded: the name looked up, when, and the IP address of the device that asked,
  only for those remote-access and DoH names. Other lookups are answered and not recorded.
  The records are sent to the Breakline cloud once the box is enrolled.
- What can go wrong, depending on the mode you pick (section 9). In dns-only mode, a dead
  box can stop name lookups. In the inline modes, a dead box cuts the internet.
- How you undo it (section 10), and who to call.
- How long it runs, and that nobody switches it to enforce without their sign-off.

**Tell the MSP:**
- Nothing is blocked during the pilot, so their tools keep working.
- The pilot records when their tools are used from this site. That is the point: it shows
  the client how often remote access happens, and when.
- Which install mode you are using and when you are on site, so their NOC doesn't chase a
  DNS change or a short outage.
- If they see a remote-access problem at this site during the pilot, call you first. Don't
  quietly route around the box.

## 2. Hardware

- A fanless mini PC with **two Intel i226-V 2.5 GbE ports**. Debian's stock kernel has the
  `igc` driver for the i226-V, so there's nothing extra to install. Avoid Realtek NICs.
- 8 GB RAM and a 64 GB or larger SSD is plenty.
- Two short patch cables, labelled, plus a spare. For the inline modes, a small UPS.

| item | example | price (AUD) |
|---|---|---|
| two-port fanless mini PC | HUNSN RJ63: N100, 2 × 2.5 GbE plus 2 × SFP+, 8 GB RAM and 256 GB SSD included | 567.60 inc GST, Newegg AU, ships from Hong Kong or China |
| cheaper alternative | HUNSN RX11: J4125, 4 Intel ports | 433.40 inc GST, Newegg AU, same shipping |
| RAM and SSD, if not included | | not priced yet |
| small UPS, for the inline modes | | not priced yet |

Prices are from the market scan of 31 Oct 2026 and will move. Neither listing names the NIC
chip, so check with the seller that the ports are i226-V (or another `igc` part) before
you buy. No plain two-port N100 box with an AUD price turned up; one would likely be
cheaper.

In the BIOS, before you install:
- set **restore on AC power loss** to **power on**, so the box comes back by itself after
  an outage;
- turn off wake-on-LAN and any onboard wifi or bluetooth you won't use.

## 3. Install Debian 13

Use the **amd64 netinst** image from debian.org, written to a USB stick. On the bench, plug
one cable into a network with internet and DHCP.

Installer choices:
- **Install** (text) or **Graphical install**: either works.
- **Location:** Australia. **Keyboard:** American English. The time zone follows the state
  you pick.
- **Network:** let it use DHCP on the plugged-in port. Hostname: e.g. `breakline-<site>`.
- **Root password:** leave it **empty**. The installer then gives your user `sudo`.
- **Partitioning:** "Guided - use entire disk", "All files in one partition". **Don't
  encrypt the disk**: an unattended box can't type a passphrase after a power cut.
- **Software selection:** untick "Debian desktop environment" and "GNOME". Tick only
  **SSH server** and **standard system utilities**.
- **GRUB:** install it to the internal disk.

After the first boot, log in and update:

```sh
sudo apt update && sudo apt full-upgrade
```

**Network config tool:** a netinst install manages the network with **ifupdown**
(`/etc/network/interfaces`), the installer's own default. systemd-networkd ships with
systemd but is off. The examples here use ifupdown, so you configure what the installer
already set up instead of changing tools.

**Time:** the gateway keeps remote access locked while the clock isn't synced (in monitor
mode it only records). Debian 13 installs `systemd-timesyncd`. Check it:

```sh
timedatectl show -p NTPSynchronized --value     # must print: yes
```

If it prints `no`, the site firewall is probably blocking outbound UDP 123. Allow it, or
set the site's NTP server in `/etc/systemd/timesyncd.conf` (`NTP=...`), then run
`sudo systemctl restart systemd-timesyncd`.

## 4. Install the package

Copy the `.deb` to the box (e.g. `scp`), then:

```sh
sudo apt install ./breakline-gateway_0.1.0_amd64.deb
```

apt pulls in what it needs (`nftables` among others). The install:
- creates the `breakline` system user;
- writes a per-box secret to `/etc/breakline-gateway/cookie`;
- enables the service, but **doesn't start it**: it needs configuring first.

What goes where:

| path | what |
|---|---|
| `/opt/breakline-gateway` | the gateway |
| `/etc/default/breakline-gateway` | its settings (yours to edit; upgrades keep your changes) |
| `/var/lib/breakline` | its state: the signed policy and the audit log |
| `/usr/share/doc/breakline-gateway/examples/` | network configs for each mode |
| `breakline-gateway` | the admin command: `status` and `enroll` |

## 5. Configure

Edit `/etc/default/breakline-gateway` (`sudo nano /etc/default/breakline-gateway`). Every
setting is explained in the file. Keep each line as plain `KEY=value`: no quotes, no
spaces.

The Breakline team gives you the **site id** and the **signing key**:

```sh
BREAKLINE_SITE_ID=<site id>
BREAKLINE_PUBLIC_KEYS=<key id>=<public key>
BREAKLINE_DEFAULT_MODE=monitor
```

The mode-specific lines (`BREAKLINE_LAN_INTERFACES`, `BREAKLINE_DNS_IP`) are in section 7.
To find the port names, run `ip -br link`. The two i226-V ports usually show up as `enp1s0`
and `enp2s0`.

## 6. Enrol

Enrolling connects the box to the Breakline cloud. The Breakline team gives you the cloud
URL, a one-time **enrolment code**, and the **CA fingerprint** (64 hex characters).

```sh
sudo breakline-gateway enroll https://<cloud> <code> --ca-sha256 <fingerprint>
```

If it fails, it prints why and exits non-zero, and nothing on the service changes. If it
works, it restarts the service. A code can only be used once, so ask for a new one if
enrolment fails after the code was accepted.

## 7. Choose a mode

| | dns-only monitor | bridge | router |
|---|---|---|---|
| cabling | one cable, like any PC | inline: firewall → box → switch | inline for one segment |
| sees | DNS lookups only | all traffic | the segment's traffic |
| can break the site | only DNS, if it dies | yes: no bypass if it dies | that segment |
| changes on the LAN | DHCP's DNS option | none | a new subnet and a route |
| use for | **the first pilots** | later pilots | a single segment |

Each mode's files are in `/usr/share/doc/breakline-gateway/examples/<mode>/`. After you
change the network, run `sudo systemctl restart networking` or reboot. Then:

```sh
sudo systemctl restart breakline-gateway
```

### dns-only monitor (first pilots)

The box is an ordinary LAN host with one cable. Nothing is inline, so it can't break
traffic, and it sees DNS lookups only.

1. Give the box a **fixed address**: a static one outside the DHCP pool, or a DHCP
   reservation. Copy `examples/dns-only/interfaces` to `/etc/network/interfaces` and set
   your addresses.
2. Point the box's own DNS at real resolvers, not at itself. Then it can still reach apt
   and the cloud when the gateway is down. In `/etc/resolv.conf`:
   `nameserver 1.1.1.1` and `nameserver 9.9.9.9`.
3. Bind the resolver to the LAN address. In `/etc/default/breakline-gateway`:
   ```sh
   BREAKLINE_LAN_INTERFACES=enp1s0
   BREAKLINE_DNS_IP=192.168.1.53
   ```
4. Restart the gateway and verify it (section 8) **before** you touch DHCP.
5. On the site's DHCP server, set the DNS server option (option 6) to the box's address.
   Read section 9 before you decide whether to add a second DNS server. Clients switch over
   as their leases renew. Run `ipconfig /renew` on a test PC to see it straight away.

Devices with a hard-coded DNS server, or with DNS-over-HTTPS that doesn't go through a
known provider, don't show up in this mode.

### bridge

The box sits between the site firewall and its switch. `br0` joins both ports, so the LAN
keeps its addressing, gateway and DHCP exactly as before.

> The gateway's firewall rules on bridged traffic are still being validated. Check with the
> Breakline team before you use bridge mode at a site.

1. `sudo apt install bridge-utils`. ifupdown's `bridge_ports` option comes from it.
2. Copy:
   - `examples/bridge/interfaces` to `/etc/network/interfaces`;
   - `examples/bridge/modules-load.conf` to `/etc/modules-load.d/breakline-bridge.conf`.
     It loads `br_netfilter` at boot;
   - `examples/bridge/sysctl.conf` to `/etc/sysctl.d/90-breakline-bridge.conf`. It turns
     on `net.bridge.bridge-nf-call-iptables` and `-ip6tables`, so bridged traffic passes
     through the firewall rules.
3. In `/etc/default/breakline-gateway`: `BREAKLINE_LAN_INTERFACES=br0`.
4. Reboot on the bench. Check `ip -br addr` (br0 has an address, both ports are up) and
   `sysctl net.bridge.bridge-nf-call-iptables` (it must print `= 1`).
5. On site, in an agreed window: connect the firewall's LAN port to one box port, and the
   other box port to the switch. Expect about a minute of outage.

### router

The box routes for one LAN segment, with its own subnet behind it.

1. Copy `examples/router/interfaces` to `/etc/network/interfaces`. enp1s0 faces the site
   LAN and enp2s0 is the segment.
2. Copy `examples/router/sysctl.conf` to `/etc/sysctl.d/90-breakline-router.conf`. It turns
   on `net.ipv4.ip_forward`.
3. Return traffic: add a static route on the site firewall (segment via the box's address).
   If the firewall can't take a route, use `examples/router/nat.nft` as
   `/etc/nftables.conf` and run `sudo systemctl enable --now nftables`.
4. Addresses on the segment: static ones, DHCP relay from the site's server, or a DHCP
   server on the box. A DHCP server on the box must not use port 53 (for dnsmasq, set
   `port=0`).
5. In `/etc/default/breakline-gateway`:
   ```sh
   BREAKLINE_LAN_INTERFACES=enp2s0
   BREAKLINE_DNS_IP=10.20.0.1
   ```

> **Never** put `flush ruleset` in `/etc/nftables.conf`. Debian's stock file has it, and
> it deletes the gateway's own `inet breakline` table. The gateway only puts the table back
> on its next change.

## 8. Verify

From a LAN PC (Windows), using the box's address:

```
nslookup use-application-dns.net 192.168.1.53
nslookup example.com 192.168.1.53
```

- The first must say **Non-existent domain**. The gateway answers that name itself, so
  this proves you reached the gateway and not some other DNS server.
- The second must return addresses.

With `dig`, from Linux or the box itself:
- `dig @192.168.1.53 use-application-dns.net` must show `status: NXDOMAIN`;
- `dig @192.168.1.53 example.com` must show `status: NOERROR`.

On the box:

```sh
sudo breakline-gateway status
```

A healthy monitor pilot before its first policy arrives:

```
enforcer
  state:            locked (no_policy)
  mode:             monitor
  policy version:   none (last accepted 0)
  clock synced:     yes
  ...
  firewall:         NftImpl, in sync, 1 applies, 0 resolved ips

uplink
  status:           connected, joined
```

In monitor mode, **"locked" means "would block"**: nothing is actually blocked. Check
these:
- `clock synced: yes`;
- `firewall: ... in sync`;
- once enrolled, `uplink: connected, joined`.

Logs: `journalctl -u breakline-gateway -f`.

## 9. Failure modes

**Inline modes (bridge, router): if the box loses power or dies, the site loses its
internet** (or, in router mode, that segment does). These NICs have no hardware bypass, so
a dead box is a cut cable. To limit the risk:
- a UPS;
- BIOS power-on after AC loss;
- a labelled spare cable on site, so anyone can do the rollback in section 10.

**dns-only: if the box dies, clients' name lookups fail**, unless DHCP also hands out a
second DNS server. That second server is a real trade-off:
- **One DNS server (the box):** the pilot sees every lookup. But a dead box means "the
  internet is down" for staff, until someone does the rollback.
- **Box plus a second server:** a dead box goes mostly unnoticed. But clients don't only
  use the second server when the box is dead. Windows and other systems switch to it after
  a slow answer and can stay on it. Those lookups bypass the box, so the pilot data has
  gaps. In enforce mode, the second server would be a way around the block.

For a monitor pilot, pick one with the client and write it down. Our default is the box
alone, with the client knowing the rollback. For a site that can't tolerate any DNS outage,
add the second server and accept that the counts are a lower bound.

**Clock not synced:** the gateway locks remote access. In monitor mode it only records
would-blocks, so nothing breaks. Fix the time (section 3).

**Cloud unreachable:** the box keeps running on its last policy. Nothing changes for the
site.

## 10. Rollback

- **Bridge or router:** unplug the box and connect the firewall straight to the switch with
  the spare cable. Done. The site is back as it was.
- **dns-only:** remove the box's address from the DHCP DNS option and put the old DNS
  servers back. Clients move back as their leases renew. Run `ipconfig /renew` on a PC to
  move it now. **Keep the box running until the leases have turned over**, or clients that
  still point at it lose DNS.

To remove the software: `sudo apt purge breakline-gateway`. This keeps
`/var/lib/breakline`, the audit log, on purpose. Delete it by hand once the pilot data is
no longer needed.
