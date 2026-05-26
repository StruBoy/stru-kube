# Troubleshooting

Common failure modes hit during the build, in roughly the order they appear.

## `tofu apply` errors: HTTP 500 "hostname lookup 'pveX' failed"

**Symptom:**
```
Error initiating file download
... received an HTTP 500 response - Reason: hostname lookup 'pve1' failed
```

**Cause:** `var.pve_hosts` map keys don't match the actual PVE node names. The API takes those keys verbatim and tries to look up the host on the cluster side.

**Fix:** Discover the real names and update [opentofu/variables.tf](../opentofu/variables.tf) (or `terraform.tfvars`):

```sh
ssh root@<any-pve-ip> 'cat /etc/pve/.members'
```

The `nodelist` keys are the names. Then update `pve_hosts` and the `host = "..."` fields on every entry in `control_plane` / `workers`. See [envsetup.md §2.7](envsetup.md#27-discover-your-pve-node-names-critical--go-to-terraformtfvars).

## `tofu apply` errors: SSH "unable to authenticate"

**Symptom:**
```
creating custom disk: unable to authenticate user "root" over SSH to "10.74.2.20:22"
... attempted methods [none password], no supported methods remain
... (NOTE: configurations in ~/.ssh/config are not considered by the provider)
```

**Cause:** bpg/proxmox **only** reads keys from `ssh-agent`. `~/.ssh/config`, `~/.ssh/id_*`, even `ssh-copy-id` setups don't matter to it.

**Fix:**
```sh
ssh-add -L                                        # confirm agent is empty
ssh-add ~/.ssh/id_ed25519                         # Linux
ssh-add --apple-use-keychain ~/.ssh/id_ed25519    # macOS, persists
```

Make sure that key is also authorized for `root@<pve-ip>` (`ssh-copy-id`).

## `tofu apply` errors: HTTP 403 "Permission check failed (/storage/local, Datastore.Allocate)"

**Symptom:** snippet upload fails with the above.

**Cause:** `TerraformProv` role is missing `Datastore.Allocate` (separate from `Datastore.AllocateSpace`).

**Fix** (on any PVE node):
```sh
pveum role modify TerraformProv -privs "VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.PowerMgmt,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,Pool.Allocate,Sys.Audit,Sys.Console,Sys.Modify,SDN.Use"
```

Note: `pveum role modify` takes **commas**, `pveum role add` takes **spaces**.

## `pveum role add` rejects `VM.Monitor`

**Symptom:** `400 Parameter verification failed. privs: invalid format - invalid privilege 'VM.Monitor'`

**Cause:** `VM.Monitor` was removed in PVE 8.

**Fix:** drop it, add `VM.Console` instead.

## Deprecation warning: "Use 'proxmox_vm' instead"

**Symptom:** `tofu plan` shows warnings like:
```
Use "proxmox_download_file" instead. This resource / data source will be removed in v1.0.
```

**Cause:** bpg/proxmox is renaming resources ahead of v1.0.

**Important:** the new names (`proxmox_vm`, `proxmox_download_file`, `proxmox_file`) are a **different schema**, not a rename. Trying to `sed s/proxmox_virtual_environment_/proxmox_/g` will break things — the new VM resource doesn't accept `disk`, `network_device`, `serial_device`, etc. as nested blocks.

**Fix:** ignore the warning until v1.0 actually ships. The old names work fine.

## Cloud-init didn't apply / static IP missing

**Symptom:** `tofu apply` succeeds but `ansible -m ping` fails; VM has no IP or a DHCP IP, not the static one from variables.

**Cause:** `user_data_file_id` requires `content_type = "snippets"` on the storage pool. If snippets aren't enabled on `local`, the snippet upload silently fails and PVE uses its default cloud-init.

**Fix:** Datacenter → Storage → local → Content → check **Snippets** → Save. Then `tofu taint module.control_plane["cp1"].proxmox_virtual_environment_vm.this` and re-apply.

## `output "node_ips"` is empty

**Symptom:** Inventory file has blank `ansible_host=` values.

**Cause:** We use static IPs from variables (not agent-reported), so this should not happen with the current code. If it does, you've probably changed `outputs.tf` to read `ipv4_addresses` — that needs `qemu-guest-agent` running in the clones. `tofu refresh` after ~60s usually resolves it.

## `ansible-playbook` errors: "The 'community.general.yaml' callback plugin has been removed"

**Symptom:**
```
[ERROR]: The 'community.general.yaml' callback plugin has been removed.
The plugin has been superseded by the option `result_format=yaml` in callback
plugin ansible.builtin.default ...
```

**Cause:** That callback was deleted in `community.general` v12.

**Fix:** in [ansible/ansible.cfg](../ansible/ansible.cfg) replace:
```ini
stdout_callback = yaml
```
with:
```ini
stdout_callback = default
result_format = yaml
```
Already applied in this repo.

## `rke2-server.service` fails: "token is required to join a cluster"

**Symptom:** `systemctl status rke2-server` on a CP shows it fail-loops with the above; `/etc/rancher/rke2/config.yaml` has an empty `token:` line.

**Cause:** `RKE2_TOKEN` wasn't in the env when Ansible rendered the config — `lookup('env', 'RKE2_TOKEN')` returned an empty string.

**Fix:** **always run via `make`** (which sources `.env` automatically). If you must run `ansible-playbook` directly:

```sh
set -a; source .env; set +a
ansible-playbook -i inventory/hosts.ini site.yml
```

Then re-render and restart on the affected hosts:

```sh
ansible-playbook -i inventory/hosts.ini site.yml --tags rke2-server
```

## RKE2 bootstrap server hangs

**Symptom:** `systemctl status rke2-server` on cp1 shows it can't connect.

**Causes:**
- The first server's `config.yaml` accidentally has a `server:` line. Verify the Jinja template's `{% if inventory_hostname != groups['rke2_first'][0] %}` guard is firing — re-render with `ansible-playbook ... --tags rke2-server --check --diff`.
- Time skew across nodes (etcd is picky). Confirm `chronyc tracking` reports a healthy peer on each node.

## kube-vip can't claim the VIP — "lookup kubernetes on 10.74.2.1:53: no such host"

**Symptom:** `kubectl -n kube-system logs kube-vip` floods with:
```
error retrieving resource lock kube-system/plndr-cp-lock: Get "https://kubernetes:6443/...":
  dial tcp: lookup kubernetes on 10.74.2.1:53: no such host
```
The VIP at `10.74.2.29` is never assigned.

**Cause:** kube-vip uses in-cluster client config which resolves the API server via the `kubernetes` service DNS name. Before kube-vip claims the VIP, cluster DNS isn't reachable (and the LAN DNS resolver doesn't know `kubernetes`). Setting `KUBERNETES_SERVICE_HOST` env var does NOT help — kube-vip ignores it.

