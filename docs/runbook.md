# Runbook

Day-2 operations.

## Add a worker node

1. Append a new entry to `workers` in `opentofu/variables.tf` (or the corresponding tfvars), picking an unused VMID and IP.
2. `make apply` — Tofu provisions the VM and regenerates the inventory.
3. `make configure` — Ansible re-runs idempotently and only the new host gets touched by the `rke2_agent` and `longhorn_prereqs` roles.
4. `kubectl get nodes` — confirm the new node is Ready and `longhorn=true` labeled.

## Add a control-plane node

Same as above but extend `control_plane`. Note: the play has `serial: 1` for join servers, so they come up one at a time. `tls-san` in the rendered config will already include the new node's IP because the template iterates `groups['rke2_servers']`.

## Rotate the RKE2 cluster token

The token is shared by all nodes and any future joiners. To rotate:

1. Generate a new value: `openssl rand -hex 32` and update `RKE2_TOKEN` in `.env`.
2. On every node, `sudo sed -i "s|^token:.*|token: <NEW>|" /etc/rancher/rke2/config.yaml`.
3. Restart RKE2: `sudo systemctl restart rke2-server` (CPs) then `sudo systemctl restart rke2-agent` (workers).
4. New token must be live on at least one server before agents restart.

Or just run `ansible-playbook -i inventory/hosts.ini site.yml --tags rke2-server,rke2-agent` after updating `.env` — the templates re-render and Ansible restarts the services.

## Upgrade RKE2

Pin a new version in `ansible/inventory/group_vars/all.yml`:

```yaml
rke2_version: "v1.30.5+rke2r1"
```

Then upgrade one node at a time:

```sh
ansible-playbook -i inventory/hosts.ini site.yml --limit cp1 --tags rke2-server
# verify cluster healthy, then cp2, cp3, w1, w2, w3
```

RKE2's install script handles binary swaps; the systemd unit picks up the new version on restart.

## Replace a failed node

If a VM dies but the Proxmox host is fine:

1. `tofu taint module.worker[\"w2\"].proxmox_virtual_environment_vm.this`
2. `make apply` — Tofu rebuilds just that VM, cloud-init restores its IP, inventory unchanged.
3. `kubectl delete node w2`
4. `ansible-playbook -i inventory/hosts.ini site.yml --limit w2`
5. Longhorn replicas re-converge automatically.

If a Proxmox host dies, you lose one CP and one worker. The remaining 2 CPs keep etcd quorum and the cluster stays up. Longhorn (3 replicas) stays available. Bring the host back, then `tofu apply` to recreate its VMs.

## Backup / state

- **OpenTofu state** lives in `opentofu/terraform.tfstate`. Back this up — losing it means losing the link between the codebase and the deployed VMs.
- **etcd** snapshots are taken by RKE2 every 12 hours at `/var/lib/rancher/rke2/server/db/snapshots/` on each CP. Rsync these off-cluster for DR.
- **Longhorn** can back up to S3/NFS via the UI or `BackupTarget` CRD.

## Host-level NIC tuning

`make bootstrap-pve` installs the `stru-kube-nic-offload.service` systemd oneshot on every PVE host (via the `pve_nic_offload` role) to permanently disable Generic Segmentation Offload and TCP Segmentation Offload on physical NICs matching `en* eth* nic*`. This is a stability fix for NIC drivers (Realtek r8168/r8169, some Intel chipsets) that drop packets under load with hardware offload on.

If a PVE host is reinstalled or the service is otherwise lost, just re-run `make bootstrap-pve` — the role is idempotent. To target only the NIC tuning (skipping the user/role/snippets setup):

```sh
cd ansible && ansible-playbook -i inventory/pve-hosts.ini bootstrap-pve.yml --tags pve-nic-offload
```

To verify the unit is installed and last ran cleanly:

```sh
ssh root@<pve-host> 'systemctl status stru-kube-nic-offload.service'
# Active: active (exited) since <boot time>
```

To re-apply without rebooting (the ExecStart is idempotent):

```sh
ssh root@<pve-host> 'systemctl restart stru-kube-nic-offload.service'
```

To verify the actual NIC state:

```sh
ssh root@<pve-host> 'ethtool -k nic0 | grep -E "(generic|tcp)-segmentation-offload"'
# both should report "off"
```

## Migrate secrets to sops-age

When this grows beyond one operator:

1. `brew install sops age` and generate `age-keygen -o ~/.config/sops/age/keys.txt`.
2. Add `.sops.yaml` to the repo root listing your public age key.
3. Replace `.env` with `secrets.enc.env` (sops-encrypted), update Makefile to `sops exec-env secrets.enc.env "set -a; ..."`.
4. Commit `secrets.enc.env` (encrypted) and `.sops.yaml`; gitignore the unencrypted file.

## GitOps (ArgoCD)

