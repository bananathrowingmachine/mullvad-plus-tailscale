# Use Tailscale with Mullvad on Linux

Use Tailscale and the Mullvad desktop app at the same time on Linux. This
configuration marks Tailnet traffic so Mullvad permits the kernel to route it
through `tailscale0`.

Based on [TheOrangeOne's guide][orangeone] and
[Mullvad's advanced Linux split-tunnelling documentation][mullvad-docs].
This variant adds IPv6 support, interface-restricted inbound rules, and a
dedicated systemd service.

**Original version tested on 2026-07-28 with:**

- Ubuntu 26.04
- Mullvad 2026.3
- Tailscale 1.98.9

**New version tested on 2026-09-07 with:**

- CachyOS (up to date as of writing)
- Mullvad 2026.4
- Tailscale 1.102.3

Note that Arch based distributions (such as CachyOS) generally have `nft` at `/usr/bin/nft` rather than `/usr/sbin/nft` (see the
[Install](#install) note below), and where the `/etc/nftables.d` directory
does not exist by default — `install -Dm0644` creates it automatically, and
`tailscale-mullvad.service` also recreates it on every start as a safety net. While the original version was written for Ubuntu, this
version was written for CachyOS so **make sure to change the nft location back to** `/usr/sbin/nft` if your on Ubuntu. 

## What it installs

- [`mullvad-tailscale.nft`](mullvad-tailscale.nft) contains the firewall
  marks.
- [`tailscale-mullvad.service`](tailscale-mullvad.service) loads and removes
  that nftables table without taking ownership of the rest of the firewall.
  It waits for Mullvad's own routing table (52) to exist before loading, so
  it doesn't race Mullvad's connection at boot.
- [`tailscale-mullvad-watch.sh`](tailscale-mullvad-watch.sh), run continuously
  by [`tailscale-mullvad-routing.service`](tailscale-mullvad-routing.service),
  keeps a high-priority `ip rule` in place that sends fwmark-`0x6d6f6c65`
  traffic to Tailscale's routing table (52) ahead of Mullvad's Local Network
  Sharing rule. Unlike a rule installed once at boot, this reacts within
  about a second to every Mullvad connect, disconnect, or reconnect — see
  [Why a background watcher, not a static rule](#why-a-background-watcher-not-a-static-rule)
  for why this is necessary.

None of this enables the generic `nftables.service`, and none of it flushes
Mullvad's or Tailscale's dynamically managed firewall tables or `ip rule`
entries other than the one specific Local Network Sharing rule described
above.

> **Important:** Traffic addressed to the Tailnet bypasses Mullvad's tunnel
> routing so it can enter `tailscale0`. Tailscale still encrypts this traffic.
> Traffic not addressed to the Tailnet remains governed by Mullvad. Incoming
> connections also remain subject to your Tailscale access controls.

## Prerequisites

- Linux with systemd
- Mullvad VPN desktop app
- Tailscale
- nftables (`nft`)
- iproute2 (`ip`), including `ip monitor` support (standard on all modern
  distributions)
- bash
- The standard Tailscale interface name, `tailscale0`

Confirm the required commands, services, and interface exist:

```bash
command -v mullvad tailscale nft ip bash
systemctl status mullvad-daemon tailscaled --no-pager
ip link show tailscale0
```

## Install

Clone the repository:

```bash
git clone https://github.com/bananathrowingmachine/mullvad-plus-tailscale.git
cd mullvad-plus-tailscale
```

Check the nftables and systemd unit files before installing them:

```bash
sudo nft --check --file mullvad-tailscale.nft
systemd-analyze verify "$PWD/tailscale-mullvad.service"
systemd-analyze verify "$PWD/tailscale-mullvad-routing.service"
bash -n tailscale-mullvad-watch.sh
```

No output means the checks succeeded.

If `command -v nft` reports a path other than `/usr/bin/nft` — for example
`/usr/sbin/nft` on some distributions — update both files that invoke it
before installing:

```bash
NFT_PATH="$(command -v nft)"
sed -i "s|/usr/bin/nft|${NFT_PATH}|g" tailscale-mullvad.service
```

fish shell equivalent:

```fish
set NFT_PATH (command -v nft)
sed -i "s|/usr/bin/nft|$NFT_PATH|g" tailscale-mullvad.service
```

Install and enable the nftables marking service:

```bash
sudo install -Dm0644 mullvad-tailscale.nft \
  /etc/nftables.d/mullvad-tailscale.nft
sudo install -Dm0644 tailscale-mullvad.service \
  /etc/systemd/system/tailscale-mullvad.service
sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-mullvad.service
```

Install and enable the routing watcher (the script must be installed at the
exact path referenced by the `.service` file, `/usr/local/bin`):

```bash
sudo install -Dm0755 tailscale-mullvad-watch.sh \
  /usr/local/bin/tailscale-mullvad-watch.sh
sudo install -Dm0644 tailscale-mullvad-routing.service \
  /etc/systemd/system/tailscale-mullvad-routing.service
sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-mullvad-routing.service
```

Do not enable the generic `nftables.service` solely for this setup.

## Verify

Check that both services are enabled and active:

```bash
systemctl is-enabled tailscale-mullvad.service tailscale-mullvad-routing.service
systemctl is-active tailscale-mullvad.service tailscale-mullvad-routing.service
```

All four commands should report `enabled` and `active` (the routing service
shows `active (running)`, not `active (exited)`, since it runs continuously).

Confirm that Mullvad remains connected:

```bash
mullvad status
curl https://am.i.mullvad.net/connected
```

Find an online Tailnet device and test it using its Tailscale IP or MagicDNS
name:

```bash
tailscale status
tailscale ping 100.x.y.z
ping -c 3 100.x.y.z
```

Inspect the compatibility rules and their packet counters:

```bash
sudo nft list table inet mullvad_tailscale
```

The relevant IPv4 or IPv6 counters should increase as Tailnet traffic passes.

Confirm the routing rule is in place, and that marked traffic actually
resolves to Tailscale's table:

```bash
ip rule show | grep '0x6d6f6c65'
ip route get 100.x.y.z mark 0x6d6f6c65 fibmatch
```

The second command should report `table 52`.

Confirm the watcher reacts to a live Mullvad reconnect. Because a live
`journalctl -f` view can itself be interrupted if you're testing over an
active Tailscale SSH session (see
[Why a background watcher, not a static rule](#why-a-background-watcher-not-a-static-rule)),
check the persisted log afterward instead of tailing it during the test:

```bash
mullvad disconnect
mullvad connect
sleep 5
journalctl -u tailscale-mullvad-routing.service --since "-2min" --no-pager
```

You should see a line like `demoted Mullvad LAN-sharing rule from priority
0 to 20000` within a second or two of reconnecting. If the nft counters
increase but `fibmatch` still reports `main` (or another table) even after
this, see
[Fwmark ignored despite matching counters](#fwmark-ignored-despite-matching-counters)
below.

## Address ranges and inbound access

- `100.64.0.0/10` is Tailscale's IPv4 shared-address range. It covers
  `100.64.0.0` through `100.127.255.255`.
- `fd7a:115c:a1e0::/48` is Tailscale's IPv6 range.

The output rules allow this computer to initiate Tailnet connections. The
input rules allow other Tailnet devices to initiate connections to this
computer. Incoming exceptions are restricted to packets that actually arrive
through `tailscale0`.

## Update

Pull the latest version, validate it, reinstall all files, and restart:

```bash
git pull --ff-only
sudo nft --check --file mullvad-tailscale.nft
systemd-analyze verify "$PWD/tailscale-mullvad.service"
systemd-analyze verify "$PWD/tailscale-mullvad-routing.service"
bash -n tailscale-mullvad-watch.sh
sudo install -Dm0644 mullvad-tailscale.nft \
  /etc/nftables.d/mullvad-tailscale.nft
sudo install -Dm0644 tailscale-mullvad.service \
  /etc/systemd/system/tailscale-mullvad.service
sudo install -Dm0755 tailscale-mullvad-watch.sh \
  /usr/local/bin/tailscale-mullvad-watch.sh
sudo install -Dm0644 tailscale-mullvad-routing.service \
  /etc/systemd/system/tailscale-mullvad-routing.service
sudo systemctl daemon-reload
sudo systemctl restart tailscale-mullvad.service
sudo systemctl restart tailscale-mullvad-routing.service
```

Use `restart`, not `reload`, for both services after an update — the routing
watcher in particular needs a full restart to pick up script changes, since
systemd has no way to reload a running script in place.

## Troubleshooting

Inspect the services and recent logs:

```bash
systemctl status tailscale-mullvad.service --no-pager
systemctl status tailscale-mullvad-routing.service --no-pager
journalctl -u tailscale-mullvad.service -b --no-pager
journalctl -u tailscale-mullvad-routing.service -b --no-pager
journalctl -u tailscaled -b --no-pager
```

Confirm the expected interfaces and rules exist:

```bash
ip -brief address show tailscale0
ip -brief address show wg0-mullvad
sudo nft list table inet mullvad_tailscale
```

If a future Mullvad update changes its split-tunnelling implementation, verify
these values against Mullvad's current documentation:

```text
Connection-tracking mark: 0x00000f41
Routing/meta mark:         0x6d6f6c65
```

### Fwmark ignored despite matching counters

Symptom: `sudo nft list table inet mullvad_tailscale` shows the packet
counters increasing for your Tailnet traffic, `tailscale ping` succeeds, but
ordinary connections (e.g. `ssh`) to a Tailnet peer hang or fail. This means
the packet is being marked correctly but something is still routing it
through the wrong table before Tailscale's own rule gets a chance.

Some ISPs (particularly those using CGNAT) assign the WAN interface an
address inside `100.64.0.0/10` — the same range Tailscale uses. This causes
the kernel to install an on-link route for that whole range in the `main`
table. Mullvad's Local Network Sharing rule
(`from all lookup main suppress_prefixlength 0`) has no fwmark condition, so
it matches every packet — marked or not — and `suppress_prefixlength 0` only
excludes the default route, not this more specific `/10` route. Whenever this
rule has a lower preference number (i.e. higher priority) than Tailscale's
own rule, it wins before your mark is ever consulted.

Check for this:

```bash
ip route show table main | grep 100.64.0.0/10
ip rule show
```

If you see a `100.64.0.0/10` route in `main` on your WAN interface, and a
`from all lookup main suppress_prefixlength 0` rule with a lower preference
number than the fwmark rule pointing at table `52`, that's the collision.

Confirm `tailscale-mullvad-routing.service` is actually running (see
[Why a background watcher, not a static rule](#why-a-background-watcher-not-a-static-rule)
for why a one-time fix isn't enough here):

```bash
systemctl status tailscale-mullvad-routing.service --no-pager
```

If it's not `active (running)`, start it:

```bash
sudo systemctl enable --now tailscale-mullvad-routing.service
```

### Why a background watcher, not a static rule

An earlier version of this setup fixed the collision above by inserting the
fwmark rule at a single fixed preference number chosen to outrank Mullvad's
rule. In testing, this did not hold up:

- **Mullvad's rule numbering is not stable.** Its Local Network Sharing
  rule's preference was observed at `5208`, then `98`, then `3`, then `0`
  (the kernel's own floor) across different reconnects — apparently
  renumbered by mullvad-daemon on every connect/disconnect/feature-toggle.
  Any static number can eventually be undercut.
- **A one-shot fix applied only at service start doesn't survive later
  reconnects.** If you disconnect and reconnect Mullvad after boot — for
  example to work around a site that blocks VPN traffic — mullvad-daemon
  reinserts its rule fresh, and nothing re-applies the fix until the next
  restart or reboot.
- **A fix applied only at boot can also lose a race with Mullvad's own
  startup**, if Mullvad hasn't finished connecting (and hasn't installed its
  rule yet) by the time this project's fix runs.

`tailscale-mullvad-routing.service` addresses all three by running
continuously instead of once: it applies the fix immediately on start, then
reacts to every subsequent `ip rule` change via `ip monitor rule`, with a
fixed-interval poll (every second) as a safety net in case an event is missed
or Mullvad's reconnect briefly touches the fwmark rule itself as part of a
broader rebuild. It doesn't pick a lower number than Mullvad's rule — it
finds Mullvad's specific unconditional rule by its content and moves it to a
fixed low-priority slot (`20000`) every time it reappears, regardless of what
number Mullvad assigned it.

### SSH session drops during a Mullvad reconnect

A live SSH session that's actively connected *during* a `mullvad connect` or
`mullvad disconnect` may still drop, even with the routing fix in place and
working correctly. This is expected, and is not a routing-rule problem.

Tailscale treats the WireGuard interface Mullvad creates and destroys
(`wg0-mullvad`) appearing or disappearing as a "major" network change, and
rebinds its own UDP sockets and renegotiates the peer-to-peer path when it
happens (visible as `LinkChange: major, rebinding` in
`journalctl -u tailscaled`). Any TCP connection actively using the old
socket/endpoint at that moment does not survive the rebind. New connections
made after Tailscale finishes rebinding work immediately once things settle
— it's specifically an in-flight session that gets interrupted, not the
Tailnet as a whole.

If you're testing this project's fix by SSHing in and running
`mullvad connect`/`mullvad disconnect` remotely, expect that SSH session
itself to drop as part of this rebind; that's a separate, expected effect,
not evidence the routing fix failed. Confirm the fix worked by checking the
*persisted* log and current routing state afterward, from a fresh
connection, rather than relying on a live `journalctl -f` view that may be
interrupted by the same rebind:

```bash
journalctl -u tailscale-mullvad-routing.service --since "-2min" --no-pager
ip rule show
ip route get 100.x.y.z mark 0x6d6f6c65 fibmatch
```

## Disable or remove

Temporarily disable and restore the compatibility rule and routing fix:

```bash
sudo systemctl stop tailscale-mullvad-routing.service
sudo systemctl stop tailscale-mullvad.service
sudo systemctl start tailscale-mullvad.service
sudo systemctl start tailscale-mullvad-routing.service
```

Remove it completely:

```bash
sudo systemctl disable --now tailscale-mullvad-routing.service
sudo systemctl disable --now tailscale-mullvad.service
sudo rm /etc/systemd/system/tailscale-mullvad-routing.service
sudo rm /etc/systemd/system/tailscale-mullvad.service
sudo rm /usr/local/bin/tailscale-mullvad-watch.sh
sudo rm /etc/nftables.d/mullvad-tailscale.nft
sudo systemctl daemon-reload
```

Stopping `tailscale-mullvad.service` deletes only the `inet mullvad_tailscale`
table. Stopping `tailscale-mullvad-routing.service` simply stops the watcher
script; it does not remove or restore Mullvad's Local Network Sharing rule to
whatever priority Mullvad would have originally chosen. If you want Mullvad
to reassert that rule on its own terms after removing this setup, restart
Mullvad's own daemon:

```bash
sudo systemctl restart mullvad-daemon
```

## Acknowledgements

- [Accessing Tailscale whilst using Mullvad][orangeone] by TheOrangeOne
- [Mullvad: Split tunneling with Linux (advanced)][mullvad-docs]

## License

MIT — see [LICENSE](LICENSE).

[orangeone]: https://theorangeone.net/posts/tailscale-mullvad/
[mullvad-docs]: https://mullvad.net/en/help/split-tunneling-with-linux-advanced
