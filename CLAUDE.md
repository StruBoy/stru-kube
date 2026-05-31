# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a 6-VM RKE2 Kubernetes cluster on a 3-node Proxmox VE cluster. **OpenTofu provisions VMs; Ansible configures them.** There is no application code — only declarative infra (HCL, YAML, Jinja templates). The cluster is real and running; this repo is the source of truth for rebuilding it.

Authoritative design doc: [PLAN.md](PLAN.md). Architecture diagrams + IP map: [docs/architecture.md](docs/architecture.md). Day-2 ops: [docs/runbook.md](docs/runbook.md). Failure modes already seen: [docs/troubleshooting.md](docs/troubleshooting.md). Onboarding / `.env` walkthrough: [docs/envsetup.md](docs/envsetup.md).

## Commands

Everything runs through the Makefile, which auto-sources `.env`. Running `tofu` or `ansible-playbook` directly without sourcing `.env` first will silently render empty `RKE2_TOKEN` into configs and break the cluster — `make preflight` (a dep of `plan`/`configure`) catches this.

```sh
make preflight       # toolchain + env + ssh-agent + Proxmox API reachability
make bootstrap-pve   # one-time PVE setup: TerraformProv role, terraform@pve user, Snippets,
                     #   `var.pve_hosts` ↔ live-cluster node-name validation, and a systemd
                     #   oneshot (stru-kube-nic-offload.service) that disables GSO/TSO on
                     #   physical NICs at every boot. Idempotent.
make plan            # tofu init + tofu plan -out=tfplan (in opentofu/) — runs preflight first
make apply           # tofu apply tfplan — provisions 6 VMs, writes ansible/inventory/hosts.ini
make configure       # ansible-galaxy + ansible-playbook site.yml — installs RKE2 — runs preflight first
make addons          # ansible-playbook addons.yml — MetalLB + Longhorn (ingress already bundled)
make verify          # kubeconfig URL check + VIP reachability + kubectl get nodes/pods/sc
make verify-full     # `verify`, then deploys a LoadBalancer service end-to-end and tears it down
make reset           # uninstall RKE2 cleanly, keep VMs
make clean           # tofu destroy — nukes the VMs
make wipeclean CONFIRM=yes
                     # DESTRUCTIVE: tofu destroy + undoes bootstrap-pve (removes TerraformProv,
                     #   terraform@pve, token, reverts Snippets, deletes cloud image + snippet files)
make fmt             # tofu fmt -recursive
make validate        # tofu validate + ansible-playbook --syntax-check site.yml addons.yml
```

Targeted re-runs (every role is tagged):

```sh
# Re-render and restart just the RKE2 servers:
cd ansible && ansible-playbook -i inventory/hosts.ini site.yml --tags rke2-server

# Limit to one host:
ansible-playbook -i inventory/hosts.ini site.yml --limit cp2 --tags rke2-server

# Just MetalLB or just Longhorn from the addons playbook:
ansible-playbook -i inventory/hosts.ini addons.yml --tags metallb
ansible-playbook -i inventory/hosts.ini addons.yml --tags longhorn
```

Tags in use: `common`, `longhorn-prereqs`, `kube-vip`, `rke2-server`, `rke2-bootstrap`, `rke2-agent`, `post-install`, `metallb`, `longhorn`, `pve-bootstrap`, `pve-nic-offload`, `pve-wipeclean`.

## Architecture you can't see from one file

**OpenTofu → Ansible contract is a generated file.** [opentofu/main.tf](opentofu/main.tf) writes `ansible/inventory/hosts.ini` via a `local_file` resource rendered from [opentofu/inventory.tftpl](opentofu/inventory.tftpl). That file is gitignored. There is no dynamic inventory plugin — if the IPs in `var.control_plane` / `var.workers` change, `make apply` regenerates the inventory; if you edit `hosts.ini` by hand it gets blown away on the next apply.

**Static IPs flow from variables, not from the guest agent.** `var.control_plane[].ip` populates both the cloud-init template (which sets the IP on boot) and the Ansible inventory (which Ansible uses to connect). This decouples us from `qemu-guest-agent` reporting IPs to `tofu refresh`. Don't change [opentofu/outputs.tf](opentofu/outputs.tf) to read `ipv4_addresses` — it will appear to work and then silently produce empty inventory entries on fresh clones.

