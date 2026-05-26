.PHONY: help plan apply configure addons verify reset clean fmt validate syntax-check

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
	@echo "  plan          tofu init + tofu plan"
	@echo "  apply         tofu apply (provisions VMs, writes ansible inventory)"
	@echo "  configure     ansible-playbook site.yml (installs RKE2)"
	@echo "  addons        ansible-playbook addons.yml (MetalLB, Longhorn, nginx ingress)"
	@echo "  verify        kubectl smoke tests against the cluster"
	@echo "  reset         ansible-playbook reset.yml (uninstall RKE2 cleanly)"
	@echo "  clean         destroy VMs (tofu destroy)"
	@echo "  fmt           tofu fmt -recursive"
	@echo "  validate      tofu validate + ansible-playbook --syntax-check"

plan:
	$(SOURCE_ENV); cd $(TOFU_DIR) && tofu init -upgrade && tofu plan -out=tfplan

apply:
	$(SOURCE_ENV); cd $(TOFU_DIR) && tofu apply tfplan

configure:
	cd $(ANSIBLE_DIR) && ansible-galaxy install -r requirements.yml
	$(SOURCE_ENV); cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.ini site.yml

addons:
	$(SOURCE_ENV); cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.ini addons.yml

verify:
	@export KUBECONFIG=$(KUBECONFIG_FILE); \
		kubectl get nodes -o wide && \
		kubectl get pods -A && \
		kubectl get sc

reset:
	$(SOURCE_ENV); cd $(ANSIBLE_DIR) && ansible-playbook -i inventory/hosts.ini reset.yml

clean:
	$(SOURCE_ENV); cd $(TOFU_DIR) && tofu destroy

fmt:
	cd $(TOFU_DIR) && tofu fmt -recursive

validate:
	cd $(TOFU_DIR) && tofu validate
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check -i inventory/hosts.ini site.yml addons.yml

syntax-check: validate
