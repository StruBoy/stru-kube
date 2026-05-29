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

`make bootstrap-pve` writes `/etc/systemd/network/10-stru-kube-no-offload.link` on every PVE host (via the `pve_nic_offload` role) to permanently disable Generic Segmentation Offload and TCP Segmentation Offload on physical NICs matching `en* eth* nic*`. This is a stability fix for NIC drivers (Realtek r8168/r8169, some Intel chipsets) that drop packets under load with hardware offload on.

If a PVE host is reinstalled or the `.link` file is otherwise lost, just re-run `make bootstrap-pve` — the role is idempotent. To target only the NIC tuning (skipping the user/role/snippets setup):

```sh
cd ansible && ansible-playbook -i inventory/pve-hosts.ini bootstrap-pve.yml --tags pve-nic-offload
```

To verify after a reboot:

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