**Fix:** `hostAliases` mapping `kubernetes → 127.0.0.1` in the static-pod manifest. The role at [ansible/roles/kube_vip/templates/kube-vip.yaml.j2](../ansible/roles/kube_vip/templates/kube-vip.yaml.j2) includes this.

If the pod is already running with an old manifest (kubelet/RKE2 won't recreate it just because the YAML on disk changed — Pod env vars are immutable), delete it:

```sh
ssh ubuntu@<cp-ip> 'sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n kube-system delete pod kube-vip'
```

The role's handler does this automatically on subsequent manifest changes.

## CP2/CP3 fail to join with "connection refused" on :9345

**Symptom:** Second/third server join fails reaching the API VIP.

**Cause:** kube-vip hasn't claimed the VIP yet. The `site.yml` wait_for task on `localhost` is meant to gate this. If it returned before the VIP was actually answering on 6443, kube-vip's pod might still be ContainerCreating.

**Fix:**
```sh
ssh ubuntu@10.74.2.30 sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml -n kube-system get pod kube-vip
```
Wait for it to be Running, then re-run the join play:
```sh
ansible-playbook -i inventory/hosts.ini site.yml --tags rke2-server --limit 'rke2_servers:!rke2_first'
```

## MetalLB service stuck "Pending"

**Symptom:** `kubectl get svc` shows EXTERNAL-IP as `<pending>` forever.

**Causes:**
- `IPAddressPool` or `L2Advertisement` not applied. `kubectl -n metallb-system get ipaddresspool,l2advertisement`.
- Pool exhausted (only 21 IPs in the default range).
- Speaker pods can't reach the LAN. `kubectl -n metallb-system logs daemonset/metallb-speaker | tail`.

## Longhorn volumes stuck "Attaching"

**Symptom:** PVC bound but pod can't attach.

**Causes:**
- `open-iscsi` not running on the worker. `ssh ubuntu@<worker> sudo systemctl status iscsid`.
- Multipath grabbing Longhorn devices. `cat /etc/multipath/conf.d/longhorn.conf` should have the `^sd[a-z0-9]+` blacklist.
- Worker missing `longhorn=true` label. `kubectl get nodes --show-labels | grep longhorn`.

## `addons.yml` errors: "Failed to find exact match for traefik.io/v1alpha1.Middleware"

**Symptom:**
```
[ERROR]: Task failed: Module failed: Failed to find exact match for
traefik.io/v1alpha1.Middleware by [kind, name, singularName, shortNames]
```

**Cause:** RKE2 ships **`rke2-ingress-nginx`**, not Traefik (Traefik is K3s). Older versions of this repo applied a Traefik `IngressRoute` + `Middleware`, but no Traefik CRDs exist in the cluster.

**Fix:** the current [addons/longhorn/ingress.yaml](../addons/longhorn/ingress.yaml) uses a standard `networking.k8s.io/v1` Ingress with nginx basic-auth annotations. If you're seeing this error, you're on stale code — pull the latest. The legacy [addons/traefik/HelmChartConfig.yaml](../addons/traefik/HelmChartConfig.yaml) is kept as a reference but no longer applied.

## API VIP not reachable from workstation

**Symptom:** `kubectl get nodes` times out, but SSH to nodes works.

**Cause:** kube-vip uses gratuitous ARP. Some switches/routers filter unsolicited ARPs. Verify with `arping 10.74.2.29` from your workstation. If filtered, switch kube-vip to BGP mode or use one of the CP IPs in your kubeconfig directly.

## Kubeconfig fetched but kubectl shows "connection refused"

**Cause:** kubeconfig still has `127.0.0.1`. The `post_install` role should rewrite it; if you ran a partial play, run:

```sh
ansible-playbook -i inventory/hosts.ini site.yml --tags post-install
```

Or manually:
```sh
sed -i.bak "s|https://127\.0\.0\.1:6443|https://10.74.2.29:6443|" kubeconfig/rke2.yaml
```

## VM rebuilds on every `tofu apply`

**Cause:** Editing `cloud-init.tftpl` after creation. bpg treats `initialization` block changes as replacement-triggering. Either accept the rebuild (VMs come back with the same IPs via cloud-init) or use Ansible for the change instead.

## "iothread" or "discard" complaints on `tofu apply`

**Cause:** Older PVE versions or non-LVM-thin storage. Edit [opentofu/modules/vm/main.tf](../opentofu/modules/vm/main.tf) and remove `iothread = true` / `discard = "on"` from the disk blocks.

## Trailing-slash error: "no such file '/json/version'"

**Symptom:**
```
curl -k -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" $PROXMOX_VE_ENDPOINT/api2/json/version
no such file '/json/version'
```

**Cause:** `PROXMOX_VE_ENDPOINT` ends in `/`. Concatenating with `/api2/...` produces `//api2/...`, which PVE mis-parses.

**Fix:** strip the trailing slash:
```sh
curl -k -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" "${PROXMOX_VE_ENDPOINT%/}/api2/json/version"
```
