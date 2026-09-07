# Use Tailscale with Mullvad on Linux

Use Tailscale and the Mullvad desktop app at the same time on Linux. This
configuration marks Tailnet traffic so Mullvad permits the kernel to route it
through `tailscale0`.

Based on [TheOrangeOne's guide][orangeone] and
[Mullvad's advanced Linux split-tunnelling documentation][mullvad-docs].
This variant adds IPv6 support, interface-restricted inbound rules, and a
dedicated systemd service.

**Tested on 2026-07-28 with:**

- Ubuntu 26.04
- Mullvad 2026.3
- Tailscale 1.98.9

Also confirmed working on Arch-based distributions (e.g. CachyOS), which
generally have `nft` at `/usr/bin/nft` rather than `/usr/sbin/nft` (see the
[Install](#install) note below), and where the `/etc/nftables.d` directory
does not exist by default — `install -Dm0644` creates it automatically, and
`tailscale-mullvad.service` also recreates it on every start as a safety net.

## What it installs

- [`mullvad-tailscale.nft`](mullvad-tailscale.nft) contains the firewall
  marks.
- [`tailscale-mullvad.service`](tailscale-mullvad.service) loads and removes
  that nftables table without taking ownership of the rest of the firewall.
  It also inserts a high-priority `ip rule` (preference 10) that sends
  fwmark-`0x6d6f6c65` traffic to Tailscale's routing table (52) before any
  unconditional rule in the main routing table can claim it, and removes that
  rule on stop.

The dedicated service does not enable the generic `nftables.service` and does
not flush Mullvad's or Tailscale's dynamically managed firewall tables.

> **Important:** Traffic addressed to the Tailnet bypasses Mullvad's tunnel
> routing so it can enter `tailscale0`. Tailscale still encrypts this traffic.
> Traffic not addressed to the Tailnet remains governed by Mullvad. Incoming
> connections also remain subject to your Tailscale access controls.

## Prerequisites

- Linux with systemd
- Mullvad VPN desktop app
- Tailscale
- nftables (`nft`)
- The standard Tailscale interface name, `tailscale0`

Confirm the required commands, services, and interface exist:

```bash
command -v mullvad tailscale nft
systemctl status mullvad-daemon tailscaled --no-pager
ip link show tailscale0
```

## Install

Clone the repository:

```bash
git clone https://github.com/patrickfeeney03/mullvad-plus-tailscale.git
cd mullvad-plus-tailscale
```

Check both configuration files before installing them:

```bash
sudo nft --check --file mullvad-tailscale.nft
systemd-analyze verify "$PWD/tailscale-mullvad.service"
```

No output means the checks succeeded.

Install and enable the compatibility service:

```bash
sudo install -Dm0644 mullvad-tailscale.nft \
  /etc/nftables.d/mullvad-tailscale.nft
sudo install -Dm0644 tailscale-mullvad.service \
  /etc/systemd/system/tailscale-mullvad.service
sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-mullvad.service
```

If `command -v nft` reports a path other than `/usr/sbin/nft` — for example
`/usr/bin/nft`, common on Arch-based distributions such as CachyOS — update
the service file to use the reported absolute path before installing it:

```bash
sed -i "s|/usr/sbin/nft|$(command -v nft)|g" tailscale-mullvad.service
```

fish shell equivalent:

```fish
set NFT_PATH (command -v nft)
sed -i "s|/usr/sbin/nft|$NFT_PATH|g" tailscale-mullvad.service
```

Do not enable the generic `nftables.service` solely for this setup.

## Verify

Check that the compatibility service is enabled and active:

```bash
systemctl is-enabled tailscale-mullvad.service
systemctl is-active tailscale-mullvad.service
```

The commands should report `enabled` and `active`.

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

The second command should report `table 52`. If the nft counters increase but
this still reports `main` (or another table), see
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

Pull the latest version, validate it, reinstall both files, and reload:

```bash
git pull --ff-only
sudo nft --check --file mullvad-tailscale.nft
systemd-analyze verify "$PWD/tailscale-mullvad.service"
sudo install -Dm0644 mullvad-tailscale.nft \
  /etc/nftables.d/mullvad-tailscale.nft
sudo install -Dm0644 tailscale-mullvad.service \
  /etc/systemd/system/tailscale-mullvad.service
sudo systemctl daemon-reload
sudo systemctl reload tailscale-mullvad.service
```

## Troubleshooting

Inspect the service and recent logs:

```bash
systemctl status tailscale-mullvad.service --no-pager
journalctl -u tailscale-mullvad.service -b --no-pager
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
table. Mullvad's own policy-routing rule
(`from all lookup main suppress_prefixlength 0`) has no fwmark condition, so
it matches every packet — marked or not — and `suppress_prefixlength 0` only
excludes the default route, not this more specific `/10` route. If this rule
has a lower preference number (i.e. higher priority) than Tailscale's own
rule, it wins before your mark is ever consulted.

Check for this:

```bash
ip route show table main | grep 100.64.0.0/10
ip rule show
```

If you see a `100.64.0.0/10` route in `main` on your WAN interface, and a
`from all lookup main` rule with a lower preference number than Tailscale's
own rule, that's the collision. `tailscale-mullvad.service` works around it
by inserting its own rule at a low preference number:

```text
ip rule add pref 10 fwmark 0x6d6f6c65 lookup 52
```

**Mullvad's own rule numbering is not stable.** In testing, Mullvad's
unconditional `lookup main suppress_prefixlength 0` rule appeared at
preference `5208` in one daemon session and preference `98` after a
reconnect (mullvad-daemon appears to renumber its rules on
reconnect/feature-toggle, e.g. LAN Sharing). Do not pick a preference number
by looking at Mullvad's current rules once and assuming it stays put — pick
something low enough to outrank *any* number Mullvad or Tailscale are likely
to use. `10` sits just above the kernel's own `local` rule (preference `0`,
never move anything above this) and well below the lowest preference either
Mullvad or Tailscale has been observed to use.

After any Mullvad reconnect, feature toggle, or update, re-check:

```bash
ip rule show
ip route get 100.x.y.z mark 0x6d6f6c65 fibmatch
```

and confirm the compatibility rule's preference number is still lower than
every unconditional `from all lookup main` rule Mullvad has installed.

## Disable or remove

Temporarily disable and restore the compatibility rule:

```bash
sudo systemctl stop tailscale-mullvad.service
sudo systemctl start tailscale-mullvad.service
```

Remove it completely:

```bash
sudo systemctl disable --now tailscale-mullvad.service
sudo rm /etc/systemd/system/tailscale-mullvad.service
sudo rm /etc/nftables.d/mullvad-tailscale.nft
sudo systemctl daemon-reload
```

Stopping the service deletes only the `inet mullvad_tailscale` table.

## Acknowledgements

- [Accessing Tailscale whilst using Mullvad][orangeone] by TheOrangeOne
- [Mullvad: Split tunneling with Linux (advanced)][mullvad-docs]

## License

MIT — see [LICENSE](LICENSE).

[orangeone]: https://theorangeone.net/posts/tailscale-mullvad/
[mullvad-docs]: https://mullvad.net/en/help/split-tunneling-with-linux-advanced