ArgoCD + Sealed Secrets are deployed by `make addons` (or `make gitops` to (re)run just the GitOps
layer). All ArgoCD inputs are optional `.env` vars — blank ones make the matching task skip, so the
controller installs cleanly before you've created any GitOps repo.

### Log into the ArgoCD UI

Two ways in, both plain HTTP (no TLS until cert-manager lands):

- **By IP:** `http://10.74.2.220` — argocd-server's pinned MetalLB LoadBalancer IP. No DNS or
  Host header needed; works from any device that can route to `10.74.2.0/24`. Confirm it's up with
  `kubectl -n argocd get svc argocd-server` (EXTERNAL-IP should read `10.74.2.220`).
- **By name:** `http://argocd.lan` — the nginx ingress (LAN DNS → any node's hostPort 80; add a
  hosts entry if your LAN resolver doesn't know `argocd.lan`).

User is `admin`. The password is whatever you set in `ARGOCD_ADMIN_PASS`. If you left it blank, read
the chart's random initial password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### Point ArgoCD at your GitOps repo (app-of-apps root)

1. Set `ARGOCD_ROOT_REPO_URL` (and `_PATH`, default `apps`; `_REVISION`, default `main`) in `.env`.
2. `make gitops` — the `root` Application is applied and starts syncing.
3. `kubectl -n argocd get applications` — `root` should go Synced/Healthy.

Your GitOps repo's `apps/` dir holds child `Application` manifests, one per app — each pointing at
its own repo/path. This is the app-of-apps pattern; stru-kube only bootstraps `root`.

### Add an app / a new repo (public or private)

- **Public repo:** add an `Application` to the root repo's `apps/` dir. No credentials needed.
- **Private repo:** make sure the repo URL is under `ARGOCD_GIT_URL_PREFIX` and `ARGOCD_GIT_TOKEN`
  is a valid PAT in `.env`, then `make gitops` (creates/updates the org-wide `repo-creds` Secret).
  Now add the `Application`. For a one-off private repo *outside* the org prefix, create a
  per-repo `repository`-typed Secret instead (same fields, label
  `argocd.argoproj.io/secret-type: repository`, `url` = the exact repo URL).

### Rotate the ArgoCD admin password

Update `ARGOCD_ADMIN_PASS` in `.env`, then `make gitops` (or
`ansible-playbook -i inventory/hosts.ini addons.yml --tags argocd`). The play re-bcrypts it and
bumps `admin.passwordMtime` in `argocd-secret`, which is what forces ArgoCD to reload it.

## Sealed Secrets

Encrypt secrets so they can live in Git. The controller runs in `kube-system` named
`sealed-secrets-controller` (matching `kubeseal`'s defaults, so no flags needed).

### Seal a secret

```sh
brew install kubeseal     # macOS; or download from the sealed-secrets releases
# Build a normal Secret locally, pipe through kubeseal, commit the SealedSecret:
kubectl create secret generic my-app-creds \
  --namespace my-app --from-literal=token=s3cr3t \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > my-app-creds.sealed.yaml
# Commit my-app-creds.sealed.yaml to your GitOps repo — ArgoCD applies it, the
# controller decrypts it into a real Secret in-cluster.
```

A `SealedSecret` is, by default (`strict` scope), bound to its **namespace + name** — you can't
rename or move it without re-sealing.

### Back up the Sealed Secrets sealing key

The controller auto-generates an RSA **sealing key** on first start, stored in `kube-system`. It is
the **root of trust** for every `SealedSecret` you've committed — if the cluster is rebuilt and this
key is lost, every committed SealedSecret becomes undecryptable and must be re-sealed. Back it up
off-cluster, encrypted, and **never commit it**:

```sh
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o yaml > sealed-secrets-key.backup.yaml    # store OFFLINE / encrypted
```

Restore into a fresh cluster *before* the controller generates a new key (or `kubectl apply` it then
restart the controller so it adopts the restored key):

```sh
kubectl apply -f sealed-secrets-key.backup.yaml
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
```

## Reset

Three tiers, smallest to largest:

```sh
make reset                       # uninstall RKE2, keep the VMs (most common)
make clean                       # tofu destroy: destroys VMs + templates, keeps PVE config
make wipeclean CONFIRM=yes       # destroys VMs AND undoes `bootstrap-pve`: removes the
                                 #   terraform@pve user/token, TerraformProv role,
                                 #   reverts Snippets on local storage, deletes the cloud
                                 #   image and leftover snippet files. Use to hand the
                                 #   PVE cluster off, or when starting completely over.
```

`make wipeclean` runs a reachability preflight ([scripts/wipeclean-preflight.sh](../scripts/wipeclean-preflight.sh)) before any destructive step — every PVE host in `pve-hosts.ini` must be reachable via SSH, and the Proxmox API endpoint is probed. SSH unreachability is a hard fail (the play needs it); a dead API is a warning only (the Ansible play handles VM cleanup via `pvesh` as a backstop if `tofu destroy` can't).

After `make wipeclean`, the next deploy must start from `make bootstrap-pve`.
