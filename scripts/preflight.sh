#!/usr/bin/env bash
# Workstation preflight: runs before `make plan` / `make configure`.
# Fails fast and loud on the wires we've previously tripped:
#   - missing tools                   (smooth fresh-laptop onboarding)
#   - empty ssh-agent                 (bpg/proxmox ignores ~/.ssh/config)
#   - missing env vars                (silent template renders → broken cluster)
#   - missing ssh keypair on disk     (cloud-init / Ansible auth)
#   - unreachable Proxmox API         (wrong endpoint, dead pveproxy, bad token)
#
# Expects `.env` to already be sourced into the environment.

set -u

fail=0
warn=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

ok()    { green "  ok    $*"; }
miss()  { red   "  FAIL  $*"; fail=$((fail+1)); }
note()  { yellow "  WARN  $*"; warn=$((warn+1)); }

# Compare versions: returns 0 if $1 >= $2 (treats version strings as dotted ints).
version_ge() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

check_tool() {
  local name="$1" min="$2" version_cmd="$3"
  if ! command -v "$name" >/dev/null 2>&1; then
    miss "$name not installed (need >= $min)"
    return
  fi
  local got
  got=$(eval "$version_cmd" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  if [ -z "$got" ]; then
    note "$name installed but version unparseable"
    return
  fi
  if version_ge "$got" "$min"; then
    ok "$name $got (>= $min)"
  else
    miss "$name $got is older than required $min"
  fi
}

check_env() {
  local var="$1"
  if [ -z "${!var:-}" ]; then
    miss "\$$var is empty or unset (source .env first, or run \`make bootstrap-pve\`)"
  else
    ok "\$$var is set"
  fi
}

check_file() {
  local var="$1"
  local raw="${!var:-}"
  if [ -z "$raw" ]; then
    miss "\$$var is empty — can't check file existence"
    return
  fi
  # expand leading ~
  local path="${raw/#\~/$HOME}"
  if [ -r "$path" ]; then
    ok "\$$var → $path (readable)"
  else
    miss "\$$var → $path (missing or unreadable)"
  fi
}

echo "=== toolchain ==="
check_tool tofu     1.6   'tofu version'
check_tool ansible  2.16  'ansible --version'
check_tool kubectl  1.28  'kubectl version --client'
check_tool helm     3.13  'helm version --short'
check_tool curl     0     'curl --version'

echo
echo "=== ssh-agent ==="
if ssh-add -L >/dev/null 2>&1; then
  key_count=$(ssh-add -L 2>/dev/null | grep -c '^ssh-')
  ok "ssh-agent has $key_count key(s) loaded"
else
  miss "ssh-agent has no keys — bpg/proxmox needs one. Run:  ssh-add ~/.ssh/id_ed25519"
fi

echo
echo "=== required env vars ==="
for v in PROXMOX_VE_ENDPOINT PROXMOX_VE_API_TOKEN PROXMOX_VE_SSH_USERNAME \
         RKE2_TOKEN ANSIBLE_SSH_KEY_FILE SSH_PUBLIC_KEY_FILE \
         LONGHORN_UI_USER LONGHORN_UI_PASS; do
  check_env "$v"
done

echo
echo "=== SSH keypair files ==="
check_file ANSIBLE_SSH_KEY_FILE
check_file SSH_PUBLIC_KEY_FILE

echo
echo "=== Proxmox API reachable ==="
if [ -n "${PROXMOX_VE_ENDPOINT:-}" ]; then
  # Strip trailing slash so concat doesn't produce //api2/...
  url="${PROXMOX_VE_ENDPOINT%/}/api2/json/version"
  curl_args=(-k -s -o /dev/null -w '%{http_code}' --max-time 8)
  if [ -n "${PROXMOX_VE_API_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN")
  fi
  http_code=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || true
  [ -z "$http_code" ] && http_code="000"
  case "$http_code" in
    200) ok  "$url responds 200 (token valid)" ;;
    401) miss "$url responds 401 — token invalid or expired" ;;
    000) miss "$url unreachable (timeout / DNS / TLS / network — confirm \$PROXMOX_VE_ENDPOINT is correct and you're on the right network)" ;;
    *)   miss "$url responds HTTP $http_code (unexpected)" ;;
  esac
else
  miss "skipping API reachability check — PROXMOX_VE_ENDPOINT not set"
fi

echo
if [ "$fail" -gt 0 ]; then
  red   "preflight FAILED: $fail problem(s), $warn warning(s)"
  exit 1
elif [ "$warn" -gt 0 ]; then
  yellow "preflight passed with $warn warning(s)"
  exit 0
else
  green "preflight passed"
  exit 0
fi
