# fips-peer

Helm chart + container image for running a publicly reachable
[FIPS](https://github.com/jmcorgan/fips) mesh peer node on Kubernetes.

The chart is deployed to the `bplab` cluster from the `park-it` GitOps repo.
This repo holds:

- `Dockerfile` / `entrypoint.sh` — the runtime image (FIPS daemon + nftables +
  IPv6 forwarding), published to `ghcr.io/notmandatory/fips-peer`.
- `charts/fips-peer/` — the Helm chart.

## Deployed node

| | |
|---|---|
| npub | `npub1ven0tdvy2u8hygx0ga2p36efuefcqc6wxjmft57xlk3z5vdftc8sp3let9` |
| Public endpoint | `136.41.161.69:2121` (UDP) |
| Kubernetes Service | `fips-peer` in namespace `fips-peer`, MetalLB VIP `10.21.0.154` |
| DNS | `fips.lab.bitcoinpark.com` → `10.21.0.154` |

## Build and push the image

```sh
podman login ghcr.io
podman build --build-arg FIPS_VERSION=0.5.2 \
  -t ghcr.io/notmandatory/fips-peer:0.5.2 .
podman push ghcr.io/notmandatory/fips-peer:0.5.2
```

Make the `ghcr.io/notmandatory/fips-peer` package **public** (or add
`imagePullSecrets` to the HelmRelease) so the cluster can pull it.

## Install with Helm

```sh
helm install fips-peer ./charts/fips-peer -n fips-peer --create-namespace
```

See `charts/fips-peer/README.md` for values.

## Firewall (pfSense)

The FIPS daemon advertises `136.41.161.69:2121` (UDP) as its endpoint. Forward
that public address/port to the Service's VIP on pfSense:

| Field | Value |
|-------|-------|
| Interface | WAN |
| Protocol | UDP |
| Destination | `136.41.161.69` port `2121` |
| Redirect target | `10.21.0.154` port `2121` |
| NAT reflection | not required |

The internal port must stay `2121` so it matches `external_addr`; only the
public destination can differ (then update `fipsConfig.transports.udp.external_addr`
to match).

## How remote users add this peer

A remote FIPS node can reach this peer in two ways.

### 1. Static peer (by npub + public IP)

Add to the remote node's `fips.yaml`:

```yaml
peers:
  - npub: "npub1ven0tdvy2u8hygx0ga2p36efuefcqc6wxjmft57xlk3z5vdftc8sp3let9"
    alias: "bplab-fips"
    addresses:
      - transport: udp
        addr: "136.41.161.69:2121"
    connect_policy: auto_connect
```

Then restart the remote daemon and confirm the link:

```sh
fipsctl show peers
```

### 2. Nostr discovery (no static config)

This node advertises itself on `relay.damus.io`, `nos.lol`, and `offchain.pub`
(Kind 37195). A remote node with Nostr rendezvous enabled can dial it by npub
without a static address:

```yaml
node:
  rendezvous:
    nostr:
      enabled: true
peers:
  - npub: "npub1ven0tdvy2u8hygx0ga2p36efuefcqc6wxjmft57xlk3z5vdftc8sp3let9"
    alias: "bplab-fips"
    via_nostr: true
    connect_policy: auto_connect
```

## Verify

```sh
kubectl -n fips-peer rollout status deploy/fips-peer
kubectl -n fips-peer exec deploy/fips-peer -c fips -- fipsctl show status
kubectl -n fips-peer exec deploy/fips-peer -c fips -- fipsctl show peers
```
