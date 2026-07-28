> Based on TheOrangeOne's "Accessing Tailscale whilst using Mullvad" and Mullvad's advanced Linux split-tunnelling documentation.

Tested 2026-07-28:
Ubuntu 26.04
Mullvad 2026.3
Tailscale 1.98.9

# Using Tailscale and Mullvad together on Linux

This configuration allows traffic to and from Tailscale devices while the
Mullvad desktop app is connected. It uses Mullvad's documented nftables marks
to route Tailnet traffic outside the Mullvad tunnel and into `tailscale0`.

The configuration consists of two files:

- `/etc/nftables.d/mullvad-tailscale.nft` contains the actual firewall marks.
- `/etc/systemd/system/tailscale-mullvad.service` loads the marks at boot.

The dedicated service manages only its own `mullvad_tailscale` table. It does
not flush or take ownership of the rest of the system firewall.

## Prerequisites

- Linux with systemd
- Mullvad VPN desktop app
- Tailscale
- nftables (`nft`)
- The standard Tailscale interface name, `tailscale0`

Confirm the commands and services exist:

```bash
command -v mullvad tailscale nft
systemctl status mullvad-daemon tailscaled --no-pager
ip link show tailscale0
```

## 1. Create the nftables rule

Create the configuration directory:

```bash
sudo install -d -m 0755 /etc/nftables.d
```

Open the rules file:

```bash
sudoedit /etc/nftables.d/mullvad-tailscale.nft
```

Paste:

```nft
table inet mullvad_tailscale {
 chain output {
  type route hook output priority -100; policy accept;

  # Bypass Mullvad for traffic addressed to Tailscale.
  ip daddr 100.64.0.0/10 counter ct mark set 0x00000f41 meta mark set 0x6d6f6c65
  ip6 daddr fd7a:115c:a1e0::/48 counter ct mark set 0x00000f41 meta mark set 0x6d6f6c65
 }

 chain input {
  type filter hook input priority -100; policy accept;

  # Mark only traffic that actually arrived through Tailscale.
  iifname "tailscale0" ip saddr 100.64.0.0/10 counter ct mark set 0x00000f41 meta mark set 0x6d6f6c65
  iifname "tailscale0" ip6 saddr fd7a:115c:a1e0::/48 counter ct mark set 0x00000f41 meta mark set 0x6d6f6c65
 }
}
```

Check the syntax before loading it:

```bash
sudo nft --check --file /etc/nftables.d/mullvad-tailscale.nft
```

No output means the check succeeded.

### Address ranges

- `100.64.0.0/10` is Tailscale's IPv4 shared-address range. It covers
  `100.64.0.0` through `100.127.255.255`.
- `fd7a:115c:a1e0::/48` is Tailscale's IPv6 range.

The output rules allow this computer to initiate Tailnet connections. The
input rules allow other Tailnet devices to initiate connections to this
computer. Incoming exceptions are restricted to packets that actually arrive
through `tailscale0`.

## 2. Create the systemd service

Open the service file:

```bash
sudoedit /etc/systemd/system/tailscale-mullvad.service
```

Paste:

```ini
[Unit]
Description=Allow Tailscale traffic alongside Mullvad VPN
Documentation=https://theorangeone.net/posts/tailscale-mullvad/
Documentation=https://mullvad.net/en/help/split-tunneling-with-linux-advanced
After=mullvad-daemon.service tailscaled.service
Wants=mullvad-daemon.service tailscaled.service

[Service]
Type=oneshot
ExecStartPre=/usr/sbin/nft destroy table inet mullvad_tailscale
ExecStart=/usr/sbin/nft -f /etc/nftables.d/mullvad-tailscale.nft
ExecReload=/usr/sbin/nft destroy table inet mullvad_tailscale
ExecReload=/usr/sbin/nft -f /etc/nftables.d/mullvad-tailscale.nft
ExecStop=/usr/sbin/nft destroy table inet mullvad_tailscale
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

If `command -v nft` reports a location other than `/usr/sbin/nft`, use the
reported absolute path in the service.

Validate and start the service:

```bash
sudo systemd-analyze verify /etc/systemd/system/tailscale-mullvad.service
sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-mullvad.service
```

Do not enable the generic `nftables.service` solely for this setup. This
dedicated service provides persistence without making the generic service
responsible for Mullvad's or Tailscale's dynamically managed firewall tables.

## 3. Verify the result

Check that the compatibility service is enabled and active:

```bash
systemctl is-enabled tailscale-mullvad.service
systemctl is-active tailscale-mullvad.service
```

Both commands should report the expected states:

```text
enabled
active
```

Confirm that Mullvad remains connected:

```bash
mullvad status
curl https://am.i.mullvad.net/connected
```

Find an online Tailnet device:

```bash
tailscale status
```

Test it using its Tailscale IP or MagicDNS name:

```bash
tailscale ping 100.x.y.z
ping -c 3 100.x.y.z
```

Finally, inspect the rule and its packet counters:

```bash
sudo nft list table inet mullvad_tailscale
```

The counters beside the matching IPv4 or IPv6 rules should increase when
Tailnet traffic passes through them.

## Updating the rule

After editing `/etc/nftables.d/mullvad-tailscale.nft`, check and reload it:

```bash
sudo nft --check --file /etc/nftables.d/mullvad-tailscale.nft
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
the two mark values against Mullvad's current advanced Linux documentation
before changing them:

```text
Connection-tracking mark: 0x00000f41
Routing/meta mark:         0x6d6f6c65
```

## Disable or remove

Temporarily disable the compatibility rule:

```bash
sudo systemctl stop tailscale-mullvad.service
```

Restore it:

```bash
sudo systemctl start tailscale-mullvad.service
```

Remove the setup completely:

```bash
sudo systemctl disable --now tailscale-mullvad.service
sudo rm /etc/systemd/system/tailscale-mullvad.service
sudo rm /etc/nftables.d/mullvad-tailscale.nft
sudo systemctl daemon-reload
```

Stopping the service destroys only the `inet mullvad_tailscale` table.

## Sources

- [Accessing Tailscale whilst using Mullvad](https://theorangeone.net/posts/tailscale-mullvad/)
- [Mullvad: Split tunneling with Linux (advanced)](https://mullvad.net/en/help/split-tunneling-with-linux-advanced)
