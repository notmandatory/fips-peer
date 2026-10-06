#!/bin/sh
set -eu

# Enable IPv6 forwarding in this network namespace so the node can relay
# mesh traffic between its peers (full mesh router, leaf_only: false).
# Requires NET_ADMIN; best-effort so a failure does not stop the daemon.
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || \
    echo "warning: could not enable net.ipv6.conf.all.forwarding" >&2

# In the background: wait for the fips0 TUN interface to exist, then load
# the default-deny mesh firewall baseline (packages/common/fips.nft). It
# polices ONLY fips0 inbound and is a no-op for every other interface, so
# it is safe to load inside the pod network namespace.
(
    for _ in $(seq 1 50); do
        ip link show fips0 >/dev/null 2>&1 && break
        sleep 0.2
    done

    if [ -f /etc/fips/fips.nft ]; then
        nft -f /etc/fips/fips.nft || \
            echo "warning: failed to load /etc/fips/fips.nft" >&2
    else
        echo "warning: /etc/fips/fips.nft not found, firewall baseline not applied" >&2
    fi
) &

# exec so fips is PID 1 and receives SIGTERM directly.
exec /usr/bin/fips "$@"
