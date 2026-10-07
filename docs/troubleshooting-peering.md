# Troubleshooting peering

A FIPS peer node can accept any peer (`transports.udp.accept_connections: true`,
no peer ACL), yet still fail to link for reasons that are invisible at the
default log level. This is the decision tree we use to find them.

The single most useful command is `fipsctl show transports` on both ends — the
UDP `packets_recv` counter tells you whether traffic is even arriving.

---

## Quick triage

```sh
# on the k8s node
kubectl -n fips-peer exec deploy/fips-peer -c fips -- fipsctl show transports
kubectl -n fips-peer exec deploy/fips-peer -c fips -- fipsctl show peers
kubectl -n fips-peer logs deploy/fips-peer -c fips --tail=300 \
  | grep -iE "handshake|peer|acl|drop|version|npub"
```

```sh
# on the remote peer
fipsctl show transports
fipsctl show peers
```

Then work through the sections below in order.

---

## 1. Is the peer's traffic arriving at all?

Note UDP `packets_recv`, have the remote peer attempt to connect, then read it
again. Any datagram counts (valid handshake or not).

- **Flat** → nothing is arriving. The problem is the network path or the remote
  peer is not sending. Go to §5.
- **Rises but no handshake log** → packets arrive but are dropped before the
  handshake. Most likely the ACL (§2) or a version mismatch (§3).
- **Handshake lines appear** → the exchange is starting; look at why it doesn't
  complete (§4).

You can send a bare UDP probe to isolate reachability from FIPS entirely:

```sh
echo x | nc -u -w1 <public-ip> 2121      # from outside
echo x | nc -u -w1 <lb-vip>    2121      # from the cluster LAN
```

Both should increment `packets_recv` by 1 (and `bytes_recv` by 2). If the LAN
probe works but the external one doesn't, the fault is the external firewall /
upstream NAT, not Kubernetes.

---

## 2. Peer ACL — the allowlist trap

FIPS ships an optional peer ACL (`peers.allow` / `peers.deny`, one npub, alias,
or `ALL` per line; comments with `#`). Evaluation is **first match wins,
default-allow on no match**:

1. `peers.allow` — match admits the handshake (overrides `peers.deny`).
2. `peers.deny` — match refuses the handshake.
3. Otherwise admitted.

The trap: **`ALL` in `peers.deny` turns `peers.allow` into a strict allowlist.**
Any npub not listed in `peers.allow` is rejected at step 2 — even though the node
otherwise accepts anyone. This produces, at `info` level:

```text
WARN fips::node::acl: Rejected peer by ACL peer=<alias> npub=<npub> \
  context=outbound_connect decision=denylist match
WARN fips::node::peering::driver: Retry connection initiation failed ...
```

If you see `decision=denylist match`, the *remote* node's ACL is refusing you.
Fix on that node:

- **Admit this peer:** add its npub to `peers.allow`.
- **Admit everyone:** remove the `ALL` line from `peers.deny` (a populated
  `peers.allow` with an empty `peers.deny` is *not* a strict allowlist — it is
  default-allow plus an always-admit set).

ACL files auto-reload on mtime change; no restart required.

---

## 3. Version mismatch

FIPS drops packets whose FMP prefix version differs from `FMP_VERSION`
(currently `0`). This happens **before** any handshake processing and is logged
at **DEBUG** only:

```text
DEBUG fips::node::dataplane::rx_loop: Unknown FMP version, dropping
      version=<n> transport_id=...
```

Symptom: `packets_recv` rises, but the peer never appears and there are no
handshake lines at `info`. Confirm by enabling debug:

```sh
# temporary (Flux reverts on next reconcile)
kubectl -n fips-peer set env deploy/fips-peer RUST_LOG=debug
kubectl -n fips-peer logs deploy/fips-peer -c fips -f | grep -iE "version|drop"
# or set fipsConfig.node.log_level: debug in the HelmRelease for a persistent change
```

Check both ends agree: `fips --version` (and `fipsctl show status`). Peers that
link successfully to the public test mesh are version-compatible with it, so if
one peer fails while the test-mesh peers work, the mismatch is specific to that
peer's build.

