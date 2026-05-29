.PHONY: help preflight bootstrap-pve wipeclean plan apply configure addons verify verify-full reset clean fmt validate syntax-check

SHELL := /bin/bash
TOFU_DIR := opentofu
ANSIBLE_DIR := ansible
KUBECONFIG_FILE := $(PWD)/kubeconfig/rke2.yaml

# Each recipe line runs in its own subshell, so sourcing must happen on the
# same line as the command that needs the env vars. SOURCE_ENV exports every
# variable in .env (if present) and is harmless if the file is missing.
SOURCE_ENV := set -a; [ -f .env ] && . .env; set +a

help:
	@echo "Targets:"
	@echo "  preflight       check toolchain, env vars, ssh-agent, Proxmox API reachability"
	@echo "  bootstrap-pve   one-time PVE setup: TerraformProv role, terraform@pve user, Snippets"
	@echo "  plan            tofu init + tofu plan (runs preflight first)"
	@echo "  apply           tofu apply (provisions VMs, writes ansible inventory)"
	@echo "  configure       ansible-playbook site.yml (installs RKE2; runs preflight first)"
	@echo "  addons          ansible-playbook addons.yml (MetalLB, Longhorn, nginx ingress)"
	@echo "  verify          kubeconfig + VIP reachability + kubectl smoke tests"
	@echo "  verify-full     verify, then deploy a LoadBalancer service end-to-end (deletes it after)"
	@echo "  reset           ansible-playbook reset.yml (uninstall RKE2 cleanly)"
	@echo "  clean           destroy VMs (tofu destroy)"
	@echo "  wipeclean       DESTRUCTIVE: VMs + PVE role/user/token + snippets (requires CONFIRM=yes)"
	@echo "  fmt             tofu fmt -recursive"
	@echo "  validate        tofu validate + ansible-playbook --syntax-check"

preflight:
	@$(SOURCE_ENV); bash scripts/preflight.sh

bootstrap-pve:
	@if [ ! -f $(ANSIBLE_DIR)/inventory/pve-hosts.ini ]; then \
		echo "ERROR: $(ANSIBLE_DIR)/inventory/pve-hosts.ini does not exist."; \
		echo "Run: cp $(ANSIBLE_DIR)/inventory/pve-hosts.ini.example $(ANSIBLE_DIR)/inventory/pve-hosts.ini"; \
		echo "then edit it for your environment."; \
		exit 1; \
	fi
	$(SOURCE_ENV); cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/pve-hosts.ini bootstrap-pve.yml

plan: preflight
	$(SOURCE_ENV); cd $(TOFU_DIR) && tofu init -upgrade && tofu plan -out=tfplan

apply:
	$(SOURCE_ENV); cd $(TOFU_DIR) && tofu apply tfplan

configure: preflight
	cd $(ANSIBLE_DIR) && ansible-galaxy install -r requirements.yml
	$(SOURCE_ENV); cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.ini site.yml

addons:
	$(SOURCE_ENV); cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.ini addons.yml

verify:
	@export KUBECONFIG=$(KUBECONFIG_FILE); \
		if [ ! -f "$$KUBECONFIG" ]; then \
			echo "FAIL: $$KUBECONFIG does not exist. Run 'make configure' first."; \
			exit 1; \
		fi; \
		api_url=$$(awk '/server:/{print $$2; exit}' "$$KUBECONFIG"); \
		if [ -z "$$api_url" ]; then \
			echo "FAIL: no 'server:' line in $$KUBECONFIG"; exit 1; \
		fi; \
		if echo "$$api_url" | grep -q '127.0.0.1'; then \
			echo "FAIL: kubeconfig points at 127.0.0.1 — post_install role didn't rewrite it."; \
			echo "      Re-run: ansible-playbook -i inventory/hosts.ini site.yml --tags post-install"; \
			exit 1; \
		fi; \
		if ! curl -kfs --max-time 5 "$$api_url/version" > /dev/null; then \
			echo "FAIL: $$api_url/version unreachable from this workstation."; \
			echo "      - is the cluster up? ssh ubuntu@<cp-ip> sudo systemctl status rke2-server"; \
			echo "      - some switches filter gratuitous ARP from kube-vip; see docs/troubleshooting.md"; \
			exit 1; \
		fi; \
		echo "API at $$api_url is reachable."; \
		kubectl get nodes -o wide && \
		kubectl get pods -A && \
		kubectl get sc

