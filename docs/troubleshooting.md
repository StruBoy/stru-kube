# Troubleshooting

## Cloud-init didn't apply / static IP missing

**Symptom:** `tofu apply` succeeds but `ansible -m ping` fails; VM has no IP or a DHCP IP, not the static one from variables.

**Cause:** `bpg/proxmox` `user_data_file_id` requires `content_type = "snippets"` on the storage pool. If snippets aren't enabled on `local`, the snippet upload silently fails and PVE uses its default cloud-init.

**Fix:** Datacenter → Storage → local → Content → check **Snippets** → Save. Then `tofu taint module.control_plane["cp1"].proxmox_virtual_environment_vm.this` and re-apply.

## `output "node_ips"` is empty

**Symptom:** Inventory file has blank `ansible_host=` values.

**Cause:** qemu-guest-agent isn't running in the clones yet — bpg can't read IPs back. Note: we use the static IP from variables (not agent-reported) for the inventory, so this should not happen with the current configuration. If it does, `tofu refresh` after ~60s lets PVE catch up.

## RKE2 bootstrap server hangs

**Symptom:** `systemctl status rke2-server` on cp1 shows it can't connect.

**Causes:**
- The first server's `config.yaml` accidentally has a `server:` line. Verify the Jinja template's `{% if inventory_hostname != groups['rke2_first'][0] %}` guard is firing — re-render with `ansible-playbook ... --tags rke2-server --check --diff`.
- Time skew across nodes (etcd is picky). Confirm `chronyc tracking` reports a healthy peer on each node.

## CP2/CP3 fail to join with "connection refused" on :9345

**Symptom:** Second/third server join fails reaching the API VIP.

**Cause:** kube-vip hasn't claimed the VIP yet. The `site.yml` wait_for task on `localhost` is meant to gate this. If it returned before the VIP was actually answering on 6443, kube-vip's pod might still be ContainerCreating.

**Fix:**
```sh
ssh ubuntu@10.74.2.30 sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml -n kube-system get pod -l name=kube-vip
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

## Traefik isn't getting a LoadBalancer IP

**Symptom:** `kubectl -n kube-system get svc rke2-traefik` shows pending.

**Cause:** Traefik's service is `ClusterIP` until the `HelmChartConfig` is reconciled. RKE2's helm-controller picks up the manifest at `/var/lib/rancher/rke2/server/manifests/rke2-traefik-config.yaml` on cp1. Confirm it's there and check the controller:

```sh
kubectl -n kube-system logs deploy/helm-install-rke2-traefik
```

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

**Cause:** Older PVE versions or non-LVM-thin storage. Edit `opentofu/modules/vm/main.tf` and remove `iothread = true` / `discard = "on"` from the disk blocks.
