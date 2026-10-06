# Security verification

How to confirm that the `fips-peer` pod exposes only what it should and blocks
everything else. There are four independent layers; verify each.

| Layer | Guards | Mechanism |
|-------|--------|-----------|
| 1. Mesh firewall | inbound on the `fips0` mesh interface | nftables `inet fips`, default-deny |
| 2. Pod ingress | inbound to the pod (its `eth0`) | Kubernetes `NetworkPolicy` (UDP/2121 only) |
| 3. Service / LAN | the externally reachable address | `LoadBalancer` Service exposes only UDP/2121 |
| 4. Listeners | sockets bound inside the pod | only the FIPS transport on a wildcard |

The pod is **not** `hostNetwork`, so it adds no listeners to the Kubernetes node
itself. Layer 1 does not filter the pod's `eth0`; layer 2 does.

---

## 1. Mesh firewall (`fips0`) — default-deny

```sh
kubectl -n fips-peer exec deploy/fips-peer -c fips -- nft list table inet fips
```

Expected:

```text
table inet fips {
        chain inbound {
                type filter hook input priority filter; policy accept;
                iifname != "fips0" return
                ct state established,related accept
                icmpv6 type echo-request accept
                counter packets 0 bytes 0 drop
        }
}
```

- `iifname != "fips0" return` — the chain is a no-op for every interface except
  the mesh TUN.
- `ct state established,related accept` — replies to flows this node initiated.
- `icmpv6 type echo-request accept` — `ping6` reachability is intentionally
  allowed.
- `counter … drop` — **everything else inbound on `fips0` is dropped.**

The `include "/etc/fips/fips.d/*.nft"` line is absent because the drop-in glob
matches nothing; nft omits empty includes. That is expected.

### Confirm the baseline actually loaded

If the table is missing, the baseline failed to load. Check the container log:

```sh
kubectl -n fips-peer logs deploy/fips-peer -c fips | grep -i "nft\|firewall"
```

```sh
kubectl -n fips-peer exec deploy/fips-peer -c fips -- nft list tables
```

### Prove it is blocking (active test)

The drop counter is passive, so generate a disallowed packet and watch it rise.
From a **second FIPS node** you control, target a port on this node's mesh
address:

```sh
nc -6 -vz <npub>.fips 22          # or: curl -6 "http://<npub>.fips:8080/"
```

Then re-check the counter — it must have incremented:

```sh
kubectl -n fips-peer exec deploy/fips-peer -c fips -- nft list table inet fips | grep counter
```

`ping6 <npub>.fips` should still succeed and must **not** move the counter.

---

## 2. Pod ingress — NetworkPolicy (UDP/2121 only)

```sh
kubectl -n fips-peer get networkpolicy fips-peer -o yaml
```

Expected `spec`:

```yaml
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/instance: fips-peer
      app.kubernetes.io/name: fips-peer
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - ports:
        - protocol: UDP
          port: 2121
  egress:
    - {}
```

`egress: [{}]` allows all outbound (FIPS dials static peers over UDP, Nostr
relays over TCP/443, and STUN). Ingress is limited to the FIPS transport.

### Prove enforcement (negative test)

```sh
PODIP=$(kubectl -n fips-peer get pod -l app.kubernetes.io/name=fips-peer \
  -o jsonpath='{.items[0].status.podIP}')

kubectl -n fips-peer run nettest --rm -it --restart=Never \
  --image=nicolaka/netshoot -- bash
```

Inside the test pod:

```sh
nc -vz  -w3 "$PODIP" 22       # times out  -> ingress blocked
nc -vz  -w3 "$PODIP" 2121     # times out  -> only UDP is allowed
nc -vzu -w3 "$PODIP" 2121     # open|filtered
```

TCP connections to any port time out (Cilium drops them); only UDP/2121 is
permitted.

---

## 3. Service / LAN surface

```sh
kubectl -n fips-peer get svc fips-peer
```

Expected:

```text
NAME        TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)          AGE
fips-peer   LoadBalancer   10.43.233.85   10.21.0.154   2121:32662/UDP   ...
```

The Service exposes **only** `2121/UDP`. From a host on the cluster LAN:

```sh
sudo nmap -Pn -sU -p 2121 10.21.0.154     # expect: 2121/udp open|filtered
sudo nmap -Pn -p- 10.21.0.154             # expect: every TCP port closed/filtered
```

Interpretation:

- `2121/udp open|filtered` is the **expected** result: FIPS does not answer a
  random UDP probe (no Noise handshake), so nmap cannot distinguish open from
  filtered. The port is reachable.
- All TCP closed/filtered is correct. Any `open` TCP port is an unexpected
  exposure and must be investigated.
- If `EXTERNAL-IP` is `<pending>` or the host is unreachable, the VIP is not
  assigned — check MetalLB, not the pod:

  ```sh
  kubectl -n fips-peer describe svc fips-peer
  kubectl -n bplab-system get ipaddresspool,l2advertisement
  kubectl get svc -A -o wide | grep 10.21.0.154
  kubectl -n bplab-system logs deploy/metallb-controller --tail=50
  ```

`externalTrafficPolicy: Local` means the VIP is served only by the node running
the pod.

---

## 4. Listener inventory

```sh
kubectl -n fips-peer exec deploy/fips-peer -c fips -- ss -tulnp
```

Expected:

```text
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
udp   UNCONN 0      0      0.0.0.0:2121       0.0.0.0:*      users:(("fips",pid=1,fd=9))
udp   UNCONN 0      0      [::1]:5354         [::]:*         users:(("fips",pid=1,fd=17))
```

- `udp 0.0.0.0:2121` — the intended FIPS transport, the only wildcard listener.
- `udp [::1]:5354` — the DNS responder, **loopback-only** (not reachable
  off-box).
- No TCP listeners.

The control socket is a unix domain socket, not a network socket, so it does not
appear in `ss -tulnp`. Confirm:

```sh
kubectl -n fips-peer exec deploy/fips-peer -c fips -- ss -xlp | grep fips
```

---

## Caveats

- Layer 1 polices `fips0` only. Do not expect it to filter `eth0`; layer 2 does.
- If you add `/etc/fips/fips.d/*.nft` drop-ins to expose mesh services, the
  `inbound` chain is no longer pure default-deny — re-run layer 1 and confirm
  each opened port is intentional.
- Keep `replicas: 1` (strategy `Recreate`): one identity and one `fips0` per
  node.