# Deploys a LoadBalancer service end-to-end. Catches MetalLB pool mis-config and
# nginx-ingress / kube-proxy regressions that `verify` would miss.
verify-full: verify
	@export KUBECONFIG=$(KUBECONFIG_FILE); \
		set -eu; \
		echo ">>> deploying nginx-verify as LoadBalancer"; \
		kubectl create deployment nginx-verify --image=nginx:alpine; \
		kubectl expose deployment nginx-verify --port=80 --type=LoadBalancer; \
		echo ">>> waiting up to 60s for MetalLB to assign EXTERNAL-IP..."; \
		ip=""; for i in $$(seq 1 30); do \
			ip=$$(kubectl get svc nginx-verify -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); \
			if [ -n "$$ip" ]; then break; fi; \
			sleep 2; \
		done; \
		if [ -z "$$ip" ]; then \
			echo "FAIL: MetalLB never assigned an EXTERNAL-IP"; \
			kubectl delete deployment,svc nginx-verify; \
			exit 1; \
		fi; \
		echo ">>> got EXTERNAL-IP=$$ip — fetching /"; \
		curl -fs --max-time 5 "http://$$ip/" | head -1; \
		echo ">>> cleaning up"; \
		kubectl delete deployment,svc nginx-verify

reset:
	$(SOURCE_ENV); cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.ini reset.yml

clean:
	$(SOURCE_ENV); cd $(TOFU_DIR) && tofu destroy

# Returns the Proxmox cluster to a virgin state — no VMs, no terraform user/role,
# no Snippets on local storage, no downloaded cloud image. Required to be invoked
# with CONFIRM=yes so a stray `make wipeclean` doesn't nuke a working cluster.
# Does NOT depend on `preflight` — the whole point is recovering from broken state.
wipeclean:
	@if [ "$(CONFIRM)" != "yes" ]; then \
		echo "DESTRUCTIVE: this will destroy all cluster VMs, all 3 templates,"; \
		echo "the TerraformProv role, the terraform@pve user + token, revert"; \
		echo "Snippets on local storage, delete the cloud image, and sweep"; \
		echo "leftover snippet files. To proceed:"; \
		echo "    make wipeclean CONFIRM=yes"; \
		exit 1; \
	fi
	@if [ ! -f $(ANSIBLE_DIR)/inventory/pve-hosts.ini ]; then \
		echo "ERROR: $(ANSIBLE_DIR)/inventory/pve-hosts.ini does not exist."; \
		echo "Run: cp $(ANSIBLE_DIR)/inventory/pve-hosts.ini.example $(ANSIBLE_DIR)/inventory/pve-hosts.ini"; \
		exit 1; \
	fi
	@echo ">>> Step 1/3: reachability preflight (SSH to each PVE host + API endpoint)"
	@$(SOURCE_ENV); bash scripts/wipeclean-preflight.sh
	@echo ">>> Step 2/3: tofu destroy (no-op if state is already gone)"
	-$(SOURCE_ENV); cd $(TOFU_DIR) && tofu destroy -auto-approve
	@echo ">>> Step 3/3: PVE-side wipe (role, user, snippets, images)"
	$(SOURCE_ENV); cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/pve-hosts.ini wipeclean-pve.yml
	@echo ">>> PVE cluster is back to a clean state. Re-run 'make bootstrap-pve' to redeploy."

fmt:
	cd $(TOFU_DIR) && tofu fmt -recursive

validate:
	cd $(TOFU_DIR) && tofu validate
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check -i inventory/hosts.ini site.yml addons.yml
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check -i inventory/pve-hosts.ini.example bootstrap-pve.yml wipeclean-pve.yml

syntax-check: validate
