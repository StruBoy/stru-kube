# Environment Setup

Step-by-step instructions for installing prerequisites and collecting every value `.env` needs. Work through the sections in order — later steps depend on earlier ones.

By the end you'll have the toolchain on your workstation, a populated `.env` file in the project root, and PVE-side state (TerraformProv role, terraform@pve user, Snippets-on-`local`) all in place. **Never commit `.env`.** `.gitignore` already excludes it.

```sh
cp .env.example .env
$EDITOR .env
```

The Proxmox-side setup (sections 2–4 below) is automated by [`make bootstrap-pve`](#20-the-automated-path-make-bootstrap-pve-recommended); after the toolchain is installed you can largely just follow the [README Quickstart](../README.md#quickstart) and use this document as a reference when you hit specific values. The remaining sections explain what each `.env` variable means and how to derive it.

---

## 0. Install the toolchain

You need four CLIs on your workstation: `tofu`, `ansible`, `kubectl`, `helm`.

### macOS (Homebrew)

```sh
brew install opentofu ansible kubernetes-cli helm
```

### Linux (Debian/Ubuntu)

```sh
# OpenTofu — official install script
curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh \
  | sh -s -- --install-method deb

# The rest
sudo apt update
sudo apt install -y ansible
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update && sudo apt install -y kubectl
curl https://baltocdn.com/helm/signing.asc | sudo gpg --dearmor -o /usr/share/keyrings/helm.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
  | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt update && sudo apt install -y helm
```

### What each one is for

| Tool | Minimum version | Used by |
|---|---|---|
| `tofu` | 1.6 | `make plan` / `make apply` |
| `ansible` (incl. `ansible-playbook`, `ansible-galaxy`) | 2.16 | `make configure` / `make addons` |
| `kubectl` | 1.30 | `make verify` and day-2 ops |
| `helm` | 3.13 | Pulled in by the `kubernetes.core.helm` Ansible module |

### Verify

```sh
tofu version
ansible --version
kubectl version --client
helm version --short
```

You also need the Ansible collections used by the playbooks. Install them once:

```sh
cd ansible
ansible-galaxy install -r requirements.yml
```

(This is wrapped into `make configure`, but running it ahead of time surfaces version conflicts before the cluster build starts.)

---

## 1. `PROXMOX_VE_ENDPOINT`

The Proxmox API URL. Any node in the cluster works — the API replicates across all of them.

**Format:** `https://<host-or-ip>:8006/` (trailing slash optional, port 8006 is the default).

For this project:

```
PROXMOX_VE_ENDPOINT=https://10.74.2.20:8006/
```

Verify it's reachable from your workstation:

```sh
curl -k https://10.74.2.20:8006/api2/json/version
# Expect: {"data":{"version":"8.x.x", ...}}
```

> **Trailing-slash note.** `PROXMOX_VE_ENDPOINT` has a trailing slash (the bpg/proxmox provider wants it that way). If you concatenate it with another path in a shell command, strip the slash with `${PROXMOX_VE_ENDPOINT%/}` to avoid `//api2/...`, which PVE rejects with `no such file '/json/version'`.

If you get connection refused, check `systemctl status pveproxy` on the PVE node.

---

## 2. `PROXMOX_VE_API_TOKEN`

A scoped API token that lets OpenTofu manage VMs without using your root password. This takes a few steps because we create a dedicated user + role + token instead of using the root token.

### 2.0 The automated path: `make bootstrap-pve` (recommended)

The TerraformProv role, `terraform@pve` user, ACL grant, Snippets-on-`local`, and a systemd `.link` file disabling GSO/TSO on each PVE host's physical NICs are all created idempotently by `ansible/bootstrap-pve.yml`. Run it once before everything else:

```sh
cp ansible/inventory/pve-hosts.ini.example ansible/inventory/pve-hosts.ini
$EDITOR ansible/inventory/pve-hosts.ini       # set your PVE hostnames + IPs
make bootstrap-pve
```

It also validates that `var.pve_hosts` keys match `/etc/pve/.members` on the live cluster, so a stale config blows up here (with a clear diff) rather than later at HTTP 500.

The token itself is **not** created automatically — Proxmox prints the secret only once, so you need to run the printed command on a PVE node and paste the result into `.env`:

```sh
ssh root@10.74.2.20 'pveum user token add terraform@pve provisioner --privsep 0'
# copy `full-tokenid=value` into PROXMOX_VE_API_TOKEN in .env
```

Then `make preflight` confirms everything is wired up.

The manual steps below (§2.1–§2.6) are what `make bootstrap-pve` automates — they're kept as reference for understanding what's happening or for environments where you can't run Ansible against the PVE hosts.

### 2.1 SSH into any Proxmox node

```sh
ssh root@10.74.2.20
```

(Commands below run on the PVE shell; they replicate across the cluster, so it doesn't matter which node you pick.)

### 2.2 Create a custom role with only the privileges OpenTofu needs

```sh
pveum role add TerraformProv -privs "\
VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU \
VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory \
VM.Config.Network VM.Config.Options VM.Console VM.Migrate VM.PowerMgmt \
Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
Pool.Allocate Sys.Audit Sys.Console Sys.Modify SDN.Use"
```

> **Two gotchas in this list:**
> - `VM.Monitor` was removed in PVE 8 — `pveum` rejects it with "invalid privilege 'VM.Monitor'". Use `VM.Console` (covers serial console / cloud-init init access).
> - `Datastore.Allocate` is **required** in addition to `Datastore.AllocateSpace`. Without it, snippet uploads fail with HTTP 403 `Permission check failed (/storage/local, Datastore.Allocate)`.
>
> If you already created the role without `Datastore.Allocate`, modify it in place:
> ```sh
> pveum role modify TerraformProv -privs "VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.PowerMgmt,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,Pool.Allocate,Sys.Audit,Sys.Console,Sys.Modify,SDN.Use"
> ```
> (Note: `modify` takes commas, `add` takes spaces.)

Verify:

```sh
pveum role list | grep TerraformProv
```

### 2.3 Create the `terraform` user

```sh
pveum user add terraform@pve --comment "OpenTofu service account"
```

(`@pve` means a Proxmox-internal user — no PAM/LDAP account needed.)

### 2.4 Grant the role at the root path

```sh
pveum aclmod / -user terraform@pve -role TerraformProv
```

Verify:

```sh
pveum user permissions terraform@pve --path /
```

### 2.5 Create the API token

```sh
pveum user token add terraform@pve provisioner --privsep 0
```

`--privsep 0` means the token inherits the user's full privileges (simpler for a single-purpose token; set to `1` and re-ACL the token if you want narrower scope later).

**Output** (capture this exactly — the secret is shown ONCE):

```
┌──────────────┬──────────────────────────────────────┐
│ key          │ value                                │
├──────────────┼──────────────────────────────────────┤
│ full-tokenid │ terraform@pve!provisioner            │
│ info         │ {"privsep":"0"}                      │
│ value        │ 12345678-aaaa-bbbb-cccc-1234567890ab │
└──────────────┴──────────────────────────────────────┘
```

The `.env` value combines both lines as `<full-tokenid>=<value>`:

```
PROXMOX_VE_API_TOKEN=terraform@pve!provisioner=12345678-aaaa-bbbb-cccc-1234567890ab
```

### 2.6 (Optional) test the token

From your workstation:

```sh
curl -k -H "Authorization: PVEAPIToken=terraform@pve!provisioner=12345678-..." \
  https://10.74.2.20:8006/api2/json/version
# Note: no trailing slash on the host:port portion when you build the URL by hand.
```

Should return the same `{"data": {"version": ...}}` you got with anonymous access.

### If you need to rotate or revoke

```sh
# Revoke
pveum user token remove terraform@pve provisioner

# Re-create (new secret value)
pveum user token add terraform@pve provisioner --privsep 0
```

Update `.env` and re-run `tofu apply`.

### 2.7 Discover your PVE node names (critical — go to `terraform.tfvars`)

`var.pve_hosts` in [opentofu/variables.tf](../opentofu/variables.tf) maps each PVE node name to its IP. The **keys must match the actual names PVE uses** (corosync / `/etc/pve/.members`), not "pve1/2/3" placeholders. If they don't, the API returns HTTP 500 `hostname lookup failed`.

While SSHed into a PVE node:

```sh
cat /etc/pve/.members
# Look at the "nodelist" object — those keys are the names.
```

Example output:

```
"nodelist": {
  "stru-prox0": { "id": 1, "online": 1, "ip": "10.74.2.20" },
  "stru-prox1": { "id": 2, "online": 1, "ip": "10.74.2.21" },
  "stru-prox2": { "id": 3, "online": 1, "ip": "10.74.2.22" }
}
```

If your names aren't `stru-prox0/1/2`, override the defaults by creating `opentofu/terraform.tfvars`:

```hcl
pve_hosts = {
  myhost-a = "10.74.2.20"
  myhost-b = "10.74.2.21"
  myhost-c = "10.74.2.22"
}
# And update control_plane/workers to use those host names
```

---

## 3. `PROXMOX_VE_INSECURE`

Set to `true` if your Proxmox nodes use the default self-signed certificates (typical for homelab). Set to `false` if you've installed a real cert (Let's Encrypt, internal PKI, etc.) and want strict TLS validation.

For a stock homelab install:

```
PROXMOX_VE_INSECURE=true
```

---

## 4. `PROXMOX_VE_SSH_USERNAME`

The `bpg/proxmox` provider needs SSH access (not just the API token) for a few operations: uploading cloud-init snippets and importing disk images. The user must have shell access on every PVE node.

**Recommendation:** use `root`. That's what the default Proxmox install gives you and what most homelab tutorials assume.

```
PROXMOX_VE_SSH_USERNAME=root
```

### 4.1 Make sure your SSH key is authorized on every PVE node

On each PVE node:

```sh
ssh-copy-id root@10.74.2.20
ssh-copy-id root@10.74.2.21
ssh-copy-id root@10.74.2.22
```

Verify keyless SSH works:

```sh
ssh root@10.74.2.20 hostname
ssh root@10.74.2.21 hostname
ssh root@10.74.2.22 hostname
```

The provider config in `opentofu/providers.tf` uses `agent = true`, so make sure your key is loaded. **bpg/proxmox does NOT honor `~/.ssh/config`** — it only reads from `ssh-agent`. If the agent is empty, every disk/snippet upload fails with `ssh: handshake failed: unable to authenticate, attempted methods [none password]`.

```sh
# Check what's in the agent
ssh-add -L

# If empty:
ssh-add ~/.ssh/id_ed25519                  # Linux
ssh-add --apple-use-keychain ~/.ssh/id_ed25519   # macOS (persists across reboots)
```

On macOS, `--apple-use-keychain` stores the passphrase in Keychain so you don't have to re-add the key every time the agent restarts.

### 4.2 If you prefer a non-root user

Create a user with NOPASSWD sudo on each PVE node:

```sh
adduser pveops
usermod -aG sudo pveops
echo "pveops ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/pveops
chmod 0440 /etc/sudoers.d/pveops
```

Then set `PROXMOX_VE_SSH_USERNAME=pveops` and copy your SSH key to that account. (Skip this if root is fine — it's simpler.)

---

## 5. `RKE2_TOKEN`

A shared secret that lets RKE2 nodes join the cluster. Used by every server and agent. Generate a strong random value once and reuse it forever (rotate via the [runbook](runbook.md#rotate-the-rke2-cluster-token)).

```sh
openssl rand -hex 32
# Example output: 9f3c8a72d1b5e604a7f8b91c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e
```

Copy that into `.env`:

```
RKE2_TOKEN=9f3c8a72d1b5e604a7f8b91c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e
```

**This is sensitive.** Anyone with the token and network access to a server's port 9345 can join a rogue node to your cluster.

---

## 6. SSH keys (`ANSIBLE_SSH_KEY_FILE`, `SSH_PUBLIC_KEY_FILE`)

These point at the keypair used to reach the **cluster VMs** (cp1–cp3, w1–w3). The public key is injected by cloud-init; the private key is recorded in the generated Ansible inventory so playbooks can connect.

### 6.1 Use an existing key (recommended)

If you already have `~/.ssh/id_ed25519` (and `~/.ssh/id_ed25519.pub`), you're done — the defaults in `.env.example` already point at these:

```
ANSIBLE_SSH_KEY_FILE=~/.ssh/id_ed25519
SSH_PUBLIC_KEY_FILE=~/.ssh/id_ed25519.pub
```

Verify:

```sh
ls -l ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
ssh-keygen -lf ~/.ssh/id_ed25519.pub
```

### 6.2 Or generate a new one

```sh
ssh-keygen -t ed25519 -C "stru-kube" -f ~/.ssh/stru-kube
# Press Enter twice for no passphrase (simpler for Ansible) — or set one and use ssh-agent
```

Update `.env`:

```
ANSIBLE_SSH_KEY_FILE=~/.ssh/stru-kube
SSH_PUBLIC_KEY_FILE=~/.ssh/stru-kube.pub
```

If the key has a passphrase, load it into ssh-agent before running Ansible:

```sh
ssh-add ~/.ssh/stru-kube
```

### 6.3 The PVE SSH key vs the VM SSH key

These can be the same key or different keys — they serve different purposes:

| Key | Used by | Authorizes access to |
|---|---|---|
| The one in `ssh-agent` for the `PROXMOX_VE_SSH_USERNAME` | OpenTofu (during apply) | Proxmox hosts (`stru-prox0/1/2` in this repo, whatever PVE calls yours) |
| `ANSIBLE_SSH_KEY_FILE` / `SSH_PUBLIC_KEY_FILE` | Ansible + cloud-init | Cluster VMs (cp1–w3) |

For a homelab, using the same `~/.ssh/id_ed25519` for both is fine.

---

## 7. Longhorn UI auth (`LONGHORN_UI_USER`, `LONGHORN_UI_PASS`)

The Longhorn web UI is exposed via the nginx ingress at `longhorn.lan` behind HTTP basic auth. These values feed an htpasswd secret created during `make addons`.

```
LONGHORN_UI_USER=admin
LONGHORN_UI_PASS=$(openssl rand -base64 16)
```

Or pick a memorable password — your call. To rotate later, update `.env` and re-run the longhorn-tagged tasks:

```sh
ansible-playbook -i inventory/hosts.ini addons.yml --tags longhorn
```

---

## 8. ArgoCD & Sealed Secrets (GitOps) — all optional

These power the GitOps layer (`make addons` / `make gitops`). **Every one is optional**: leave it
blank and the matching Ansible task simply skips, so the cluster installs ArgoCD + Sealed Secrets
fine before you've created any GitOps repo. They're documented in `.env.example`. `make preflight`
lists them under "optional GitOps env vars" and only *warns* (never fails) when they're unset.

These are ArgoCD's own **bootstrap** secrets. Application secrets don't go here — they go into Git
as Sealed Secrets (see [runbook.md](runbook.md#sealed-secrets)).

| Var | Purpose | Blank behavior |
|---|---|---|
| `ARGOCD_ADMIN_PASS` | ArgoCD `admin` UI password (bcrypt-hashed at apply time) | Chart's random initial password is kept (read it from `argocd-initial-admin-secret`) |
| `ARGOCD_ROOT_REPO_URL` | Your separate GitOps repo for the app-of-apps `root` | `root` Application is not created |
| `ARGOCD_ROOT_REPO_PATH` | Dir in that repo holding child `Application`s (default `apps`) | — |
| `ARGOCD_ROOT_REPO_REVISION` | Branch/tag/SHA to track (default `main`) | — |
| `ARGOCD_GIT_URL_PREFIX` | URL prefix for private repos (default `https://github.com/StruBoy/`) | — |
| `ARGOCD_GIT_USERNAME` | Git username for private-repo PAT | — |
| `ARGOCD_GIT_TOKEN` | GitHub PAT / token covering all private repos under the prefix | No private-repo creds created (public repos still clone anonymously) |

```
ARGOCD_ADMIN_PASS=$(openssl rand -base64 16)
ARGOCD_ROOT_REPO_URL=https://github.com/StruBoy/<your-gitops-repo>.git
ARGOCD_ROOT_REPO_PATH=apps
ARGOCD_ROOT_REPO_REVISION=main
ARGOCD_GIT_URL_PREFIX=https://github.com/StruBoy/
ARGOCD_GIT_USERNAME=StruBoy
ARGOCD_GIT_TOKEN=ghp_xxx          # fine-grained PAT with read access to your private repos
```

To rotate the admin password or change the root repo later, update `.env` and re-run the GitOps
layer: `make gitops` (or `ansible-playbook -i inventory/hosts.ini addons.yml --tags argocd`).

---

## 9. Wiring `.env` into your shell

The Makefile expects `.env` to be sourced into the environment before targets run. Two common patterns:

### One-shot per session

```sh
set -a; source .env; set +a
make plan
make apply
```

### `direnv` (auto-load when you `cd` into the repo)

```sh
brew install direnv   # macOS
# add `eval "$(direnv hook zsh)"` to ~/.zshrc

cat > .envrc <<'EOF'
set -a
source .env
set +a
EOF

direnv allow
```

Now `cd /path/to/stru-kube` auto-loads `.env`. `.envrc` should also be gitignored.

---

## 10. Sanity check

Confirm everything is wired:

```sh
set -a; source .env; set +a

# Proxmox reachable + token valid
curl -k -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "${PROXMOX_VE_ENDPOINT%/}/api2/json/version"

# Required vars present (run in bash; zsh uses ${(P)v} instead of ${!v})
bash <<'BASH'
for v in PROXMOX_VE_ENDPOINT PROXMOX_VE_API_TOKEN PROXMOX_VE_INSECURE \
         PROXMOX_VE_SSH_USERNAME RKE2_TOKEN ANSIBLE_SSH_KEY_FILE \
         SSH_PUBLIC_KEY_FILE LONGHORN_UI_USER LONGHORN_UI_PASS; do
  if [ -z "${!v}" ]; then echo "MISSING: $v"; else echo "ok:      $v"; fi
done
BASH

# SSH keypair exists
ls -l "${ANSIBLE_SSH_KEY_FILE/#\~/$HOME}" "${SSH_PUBLIC_KEY_FILE/#\~/$HOME}"

# Token length sanity
[ ${#RKE2_TOKEN} -ge 32 ] && echo "RKE2_TOKEN looks ok" || echo "RKE2_TOKEN too short"
```

All checks passing? You're ready for `make plan`.

---

## Don't forget the one-time PVE GUI step

`make bootstrap-pve` enables this for you automatically. If you're skipping the bootstrap play and configuring PVE by hand, **enable Snippets** on `local` storage:

1. Open the Proxmox web UI → **Datacenter** → **Storage**
2. Select `local` → click **Edit**
3. In the **Content** dropdown, check **Snippets**
4. **OK**

Without this, the cloud-init user-data uploads silently fail and VMs come up without their static IPs. See [troubleshooting.md](troubleshooting.md#cloud-init-didnt-apply--static-ip-missing) for symptoms.
