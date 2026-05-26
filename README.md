# stru-kube

LAN-hosted, HA Kubernetes cluster on Proxmox VE. Six VMs (3 control-plane + 3 workers) running RKE2 with kube-vip, MetalLB, Longhorn, and Traefik. Provisioned end-to-end by OpenTofu (infra) and Ansible (configuration).

## Topology

- **Proxmox hosts:** the `stru-cluster` PVE cluster — `stru-prox0/1/2` at `10.74.2.20/21/22` (your node names may differ; see [docs/envsetup.md §2.7](docs/envsetup.md#27-discover-your-pve-node-names-critical--go-to-terraformtfvars))
- **Cluster VMs:** cp1/cp2/cp3 + w1/w2/w3 (one of each role per PVE host)
- **API VIP:** 10.74.2.29 (kube-vip ARP mode)
- **Ingress:** `rke2-ingress-nginx` (DaemonSet, hostPort 80/443 on every node)
- **MetalLB pool:** 10.74.2.200-10.74.2.220 (available for app `type: LoadBalancer` services)

See [PLAN.md](PLAN.md) for the full design and [docs/architecture.md](docs/architecture.md) for the IP map.

## Prerequisites

- An existing 3-node Proxmox VE cluster reachable at the IPs above
- `tofu` >= 1.6, `ansible` >= 2.16, `kubectl`, `helm` >= 3.13 on your workstation (`brew install opentofu ansible kubernetes-cli helm`)
- SSH keypair (`~/.ssh/id_ed25519` by default) **loaded into ssh-agent** — bpg/proxmox ignores `~/.ssh/config` (see [docs/envsetup.md §4](docs/envsetup.md))
- One-time Proxmox prep — see [Phase 1 in PLAN.md](PLAN.md#phase-1--proxmox-prep-one-time-manual) or the more detailed [docs/envsetup.md](docs/envsetup.md):
  - Discover the actual node names (`cat /etc/pve/.members`)
  - Create the `terraform@pve` user + API token with the `TerraformProv` role (incl. `Datastore.Allocate`)
  - Enable **Snippets** content type on `local` storage in the PVE GUI

## Quickstart

```sh
cp .env.example .env && $EDITOR .env       # fill in PROXMOX_VE_*, RKE2_TOKEN, etc.
set -a; source .env; set +a

make plan        # tofu init + tofu plan
make apply       # tofu apply — provisions 6 VMs, writes ansible inventory
make configure   # ansible-playbook site.yml — installs RKE2
make addons      # ansible-playbook addons.yml — MetalLB, Longhorn, Traefik
make verify      # kubectl checks
```

Kubeconfig lands at `kubeconfig/rke2.yaml`. `export KUBECONFIG=$PWD/kubeconfig/rke2.yaml`.

## Layout

| Path | Purpose |
|---|---|
| [opentofu/](opentofu/) | Proxmox VM provisioning |
| [ansible/](ansible/) | RKE2 install + cluster config |
| [addons/](addons/) | Helm values + manifests for MetalLB, Longhorn, Traefik |
| [docs/](docs/) | Architecture, runbook, troubleshooting |
| [PLAN.md](PLAN.md) | Full design document |
