# stru-kube

LAN-hosted, HA Kubernetes cluster on Proxmox VE. Six VMs (3 control-plane + 3 workers) running RKE2 with kube-vip, MetalLB, Longhorn, and the bundled `rke2-ingress-nginx`, plus ArgoCD + Sealed Secrets for GitOps. Provisioned end-to-end by OpenTofu (infra) and Ansible (configuration).

## Topology

- **Proxmox hosts:** the `stru-cluster` PVE cluster — `stru-prox0/1/2` at `10.74.2.20/21/22` (your node names may differ; see [docs/envsetup.md §2.7](docs/envsetup.md#27-discover-your-pve-node-names-critical--go-to-terraformtfvars))
- **Cluster VMs:** cp1/cp2/cp3 + w1/w2/w3 (one of each role per PVE host)
- **API VIP:** 10.74.2.29 (kube-vip ARP mode)
- **Ingress:** `rke2-ingress-nginx` (DaemonSet, hostPort 80/443 on every node)
- **MetalLB pool:** 10.74.2.200-10.74.2.220 (available for app `type: LoadBalancer` services)
- **GitOps:** ArgoCD (UI at `argocd.lan`, insecure behind nginx) reconciling from separate manifest repos, with Sealed Secrets for committing secrets to Git

See [PLAN.md](PLAN.md) for the full design and [docs/architecture.md](docs/architecture.md) for the IP map.

## Prerequisites

- An existing 3-node Proxmox VE cluster reachable at the IPs above
- `tofu` >= 1.6, `ansible` >= 2.16, `kubectl`, `helm` >= 3.13 on your workstation (`brew install opentofu ansible kubernetes-cli helm`). `make preflight` verifies all four.
- SSH keypair (`~/.ssh/id_ed25519` by default) **loaded into ssh-agent** — bpg/proxmox ignores `~/.ssh/config` (see [docs/envsetup.md §4](docs/envsetup.md))
- Proxmox prep is automated by `make bootstrap-pve`. It creates the `terraform@pve` user + `TerraformProv` role, enables Snippets on `local`, and validates `var.pve_hosts` against the live cluster. The only manual step it can't do for you is the API token itself — Proxmox prints the secret only once, so the play emits the exact `pveum user token add ...` command to run and paste back into `.env`. See [docs/envsetup.md §2.0](docs/envsetup.md#20-the-automated-path-make-bootstrap-pve-recommended).

## Quickstart

```sh
cp .env.example .env && $EDITOR .env             # fill in PROXMOX_VE_ENDPOINT/SSH_USERNAME, RKE2_TOKEN, etc.
                                                  # (leave PROXMOX_VE_API_TOKEN blank for now — bootstrap-pve issues it)
set -a; source .env; set +a

cp ansible/inventory/pve-hosts.ini.example ansible/inventory/pve-hosts.ini   # adjust to your PVE nodes
make bootstrap-pve                               # one-time PVE setup: TerraformProv role, terraform@pve user, Snippets.
                                                  # Prints the `pveum user token add ...` command for you to run on a PVE host.
$EDITOR .env                                     # paste the printed token into PROXMOX_VE_API_TOKEN
set -a; source .env; set +a                      # re-source after the edit

make preflight                                   # toolchain + env + ssh-agent + API reachability sanity check
make plan                                        # tofu init + tofu plan (preflight runs as a dep)
make apply                                       # tofu apply — provisions 6 VMs, writes ansible inventory
make configure                                   # ansible-playbook site.yml — installs RKE2 (preflight runs as a dep)
make addons                                      # ansible-playbook addons.yml — MetalLB + Longhorn + ArgoCD + Sealed Secrets
make verify                                      # kubeconfig + VIP reachability + kubectl checks
# make verify-full                               # optional: end-to-end LoadBalancer smoke test
```

To return the Proxmox cluster to a completely clean state (VMs gone, terraform user/role/token removed, Snippets reverted): `make wipeclean CONFIRM=yes`.

Kubeconfig lands at `kubeconfig/rke2.yaml`. `export KUBECONFIG=$PWD/kubeconfig/rke2.yaml`.

## GitOps

`make addons` installs ArgoCD and Sealed Secrets alongside MetalLB/Longhorn. The GitOps env vars in `.env` are **all optional** — leave them blank and the controllers still install cleanly; the app-of-apps root and private-repo creds are skipped until you set them. Once you have a manifest repo, set `ARGOCD_ROOT_REPO_URL` (and a PAT in `ARGOCD_GIT_TOKEN` for private repos) and run `make gitops` to point ArgoCD at it. The ArgoCD UI is at `http://argocd.lan` (`admin` / `ARGOCD_ADMIN_PASS`). Day-2 GitOps ops — sealing secrets, adding repos, backing up the sealing key — are in [docs/runbook.md](docs/runbook.md#gitops-argocd); env-var details in [docs/envsetup.md §8](docs/envsetup.md#8-argocd--sealed-secrets-gitops--all-optional).

## Layout

| Path | Purpose |
|---|---|
| [opentofu/](opentofu/) | Proxmox VM provisioning |
| [ansible/](ansible/) | RKE2 install + cluster config |
| [addons/](addons/) | Helm values + manifests for MetalLB, Longhorn, ArgoCD, Sealed Secrets |
| [docs/](docs/) | Architecture, runbook, troubleshooting |
| [PLAN.md](PLAN.md) | Full design document |
