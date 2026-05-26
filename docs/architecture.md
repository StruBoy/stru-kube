# Architecture

## Physical layout

```
                            ┌──────────────────────────────┐
                            │     LAN  10.74.2.0/24        │
                            │     gw  10.74.2.1            │
                            └──────────────┬───────────────┘
                                           │
        ┌──────────────────────────────────┼──────────────────────────────────┐
        │                                  │                                  │
   ┌────┴────┐                        ┌────┴────┐                        ┌────┴────┐
   │  pve1   │ 10.74.2.20             │  pve2   │ 10.74.2.21             │  pve3   │ 10.74.2.22
   └────┬────┘                        └────┬────┘                        └────┬────┘
        │                                  │                                  │
   ┌────┴──────┐                      ┌────┴──────┐                      ┌────┴──────┐
   │ cp1 .30   │ control-plane        │ cp2 .31   │ control-plane        │ cp3 .32   │ control-plane
   │ w1  .33   │ worker (+100G LH)    │ w2  .34   │ worker (+100G LH)    │ w3  .35   │ worker (+100G LH)
   └───────────┘                      └───────────┘                      └───────────┘

                        API VIP 10.74.2.29 (kube-vip, floats across cp1-3)
                        MetalLB LB pool: 10.74.2.200 – 10.74.2.220
```

## IP map

| Role             | Name | Host | VMID | IP            | Notes                     |
|------------------|------|------|------|---------------|---------------------------|
| control-plane    | cp1  | pve1 | 110  | 10.74.2.30    | rke2-server               |
| control-plane    | cp2  | pve2 | 120  | 10.74.2.31    | rke2-server               |
| control-plane    | cp3  | pve3 | 130  | 10.74.2.32    | rke2-server               |
| worker           | w1   | pve1 | 111  | 10.74.2.33    | rke2-agent, longhorn=true |
| worker           | w2   | pve2 | 121  | 10.74.2.34    | rke2-agent, longhorn=true |
| worker           | w3   | pve3 | 131  | 10.74.2.35    | rke2-agent, longhorn=true |
| K8s API VIP      | —    | —    | —    | 10.74.2.29    | kube-vip ARP              |
| MetalLB pool     | —    | —    | —    | 10.74.2.200–220 | LoadBalancer services    |

Pod CIDR `10.42.0.0/16`, Service CIDR `10.43.0.0/16`, cluster DNS suffix `cluster.local`.

## Component stack

| Layer              | Choice                                                |
|--------------------|-------------------------------------------------------|
| Hypervisor         | Proxmox VE 8                                          |
| Guest OS           | Ubuntu 24.04 (cloud image)                            |
| Provisioning       | OpenTofu + `bpg/proxmox`                              |
| Configuration      | Ansible (community.general, ansible.posix, kubernetes.core) |
| Kubernetes         | RKE2 (CNCF-certified)                                 |
| CNI                | Canal (RKE2 default)                                  |
| API HA             | kube-vip (ARP, static pod)                            |
| LoadBalancer       | MetalLB (L2 mode)                                     |
| Ingress            | Traefik (bundled with RKE2, override via HelmChartConfig) |
| Storage            | Longhorn (3 replicas, default StorageClass)           |

## Decisions log

- **bpg/proxmox over Telmate/proxmox.** Telmate has stalled; bpg has native cloud-init, image download, and template modeling.
- **kube-vip over HAProxy+keepalived.** One static-pod manifest beats two extra daemons + a config file Ansible has to babysit.
- **Keep RKE2's bundled Traefik.** Avoids managing CRDs and the upgrade path; we customize via `HelmChartConfig`.
- **Disable RKE2's ServiceLB.** MetalLB owns `type: LoadBalancer` IPs.
- **Canal over Cilium.** Cilium is materially better for NetworkPolicy at scale, eBPF observability, and BGP — none of which we need in a 6-node homelab. Canal is the default and lowest-friction choice.
- **Static Ansible inventory written by Tofu.** Dynamic Proxmox inventory adds runtime PVE dependency and duplicates credentials. A flat file is diffable and works offline.
