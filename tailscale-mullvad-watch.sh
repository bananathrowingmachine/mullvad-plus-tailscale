#!/usr/bin/env bash
# Keeps the Tailscale fwmark routing rule ahead of Mullvad's Local Network
# Sharing rule ("lookup main suppress_prefixlength 0"), which has no fwmark
# condition and unconditionally grabs Tailscale's CGNAT range whenever the
# WAN interface also sits inside 100.64.0.0/10 (common with CGNAT ISPs).
#
# Mullvad reinserts this rule at an arbitrary -- often very low -- priority
# every time it connects or reconnects, including manual disconnects to work
# around sites that block VPN traffic. Reconnects may also briefly touch or
# remove our own fwmark rule as part of a broader rule rebuild, so this does
# not rely solely on catching every netlink event: it reacts immediately to
# rule-change events AND polls on a fixed interval as a safety net.
set -uo pipefail

MARK="0x6d6f6c65"
LAN_PRIORITY=20000
FWMARK_PRIORITY=1
POLL_INTERVAL=1

apply_fix() {
    local current_pref
    current_pref=$(ip -4 rule show | awk -F: '/lookup main suppress_prefixlength 0/{print $1; exit}')
    if [[ -n "$current_pref" && "$current_pref" != "$LAN_PRIORITY" ]]; then
        ip rule del priority "$current_pref" from all lookup main suppress_prefixlength 0 2>/dev/null
        ip rule add priority "$LAN_PRIORITY" from all lookup main suppress_prefixlength 0
        echo "$(date -Is): demoted Mullvad LAN-sharing rule from priority $current_pref to $LAN_PRIORITY"
    fi

    if ! ip rule show | grep -q "fwmark $MARK lookup 52"; then
        ip rule add priority "$FWMARK_PRIORITY" fwmark "$MARK" lookup 52
        echo "$(date -Is): re-added Tailscale fwmark rule at priority $FWMARK_PRIORITY"
    fi
}

apply_fix

# Fixed-interval safety net: catches anything the event stream below might
# miss (e.g. rapid/batched netlink operations during a Mullvad reconnect).
(
    while true; do
        sleep "$POLL_INTERVAL"
        apply_fix
    done
) &

# Event-driven fast path: reacts within a fraction of a second of any
# routing-rule change instead of waiting for the next poll tick.
ip monitor rule 2>/dev/null | while read -r _line; do
    sleep 0.2
    apply_fix
done
