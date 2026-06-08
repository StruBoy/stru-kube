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
   ┌────┴───────┐                     ┌────┴───────┐                     ┌────┴───────┐
   │stru-prox0  │ 10.74.2.20          │stru-prox1  │ 10.74.2.21          │stru-prox2  │ 10.74.2.22
   └────┬───────┘                     └────┬───────┘                     └────┬───────┘
        │                                  │                                  │
   ┌────┴──────┐                      ┌────┴──────┐                      ┌────┴──────┐
   │ cp1 .30   │ control-plane        │ cp2 .31   │ control-plane        │ cp3 .32   │ control-plane
   │ w1  .33   │ worker (+100G LH)    │ w2  .34   │ worker (+100G LH)    │ w3  .35   │ worker (+100G LH)
   └───────────┘                      └───────────┘                      └───────────┘

                        API VIP 10.74.2.29 (kube-vip, floats across cp1-3)
                        MetalLB LB pool: 10.74.2.200 – 10.74.2.220
                        Ingress: rke2-ingress-nginx DaemonSet, hostPort 80/443 on every node
```

## IP map

| Role             | Name | Host         | VMID | IP            | Notes                     |
|------------------|------|--------------|------|---------------|---------------------------|
| control-plane    | cp1  | stru-prox0   | 110  | 10.74.2.30    | rke2-server               |
| control-plane    | cp2  | stru-prox1   | 120  | 10.74.2.31    | rke2-server               |
| control-plane    | cp3  | stru-prox2   | 130  | 10.74.2.32    | rke2-server               |
| worker           | w1   | stru-prox0   | 111  | 10.74.2.33    | rke2-agent, longhorn=true |
| worker           | w2   | stru-prox1   | 121  | 10.74.2.34    | rke2-agent, longhorn=true |
| worker           | w3   | stru-prox2   | 131  | 10.74.2.35    | rke2-agent, longhorn=true |
| K8s API VIP      | —    | —            | —    | 10.74.2.29    | kube-vip ARP              |
| MetalLB pool     | —    | —            | —    | 10.74.2.200–220 | LoadBalancer services    |

Pod CIDR `10.42.0.0/16`, Service CIDR `10.43.0.0/16`, cluster DNS suffix `cluster.local`.

> Node names are whatever PVE knows them as (see `pvesh get /nodes` or `/etc/pve/.members`). If your cluster uses different names, override `pve_hosts` in a `terraform.tfvars` file.

## Component stack

| Layer              | Choice                                                |
|--------------------|-------------------------------------------------------|
| Hypervisor         | Proxmox VE 8/9                                        |
| Guest OS           | Ubuntu 24.04 (cloud image)                            |
| Provisioning       | OpenTofu + `bpg/proxmox`                              |
| Configuration      | Ansible (community.general, ansible.posix, kubernetes.core) |
| Kubernetes         | RKE2 (CNCF-certified)                                 |
| CNI                | Canal (RKE2 default)                                  |
| API HA             | kube-vip (ARP, static pod, `hostAliases: kubernetes → 127.0.0.1`) |
| LoadBalancer       | MetalLB (L2 mode)                                     |
| Ingress            | `rke2-ingress-nginx` (RKE2-bundled, DaemonSet hostPort 80/443) |
| Storage            | Longhorn (3 replicas, default StorageClass)           |
| GitOps             | ArgoCD (`argo-cd` chart, server insecure behind nginx) |
| Secrets-in-Git     | Bitnami Sealed Secrets (controller in `kube-system`)  |

## GitOps & secrets model

ArgoCD turns the cluster into a GitOps control plane: workloads are reconciled from Git, not
`kubectl apply`-ed by hand. **stru-kube is the bootstrap layer only** — it installs ArgoCD +
Sealed Secrets and an app-of-apps `root` Application; the actual app manifests live in **separate**
GitOps repos (some public, some private). Day-2 app changes happen by editing those repos.

**Two secret tiers:**
- **Bootstrap secrets** — ArgoCD's own admin password and the private-repo PAT. These must exist
  *before* ArgoCD can authenticate a login or clone a private repo (chicken-and-egg), so they live
  in `.env` and are injected by Ansible, exactly like `RKE2_TOKEN`/`LONGHORN_UI_PASS`.
- **App secrets** — everything else. Committed to the GitOps repos as encrypted `SealedSecret` CRs
  and decrypted in-cluster by the sealed-secrets controller. Never plaintext in Git.

> **Roadmap (deferred, not in the GitOps foundation pass):** cert-manager (real TLS on
> `argocd.lan`/`longhorn.lan` + a gRPC/SSL-passthrough ingress for the `argocd` CLI),
> kube-prometheus-stack (Prometheus/Grafana/Alertmanager, deployed *via* ArgoCD), and Dex/SSO for
> ArgoCD. See [PLAN.md](../PLAN.md) for the component roadmap.

## Decisions log

- **bpg/proxmox over Telmate/proxmox.** Telmate has stalled; bpg has native cloud-init, image download, and template modeling.
- **`proxmox_virtual_environment_*` resource names retained.** bpg has shorter aliases (`proxmox_vm`, `proxmox_download_file`, `proxmox_file`) marked for v1.0 — but those are a *different schema*, not just a rename. The old names still work and the deprecation is a harmless warning.
- **kube-vip over HAProxy+keepalived.** One static-pod manifest beats two extra daemons + a config file Ansible has to babysit. The `hostAliases` workaround is the only setup quirk.
- **rke2-ingress-nginx, not Traefik.** RKE2 ships nginx; Traefik is K3s. Swapping would mean disabling nginx + managing the Traefik chart + CRDs. Nginx as a hostPort DaemonSet means clients hit any node:80/443 directly — MetalLB stays available for app LB services.
- **Disable RKE2's ServiceLB.** MetalLB owns `type: LoadBalancer` IPs.
- **Canal over Cilium.** Cilium is materially better for NetworkPolicy at scale, eBPF observability, and BGP — none of which we need in a 6-node homelab. Canal is the default and lowest-friction choice.
- **Static Ansible inventory written by Tofu.** Dynamic Proxmox inventory adds runtime PVE dependency and duplicates credentials. A flat file is diffable and works offline.
- **Static IPs from cloud-init (not agent-reported).** `var.control_plane[].ip` / `var.workers[].ip` populate both cloud-init and the Ansible inventory deterministically. Removes any dependence on `qemu-guest-agent` returning addresses to `tofu refresh`.
- **`.env` sourced via the Makefile.** Running `ansible-playbook` directly without env vars makes `lookup('env','RKE2_TOKEN')` return empty; rendered configs lose the token. `make` targets source `.env` first, `make preflight` asserts the vars are non-empty, and `site.yml` has a `pre_tasks` assert as a final backstop.
- **PVE one-time setup is automated** via [ansible/bootstrap-pve.yml](../ansible/bootstrap-pve.yml). The `TerraformProv` role, `terraform@pve` user, Snippets-on-`local`, and the `pve_hosts` ↔ live-cluster validation are all idempotent — re-running `make bootstrap-pve` is safe and fixes drift. The matching teardown is `make wipeclean CONFIRM=yes`.
- **Plan-time validation in OpenTofu** via [opentofu/preflight.tf](../opentofu/preflight.tf). A `terraform_data` precondition cross-checks `var.pve_hosts` against the live cluster's node list at the start of every plan, turning a cryptic apply-time HTTP 500 into a clear plan-time diff.
- **Strong wait for kube-vip → API**. `site.yml` uses `ansible.builtin.uri` against `/livez`, not a bare port-open check — the join only proceeds when the API is actually serving requests, eliminating the cp2/cp3 race.
- **ArgoCD server runs insecure behind nginx.** `configs.params."server.insecure": true` + the ingress annotation `nginx.ingress.kubernetes.io/backend-protocol: "HTTP"` — nginx terminates the connection and proxies plain HTTP to argocd-server. This avoids ArgoCD's self-signed TLS double-termination (redirect loop / 502) and needs no cert until cert-manager lands. The two settings are load-bearing *together*.
- **App-of-apps with separate repos.** A single `root` Application (applied by Ansible, guarded so it's skipped until `ARGOCD_ROOT_REPO_URL` is set) points at a separate GitOps repo whose `apps/` dir holds child `Application`s. Keeps stru-kube as the bootstrap layer; app churn doesn't touch this repo.
- **Private-repo creds as an org-wide `repo-creds` template.** One Secret labeled `argocd.argoproj.io/secret-type: repo-creds` with a URL *prefix* (`https://github.com/StruBoy/`) lets a single PAT cover every private repo under the org; public repos match no prefix and clone anonymously. Built from `.env` by Ansible, never committed.
- **Sealed Secrets over SOPS/External-Secrets.** Encrypted `SealedSecret` CRs commit straight to Git with no decrypt sidecar in ArgoCD; the controller lives in `kube-system` named `sealed-secrets-controller` so `kubeseal` works flag-free. The controller's RSA sealing key is the root of trust — back it up (see [runbook](runbook.md#back-up-the-sealed-secrets-sealing-key)).
- **ArgoCD bootstrap secrets stay in `.env`.** Admin password + repo PAT are bootstrap secrets (needed before ArgoCD can pull anything), so they're Ansible/`.env`, not SealedSecrets. App secrets go through Sealed Secrets. See the two-tier model above.
