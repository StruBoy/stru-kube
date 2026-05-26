# stru-kube

LAN-hosted, HA Kubernetes cluster on Proxmox VE. Six VMs (3 control-plane + 3 workers) running RKE2 with kube-vip, MetalLB, Longhorn, and Traefik. Provisioned end-to-end by OpenTofu (infra) and Ansible (configuration).

## Topology

- **Proxmox hosts:** pve1 (10.74.2.20), pve2 (10.74.2.21), pve3 (10.74.2.22)
- **Cluster VMs:** cp1/cp2/cp3 + w1/w2/w3 (one of each role per PVE host)
- **API VIP:** 10.74.2.29 (kube-vip ARP mode)
- **MetalLB pool:** 10.74.2.200-10.74.2.220

See [PLAN.md](PLAN.md) for the full design and [docs/architecture.md](docs/architecture.md) for the IP map.

## Prerequisites

- An existing 3-node Proxmox VE cluster reachable at the IPs above
- `tofu` >= 1.6, `ansible` >= 2.16, `kubectl`, `helm` >= 3.13 on your workstation
- SSH keypair (`~/.ssh/id_ed25519` by default)
- One-time Proxmox prep — see [Phase 1 in PLAN.md](PLAN.md#phase-1--proxmox-prep-one-time-manual):
  - Create a `terraform@pve` user + API token with the `TerraformProv` role
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
