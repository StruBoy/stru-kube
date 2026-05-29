#!/usr/bin/env bash
# Verify that everything wipeclean needs to reach is reachable BEFORE we start
# destroying things. Two endpoint classes:
#
#   1. SSH to each PVE host listed in ansible/inventory/pve-hosts.ini
#      (hard fail — the Ansible play absolutely needs SSH).
#
#   2. The Proxmox API at $PROXMOX_VE_ENDPOINT
#      (warn-only — `tofu destroy` needs it, but the Ansible play does the VM
#      cleanup via pvesh as a backstop, so a partial wipeclean still works
#      when the API/token has gone stale).
#
# Expects `.env` to already be sourced into the environment.

set -u

INVENTORY="${INVENTORY:-ansible/inventory/pve-hosts.ini}"

fail=0
warn=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

ok()    { green "  ok    $*"; }
miss()  { red   "  FAIL  $*"; fail=$((fail+1)); }
note()  { yellow "  WARN  $*"; warn=$((warn+1)); }

echo "=== SSH to each PVE host in $INVENTORY ==="

if [ ! -f "$INVENTORY" ]; then
  miss "$INVENTORY does not exist"
elif ! command -v ansible >/dev/null 2>&1; then
  miss "ansible not installed — needed to ping PVE hosts"
else
  ping_log=$(mktemp)
  trap 'rm -f "$ping_log"' EXIT

  # `ansible -m ping` uses the inventory's ansible_user / private key.
  # ANSIBLE_HOST_KEY_CHECKING=False matches the play's ssh_args.
  if ANSIBLE_HOST_KEY_CHECKING=False ansible \
       -i "$INVENTORY" \
       -m ping proxmox_hosts >"$ping_log" 2>&1; then
    # ansible exited 0 — every host is SUCCESS
    while IFS= read -r line; do ok "$line"; done < <(grep -E 'SUCCESS' "$ping_log")
  else
    # mixed: pull both SUCCESS and UNREACHABLE lines and tag each appropriately
    while IFS= read -r line; do ok   "$line"; done < <(grep -E 'SUCCESS'    "$ping_log")
    while IFS= read -r line; do miss "$line"; done < <(grep -E 'UNREACHABLE' "$ping_log")
    # If nothing matched either pattern, surface the raw error
    if ! grep -qE 'SUCCESS|UNREACHABLE' "$ping_log"; then
      red "ansible ping produced no per-host status. Raw output:"
      sed 's/^/    /' "$ping_log"
      fail=$((fail+1))
    fi
  fi
fi

echo
echo "=== Proxmox API at \$PROXMOX_VE_ENDPOINT ==="

if [ -z "${PROXMOX_VE_ENDPOINT:-}" ]; then
  note "PROXMOX_VE_ENDPOINT not set — tofu destroy will skip / fail-soft"
else
  url="${PROXMOX_VE_ENDPOINT%/}/api2/json/version"
  curl_args=(-k -s -o /dev/null -w '%{http_code}' --max-time 8)
  if [ -n "${PROXMOX_VE_API_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN")
  fi
  http_code=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || true
  [ -z "$http_code" ] && http_code="000"
  case "$http_code" in
    200) ok   "$url responds 200" ;;
    401) note "$url responds 401 — token invalid; tofu destroy will fail, play picks up the slack" ;;
    000) note "$url unreachable; tofu destroy will fail, play picks up the slack" ;;
    *)   note "$url responds HTTP $http_code; tofu destroy may fail" ;;
  esac
fi

echo
if [ "$fail" -gt 0 ]; then
  red "wipeclean preflight FAILED: $fail unreachable endpoint(s), $warn warning(s). Aborting before any destruction."
  exit 1
elif [ "$warn" -gt 0 ]; then
  yellow "wipeclean preflight passed with $warn warning(s). Proceeding — Ansible play will handle what tofu can't."
  exit 0
else
  green "wipeclean preflight passed."
  exit 0
fi
