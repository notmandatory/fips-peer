# fips-peer

A Helm chart that runs a publicly reachable [FIPS](https://github.com/jmcorgan/fips)
mesh peer node on Kubernetes.

Unlike the upstream `fips` chart (a host-network DaemonSet), this chart runs a
**single-replica Deployment in the pod network namespace**. It creates the
`fips0` TUN device, accepts inbound mesh peers on UDP/2121, and exposes that
port through a `LoadBalancer` Service so an external firewall (e.g. pfSense) can
DNAT a public IP/port to the node.

## What it creates

- A `Deployment` (replicas: 1, strategy: Recreate) running the FIPS daemon with
  `NET_ADMIN` and `/dev/net/tun`.
- A `ConfigMap` holding `fips.yaml`, `hosts`, and the default-deny `fips.nft`
  mesh firewall baseline.
- A `ServiceAccount`, a `NetworkPolicy` (ingress restricted to UDP/2121), and a
  `LoadBalancer` Service.
- Optionally a `Secret` when `identity.nsec` is set (otherwise bring your own
  via `identity.existingSecret`).

The node identity (nsec) is injected into `fips.yaml` by an init container and
never written to the ConfigMap.

## Key values

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `ghcr.io/notmandatory/fips-peer` | Runtime image |
| `image.tag` | `Chart.AppVersion` | Image tag |
| `identity.existingSecret` | `fips-peer-nsec` | Secret holding the nsec |
| `identity.secretKey` | `nsec` | Key within that Secret |
| `identity.npub` | — | Display-only npub for NOTES |
| `fipsConfig` | see `values.yaml` | Rendered into `fips.yaml` |
| `fipsConfig.transports.udp.external_addr` | — | Public `ip:port` peers dial |
| `fipsConfig.peers` | test mesh | Static bootstrap peers |
| `meshFirewall.enabled` | `true` | Load the `fips0` default-deny baseline |
| `service.type` | `LoadBalancer` | Service type |
| `service.annotations` | MetalLB VIP | e.g. `metallb.io/loadBalancerIPs` |
| `networkPolicy.enabled` | `true` | Restrict pod ingress to UDP/2121 |

## Install

```sh
helm install fips-peer ./charts/fips-peer -n fips-peer --create-namespace
```

## Public reachability

Set `fipsConfig.transports.udp.external_addr` to the public `ip:port` and point
your firewall's UDP DNAT at the Service's `EXTERNAL-IP`:

```sh
kubectl -n fips-peer get svc fips-peer
```

## Namespace Pod Security

The pod needs `NET_ADMIN`. If the namespace enforces the `restricted` Pod
Security Standard, label it:

```sh
kubectl label namespace fips-peer pod-security.kubernetes.io/enforce=privileged --overwrite
```