---

## 4. Connected, then disconnecting (`reason=Shutdown`)

```text
INFO fips::node::dataplane::dispatch: Peer sent disconnect notification peer=<npub> reason=Shutdown
```

`DisconnectReason::Shutdown` means the **remote daemon deliberately closed the
link** (it is stopping). It is *not* a protocol/version error and *not* a
firewall drop. If a peer flaps with this reason, look at that peer's process —
it is restarting or being killed (crash loop, `just restart`, a supervisor, or
the container being stopped). Restore its stability and the link returns.

This is distinct from a link dying silently (no disconnect message), which
points at the network path or UDP buffer drops (§5, §6).

---

## 5. Network path — Service/VIP vs `hostNetwork`

This chart can expose the UDP transport two ways:

- **LoadBalancer (default):** `Service` + MetalLB VIP; pfSense DNATs the public
  port to the VIP. Works in the reference cluster, but the return path crosses
  Cilium DNAT and pfSense NAT — if the peer's `msg2` arrives from an unexpected
  source, the peer rejects it and never links.
- **`hostNetwork: true`:** FIPS binds the node's `eth0:2121` directly; pfSense
  DNATs to the **node IP**. No Service/VIP/Cilium/SNAT in the path — the most
  robust shape for a publicly reachable peer. Pin the pod with `nodeSelector`
  so the node IP is stable, and set `service.enabled: false`.

Diagnose where packets die:

```sh
NODE=$(kubectl -n fips-peer get pod -l app.kubernetes.io/name=fips-peer \
  -o jsonpath='{.items[0].spec.nodeName}')
kubectl debug node/$NODE -it --image=nicolaka/netshoot -- tcpdump -ni any udp port 2121
```

- Nothing on the node → the packet never left the external firewall (check the
  WAN allow rule and the DNAT target, and confirm the WAN IP).
- On the node but not delivered to the pod → Service/VIP/NetworkPolicy path.
- Delivered but no handshake → §2 or §3.

Caveats for `hostNetwork`:
- `NetworkPolicy` is **not enforced** for host-network pods; the node firewall
  is what constrains the port.
- The `fips0` default-deny baseline still applies (it polices the mesh TUN, not
  `eth0`).

---

## 6. UDP socket buffers

At startup the daemon requests 2 MB socket buffers; if the node's
`net.core.rmem_max` / `wmem_max` are lower, the kernel clamps them and logs:

```text
WARN fips::transport::udp::io::unix: UDP recv buffer clamped by kernel
     (increase net.core.rmem_max) requested=2097152 actual=425984
```

Clamped buffers cause silent packet loss under load. Raise the limits on the
**nodes** (`net.core.*` are not namespaced):

```sh
sysctl -w net.core.rmem_max=4194304 net.core.wmem_max=4194304
# persist via /etc/sysctl.d/60-fips.conf
```

Or lower `fipsConfig.transports.udp.recv_buf_size` / `send_buf_size` to match the
clamp (silences the warning, caps throughput).

---

## 7. Command reference

| Goal | Command |
|------|---------|
| Transport counters (reachability) | `fipsctl show transports` |
| Peer link state + addresses | `fipsctl show peers` |
| Node identity / version | `fipsctl show status` |
| Debug logs (version drops, handshakes) | `RUST_LOG=debug fips` |
| ACL rejections | `grep -i "acl\|denylist" <logs>` |
| Node-side packet capture | `kubectl debug node/<node> -- tcpdump -ni any udp port 2121` |

### Checklist

1. `packets_recv` rises on the target? If not → §5 (path) or the peer isn't sending.
2. `decision=denylist match`? → §2 (peer ACL on the *other* node).
3. `Unknown FMP version, dropping`? → §3 (build mismatch).
4. `reason=Shutdown` from a peer? → §4 (that peer is restarting).
5. Handshake completes but link dies under load? → §6 (UDP buffers).
6. Public path unreliable with the VIP? → §5 (`hostNetwork`).