**Bootstrap ordering is encoded across three places** and matters:
1. `site.yml` runs `kube_vip` role on `rke2_servers` **before** the RKE2 install play, so the static-pod manifest is already on disk at `/var/lib/rancher/rke2/server/manifests/kube-vip.yaml` when RKE2 first starts.
2. The first server (alias `rke2_first`, just cp1) gets a `config.yaml` with **no** `server:` line — the `rke2_server` role's Jinja template gates this with `{% if inventory_hostname != groups['rke2_first'][0] %}`. Removing that conditional makes cp1 try to join itself and hang forever.
3. After cp1 is up, `site.yml` has an `ansible.builtin.uri` task that polls `https://10.74.2.29:6443/livez` (the VIP) before the second play starts cp2/cp3 with `serial: 1`. This used to be a bare `wait_for host:port` which returned true as soon as the socket accepted — and cp2/cp3 still raced kube-vip. If you switch back to a port-check, the race comes back.

**kube-vip's `hostAliases` is load-bearing, not cosmetic.** kube-vip's in-cluster client resolves the API via the `kubernetes` service DNS name — before kube-vip claims the VIP, that name doesn't resolve, so kube-vip can't talk to the API to claim the VIP (chicken-and-egg). The static-pod manifest at `ansible/roles/kube_vip/templates/kube-vip.yaml.j2` maps `kubernetes → 127.0.0.1` via `hostAliases`. Setting `KUBERNETES_SERVICE_HOST` env vars does **not** work — kube-vip ignores them.

**Pod env-var changes don't restart the pod.** The `kube_vip` role has a handler that explicitly `kubectl delete pod kube-vip` when its manifest template changes, because kubelet/RKE2 won't recreate a static pod just from a file edit (env vars are immutable on running pods). If you edit the kube-vip template and the handler doesn't fire (e.g., `--check` mode), the change is on disk but not live.

**Ingress is `rke2-ingress-nginx`, not Traefik.** Traefik is K3s. The bundled nginx controller runs as a DaemonSet with hostPort 80/443 on every node — so clients hit any node IP directly, and MetalLB's `10.74.2.200-220` pool stays free for app `type: LoadBalancer` services. Longhorn UI ingress uses standard `networking.k8s.io/v1` with nginx basic-auth annotations (Secret key `auth`, **not** Traefik's `users`).

**Secrets are env-only.** `.env` (gitignored) is the only secret store. Ansible reads `RKE2_TOKEN` and `LONGHORN_UI_PASS` via `lookup('env', ...)`. The provider reads `PROXMOX_VE_*` via env vars. Migration path to sops-age is sketched in [docs/runbook.md](docs/runbook.md) — don't introduce a different secrets system without updating that.

**Host NIC offloads (GSO/TSO) are disabled by `bootstrap-pve` via a systemd oneshot service.** [ansible/roles/pve_nic_offload](ansible/roles/pve_nic_offload/) installs `/etc/systemd/system/stru-kube-nic-offload.service` (a `Type=oneshot RemainAfterExit=yes` unit) that runs `ethtool -K <iface> gso off tso off` on every NIC matching `en* eth* nic*` after `network.target`. The role `systemctl enable --now`'s it so the offload disable takes effect immediately and re-fires automatically at every boot. Reason: during a deploy, stru-prox0 fell off the network under Longhorn's container-pull load — the signature of a NIC driver wedging with hardware segmentation offload enabled (common Realtek/Intel bug). **Don't replace this with a systemd `.link` file** — an earlier version of this role did exactly that, and the file shadowed the host's boot-time `eno2 → nic0` rename rule (per `man systemd.link`, only the first matching `.link` per device is applied), leaving `vmbr0` with no slave on reboot. The service-based approach has no interaction with `.link` matching. Don't remove the role without confirming the underlying hardware is offload-stable.

## Things that will break the build if you "fix" them

These are tarpits — each one represents a debugged incident, captured in [docs/troubleshooting.md](docs/troubleshooting.md). Most now have automated prevention (named after each); skim the troubleshooting doc before changing the corresponding file.

