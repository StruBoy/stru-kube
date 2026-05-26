# Session Report — 2026-05-26: Build RKE2 cluster on Proxmox

End-to-end build of a 6-VM HA RKE2 Kubernetes cluster on an existing 3-node Proxmox VE cluster, from empty directory to verified workloads. Session covers scaffolding, real-world apply, and chasing down a series of integration issues.

## What was delivered

A working homelab Kubernetes cluster with:
- 6 VMs provisioned by OpenTofu (`bpg/proxmox`) — 3 control-plane + 3 workers, one of each per PVE host
- RKE2 installed and joined via Ansible (kube-vip API VIP at `10.74.2.29`)
- MetalLB LoadBalancer pool (`10.74.2.200-220`)
- Longhorn replicated storage as default `StorageClass`
- nginx ingress (RKE2-bundled) with basic-auth on Longhorn UI at `longhorn.lan`
- Full IaC repo (OpenTofu + Ansible + addons + docs) committed to a local `main`
- Verification: 6/6 nodes Ready, API VIP responding, MetalLB hands out IPs, Longhorn PVC bound in 4s, ingress 401 challenge working

## Timeline

1. **Planning** — Q&A with user (4 question batches) to pin K8s distro (RKE2), topology (3+3 HA), storage (Longhorn), LB/ingress (initially said Traefik), PVE hosts (10.74.2.20/21/22), sizing (CP 2/4G/40G, worker 4/8G/80G+100G), IP plan (10.74.2.0/24). Plan agent designed the architecture; plan file approved.

2. **Scaffolding** — 53 files across `opentofu/`, `ansible/`, `addons/`, `docs/`. YAML parsed clean, HCL braces balanced. Committed as `7fa1241`.

3. **Toolchain + secrets** — User installed `tofu/ansible/kubectl/helm` via Homebrew. Created `terraform@pve` user + `TerraformProv` role + API token on PVE. Generated `RKE2_TOKEN`. Sourced `.env`.

4. **Apply attempt 1** — failed with bpg provider warnings (`hashicorp/proxmox` lookup) → added `versions.tf` to child modules. Then real apply failed with HTTP 500 `hostname lookup 'pve1' failed`.

5. **Real PVE state discovered** — node names are `stru-prox0/1/2`, not `pve1/2/3`. Updated `var.pve_hosts` and CP/worker placement; added `dynamic "node"` SSH mapping in provider config.

6. **Apply attempt 2** — SSH auth failure (`attempted methods [none password]`) → bpg only reads from ssh-agent, ignores `~/.ssh/config`. Loaded key with `ssh-add --apple-use-keychain`. Then 403 on `Datastore.Allocate` — modified PVE role to add that privilege.

7. **Apply attempt 3** — 6 VMs provisioned cleanly in ~2 minutes. Inventory written.

8. **Configure attempt 1** — failed immediately: `community.general.yaml` callback was removed in v12. Switched `ansible.cfg` to `stdout_callback=default` + `result_format=yaml`.

9. **Configure attempt 2** — cp1 bootstrapped fine, but `Wait for kube-vip to claim 10.74.2.29:6443` timed out (300s). kube-vip pod was running but in a loop trying to resolve `kubernetes:6443` via LAN DNS.

10. **kube-vip fix** — tried setting `KUBERNETES_SERVICE_HOST=127.0.0.1` (ignored). Switched to `hostAliases: kubernetes → 127.0.0.1` in the static-pod manifest. Added a handler to delete the pod when the manifest changes (env vars are immutable on running pods). VIP claimed in 4s.

11. **Configure attempt 3** — ran ansible-playbook directly without sourcing `.env` first → `RKE2_TOKEN` lookup returned empty → cp2 failed to start with `token is required to join a cluster`. Re-sourced and re-ran. Full cluster joined; kubeconfig fetched.

12. **Addons attempt 1** — MetalLB + Longhorn installed cleanly. Last task failed: `Failed to find exact match for traefik.io/v1alpha1.Middleware`. Discovered RKE2 ships **`rke2-ingress-nginx`**, not Traefik (Traefik is K3s). My original plan conflated the two.

13. **Ingress fix** — rewrote `addons/longhorn/ingress.yaml` to use standard `networking.k8s.io/v1` Ingress with nginx basic-auth annotations; switched Secret key from `users` (Traefik) to `auth` (nginx); dropped the Traefik HelmChartConfig task from `addons.yml`. Re-ran cleanly.

14. **Verification** — 6/6 nodes Ready, API VIP responding, MetalLB hands out `10.74.2.200` to test LB, Longhorn PVC bound in 4s, nginx ingress returns 401 challenge for `longhorn.lan`. All checks passed except CP failover test (skipped — disruptive).

15. **Permissions** — wrote `.claude/settings.local.json` with 57 allow rules for the toolchain used; gitignored it. `tofu destroy`, `kubectl delete deployment/namespace`, `ssh-keygen`, `helm uninstall` still prompt.

16. **Doc reconciliation** — updated PLAN.md, README.md, docs/architecture.md, docs/envsetup.md, docs/troubleshooting.md, Makefile, and the unused Traefik file to reflect every issue hit. Makefile now auto-sources `.env`. troubleshooting.md grew from 9 to 18 entries.

## Issues hit, in order

1. `hashicorp/proxmox` provider lookup → child modules need their own `versions.tf` declaring `bpg/proxmox`
2. PVE node names mismatch (`pve1` vs actual `stru-prox0`) → API returns HTTP 500 with `hostname lookup failed`
3. bpg/proxmox SSH auth failure → only reads `ssh-agent`, not `~/.ssh/config`
4. Missing `Datastore.Allocate` privilege on TerraformProv role → 403 on snippet upload
5. `VM.Monitor` rejected in PVE 8 → use `VM.Console`
6. `proxmox_*` short resource names are a different schema, not a rename → kept `proxmox_virtual_environment_*` with deprecation warnings
7. `community.general.yaml` callback removed in v12 → `stdout_callback=default` + `result_format=yaml`
8. kube-vip `lookup kubernetes: no such host` → `hostAliases` workaround
9. kube-vip pod won't restart on manifest change → handler that deletes the pod
10. `ansible-playbook` directly (without `.env` sourced) → empty `RKE2_TOKEN` → join nodes fail
11. RKE2 ships nginx, not Traefik → rewrote Longhorn ingress as standard `Ingress`, switched basic-auth secret key from `users` to `auth`
12. Trailing slash on `PROXMOX_VE_ENDPOINT` + manual curl → `//api2/...` rejected

## State at session end

- 2 commits on `main` (`bb7ae64` initial plan, `7fa1241` scaffold)
- 19 files modified, 4 untracked since `7fa1241` (this session's bug fixes + docs reconciliation + new envsetup.md + this session report)
- No git remote configured
- `.claude/settings.local.json` in place with project-scoped allowlist
- Cluster running, kubeconfig at `kubeconfig/rke2.yaml`

## Recommended next steps

- Wire up a remote (GitHub/Gitea) and push
- Test CP failover (reboot cp1, confirm VIP migrates within ~10s)
- Set up etcd snapshot offsite copy (RKE2 already writes snapshots every 12h)
- Migrate `.env` to sops-age if scaling beyond one operator (path documented in [docs/runbook.md](../../docs/runbook.md))
- Pin `rke2_version` in `ansible/inventory/group_vars/all.yml` for reproducibility