- **`var.pve_hosts` map keys must match `cat /etc/pve/.members`** on the PVE cluster (`stru-prox0/1/2` here, not `pve1/2/3`). The bpg/proxmox provider passes those keys verbatim to the API as `node_name`. *Caught at plan time by [opentofu/preflight.tf](opentofu/preflight.tf) and during `make bootstrap-pve`.*
- **The provider only honors `ssh-agent`** — it ignores `~/.ssh/config`. `tofu apply` will fail with "unable to authenticate" if the agent is empty. *Caught by `make preflight`.*
- **`TerraformProv` role needs `Datastore.Allocate`** (separate from `Datastore.AllocateSpace`) for snippet uploads, and **must not** include `VM.Monitor` (removed in PVE 8 — use `VM.Console`). *The canonical privilege list lives in [ansible/roles/pve_bootstrap/defaults/main.yml](ansible/roles/pve_bootstrap/defaults/main.yml); `make bootstrap-pve` resyncs on every run.*
- **Don't rename the `proxmox_virtual_environment_vm` resources → `proxmox_vm`** in the OpenTofu files. For the VM/container resources the shorter alias is a genuinely different (stub) schema — verified on bpg 0.107, `proxmox_vm` exposes **zero** nested blocks while `proxmox_virtual_environment_vm` has all 24 (`disk`/`network_device`/`serial_device`/…). Deprecation warnings on those long names are harmless until bpg v1.0. **Exception:** `proxmox_download_file` (in [modules/template/main.tf](opentofu/modules/template/main.tf)) *is* a true rename — its short alias has a byte-identical schema, so we renamed it and added a `moved` block to migrate state. Verify schema parity (`tofu providers schema -json`) before assuming any other rename is safe.
- **Don't edit `opentofu/cloud-init.tftpl` after first apply unless you want VMs rebuilt.** The provider treats the `initialization` block as replacement-triggering. OS-level changes belong in Ansible.
- **`ansible.cfg` uses `stdout_callback=default` + `result_format=yaml`** — the old `community.general.yaml` callback was removed in v12 and won't load.
- **`ansible_python_interpreter=/usr/bin/python3` is pinned** in `group_vars/all.yml` for Ubuntu 24.04. Don't remove it.
- **The kubeconfig at `kubeconfig/rke2.yaml` has the VIP rewritten in** by the `post_install` role. RKE2 writes `127.0.0.1` natively. *`make verify` greps for `127.0.0.1` and fails if the rewrite didn't happen.*
- **`RKE2_TOKEN` must be non-empty in the env** when `site.yml` runs — `lookup('env', 'RKE2_TOKEN')` happens at template-render time, and a partial-environment invocation will silently render `token:` empty. *`make preflight` and a `localhost` `pre_tasks` assert in `site.yml` both catch this.*
- **etcd is intolerant of clock skew across CPs.** *`common` role asserts `chronyc tracking` reports `Leap status: Normal` before RKE2 ever installs.*
- **kube-vip's `hostAliases` and the manifest-change handler are load-bearing**, not cosmetic — see the architecture section above.

## Verification (after any cluster-touching change)

`make verify` greps the kubeconfig for the VIP URL, curls `https://VIP:6443/version`, then runs `kubectl get nodes/pods/sc` — so it catches the "kubeconfig still has 127.0.0.1" and "workstation can't reach the VIP" cases that used to silently time out. `make verify-full` adds an end-to-end MetalLB smoke test (creates a LoadBalancer service, waits for EXTERNAL-IP, curls it, tears down). The full manual end-to-end checklist (VIP failover on cp1 reboot, Longhorn PVC binding, etc.) is at the bottom of [PLAN.md](PLAN.md#verification-end-to-end).

## Conventions

- **OpenTofu**, not Terraform (`tofu` CLI). Provider is `bpg/proxmox ~> 0.66`; chart and image versions are pinned in `ansible/inventory/group_vars/all.yml`.
- **Idempotency over imperative scripts.** Every role re-runs cleanly: install commands use `creates:` guards, configs are `template`-rendered, services are `state: started, enabled: true`. If you add a task that isn't safely re-runnable, it's a bug.
- **The `.env` file is the seam.** If a new value is needed at runtime, it goes in `.env.example` and gets read via `lookup('env', ...)` (Ansible) or env-var-driven provider config (OpenTofu). No baked-in defaults for secrets.
- **One PR per concern.** When fixing the cluster, the convention in recent commits has been to bundle docs + code changes that solve a single real-world problem into one commit (see `5d9a482` "Reconcile docs + bug fixes from real-world cluster build"), not to split docs and code into separate commits.
