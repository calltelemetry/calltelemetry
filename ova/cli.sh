#!/bin/bash

# cli.sh semver — bump on any user-visible change to this script.
# Independent from the appliance release version (cli.sh ships with every
# bundle but may be updated across multiple releases). Print via `cli.sh
# version` / `cli.sh --version`; also included in `upgrade-diag-*.log`.
# Bumping rules (for X.Y.Z):
#   - PATCH  X.Y.(Z+1) — bug fixes, non-functional cleanup
#   - MINOR  X.(Y+1).0 — new subcommand, new diagnostic section, new phase
#   - MAJOR  (X+1).0.0 — breaking change in subcommand signature or output
CLI_VERSION="0.11.5"

# Short-circuit --version / -V / version (before the ASCII banner / INSTALL_DIR
# detection runs, so this works on any host with any permission).
case "${1:-}" in
  --version|-V|version)
    echo "cli.sh ${CLI_VERSION}"
    exit 0
    ;;
esac

# Test-mode detection: stash this once at the top so helpers called from
# anywhere (including subshells like $(detect_docker_compose)) can read
# it without re-parsing $1. CodeRabbit hardening on PR #76.
CLI_TEST_HARNESS_MODE=0
if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
  case "${1:-}" in __test_*) CLI_TEST_HARNESS_MODE=1 ;; esac
fi
export CLI_TEST_HARNESS_MODE

# ─── Output helpers ─────────────────────────────────────────────────────
#
# Standardize status markers so the operator eye trains on one visual
# pattern. Call log_ok / log_fail / log_warn instead of raw
# `echo "[OK] ..."` / `"[FAIL]"` / `"[WARN]"` / emoji mixes.
#
# Color is auto-detected: enabled on a TTY stdout, suppressed when
# piped (so logs captured via tee / ansible / journalctl stay clean).
# Override with CLI_COLOR=0 (force off) or CLI_COLOR=1 (force on).
#
# log_fail writes to stderr so automation (scripts grepping exit output,
# CI lint rules, etc.) can redirect failure signal independently. To
# capture EVERYTHING to a single file, use `cli.sh ... 2>&1 | tee out.log`.
#
# The single remaining raw `[WARN]` in the file (certificate-expiry
# Status column) is an intentional formatted-column marker, not a log
# line — keep it raw to preserve the fixed-width layout.
if [ -t 1 ] && [ "${CLI_COLOR:-auto}" != "0" ] || [ "${CLI_COLOR:-}" = "1" ]; then
  _C_OK=$'\e[32m'; _C_FAIL=$'\e[31m'; _C_WARN=$'\e[33m'
  _C_INFO=$'\e[34m'; _C_STEP=$'\e[1m'; _C_DIM=$'\e[2m'; _C_RESET=$'\e[0m'
else
  _C_OK=""; _C_FAIL=""; _C_WARN=""; _C_INFO=""; _C_STEP=""; _C_DIM=""; _C_RESET=""
fi

log_ok()   { printf '%s✓%s %s\n' "$_C_OK"   "$_C_RESET" "$*"; }
log_fail() { printf '%s✗%s %s\n' "$_C_FAIL" "$_C_RESET" "$*" >&2; }
log_warn() { printf '%s⚠%s %s\n' "$_C_WARN" "$_C_RESET" "$*"; }
log_info() { printf '%sℹ%s %s\n' "$_C_INFO" "$_C_RESET" "$*"; }
log_step() { printf '\n%s▸ %s%s\n' "$_C_STEP" "$*" "$_C_RESET"; }
log_dim()  { printf '%s%s%s\n'   "$_C_DIM"  "$*" "$_C_RESET"; }

print_failure_card() {
  local title="$1" reason="$2" impact="$3" next_step="$4" details="${5:-}"

  printf '\n' >&2
  log_fail "$title"
  printf '   Reason: %s\n' "$reason" >&2
  printf '   Impact: %s\n' "$impact" >&2
  printf '   Next step: %s\n' "$next_step" >&2
  if [ -n "$details" ]; then
    printf '   Details: %s\n' "$details" >&2
  fi
}

# Verbosity controls.
#   CLI_QUIET=1   suppress per-tick \r-updated heartbeat lines.
#                 Phase headers and final OK/FAIL outcomes still print.
#                 Useful for CI/automation logs where \r updates become noise.
#   CLI_VERBOSE=1 print extra diagnostic detail (reserved for per-call adoption).
cli_quiet()   { [ "${CLI_QUIET:-0}" = "1" ]; }
cli_verbose() { [ "${CLI_VERBOSE:-0}" = "1" ]; }

# Verbose-only variants of the log helpers. Default runs (customer-facing)
# stay silent for these; a dev with `--verbose` / `CLI_VERBOSE=1` gets the
# full detail. Use these for internal check confirmations that don't
# belong in a normal upgrade transcript.
log_verbose()      { cli_verbose || return 0; printf '  %s\n' "$*"; }
log_verbose_ok()   { cli_verbose || return 0; log_ok   "$@"; }
log_verbose_warn() { cli_verbose || return 0; log_warn "$@"; }
log_verbose_info() { cli_verbose || return 0; log_info "$@"; }

# log_heartbeat <format> [args...] — prints a \r-updated progress line
# unless CLI_QUIET=1. Caller owns the trailing \n (usually via a subsequent
# success/failure log line once the phase resolves).
log_heartbeat() {
  cli_quiet && return 0
  # shellcheck disable=SC2059
  printf "$@"
}

# ASCII Art Logo — only printed for interactive help, not subcommand calls
if [ $# -eq 0 ] || [ "${1:-}" = "help" ]; then
cat << "EOF"

   ______      ____   ______     __                    __
  / ____/___ _/ / /  /_  __/__  / /__  ____ ___  ___  / /________  __
 / /   / __ `/ / /    / / / _ \/ / _ \/ __ `__ \/ _ \/ __/ ___/ / / /
/ /___/ /_/ / / /    / / /  __/ /  __/ / / / / /  __/ /_/ /  / /_/ /
\____/\__,_/_/_/    /_/  \___/_/\___/_/ /_/ /_/\___/\__/_/   \__, /
                                                            /____/

https://calltelemetry.com
EOF
fi

# Detect installation user and directory
if [ -n "${SUDO_USER:-}" ]; then
  INSTALL_USER="$SUDO_USER"
  INSTALL_DIR=$(eval echo "~$SUDO_USER")
else
  INSTALL_USER=$(whoami)
  INSTALL_DIR="$HOME"
fi

# --- Existing installation detection ---
# Prevent accidentally creating a second instance when running as root
# or from the wrong directory. Check well-known install paths for an
# existing docker-compose.yml with CallTelemetry services.
KNOWN_INSTALL_PATHS="/home/calltelemetry /opt/calltelemetry"

if [ "${CT_CLI_TEST_MODE:-0}" != "1" ]; then
  for check_path in $KNOWN_INSTALL_PATHS; do
    if [ "$check_path" != "$INSTALL_DIR" ] && [ -f "$check_path/docker-compose.yml" ]; then
      # Verify it's actually a CallTelemetry compose file (not some unrelated project)
      if grep -q "calltelemetry" "$check_path/docker-compose.yml" 2>/dev/null; then
        echo ""
        echo "  Note: Existing installation detected at $check_path"
        echo "  Using $check_path instead of $INSTALL_DIR"
        echo ""
        INSTALL_DIR="$check_path"
        INSTALL_USER=$(stat -c '%U' "$check_path" 2>/dev/null || ls -ld "$check_path" | awk '{print $3}')
        break
      fi
    fi
  done
fi

cd "$INSTALL_DIR" 2>/dev/null || true

# Directory for storing backups and other directories to be cleared
BACKUP_DIR="${INSTALL_DIR}/backups"
BACKUP_FOLDER_PATH="${INSTALL_DIR}/db_dumps"
SFTP_DIR="sftp/*"
POSTGRES_DATA_DIR="postgres-data"
# Original and backup docker-compose files
ORIGINAL_FILE="docker-compose.yml"
TEMP_FILE="temp-docker-compose.yml"
# GCS URLs for downloads (no GitHub dependency)
GCS_BASE_URL="https://storage.googleapis.com/ct_releases"
SCRIPT_URL="${GCS_BASE_URL}/cli.sh"
GCS_BUNDLE_BASE_URL="${GCS_BASE_URL}/releases"

CLI_INSTALL_PATH="${INSTALL_DIR}/cli.sh"
# Detect if running from a pipe (curl ... | sh) vs local file
if [ -f "$0" ] && [ "$0" != "sh" ] && [ "$0" != "bash" ] && [ "$0" != "-bash" ]; then
  CURRENT_SCRIPT_PATH="$0"
  CT_CLI_FROM_STDIN=0
else
  CURRENT_SCRIPT_PATH="$CLI_INSTALL_PATH"
  CT_CLI_FROM_STDIN=1
fi

# Capture the original argv for use in error hints like "re-run with sudo ...".
# Stored as an array so we can requote safely regardless of spaces in args.
ORIGINAL_ARGS=("$@")

# Prep script from GCS
PREP_SCRIPT_URL="${GCS_BASE_URL}/prep.sh"

# Fail early if a privileged subcommand is invoked without root.
# Destructive helpers (restart_service, jtapi enable/disable, offline apply,
# ipv6 toggle, upgrade, rollback) must NEVER run `docker rm -f` or mutate
# systemd state when systemctl will later fail with "Access denied".
# Call this FIRST, before any mutation.
require_root() {
  local context="${1:-this command}"
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  log_fail "$context requires root privileges."
  echo ""
  echo "  systemctl and privileged docker operations need root to succeed."
  echo "  Re-run with sudo, for example:"
  echo ""
  if [ "${#ORIGINAL_ARGS[@]}" -gt 0 ]; then
    printf '    sudo %s' "$CURRENT_SCRIPT_PATH"
    printf ' %q' "${ORIGINAL_ARGS[@]}"
    printf '\n'
  else
    echo "    sudo $CURRENT_SCRIPT_PATH"
  fi
  echo ""
  return 1
}

# --- Self-healing bind-mount fix ---
# Docker auto-creates missing bind-mount paths as DIRECTORIES.
# If alertmanager.yml was created as a directory, fix it NOW before
# any Docker command runs. This runs on every cli.sh invocation.
if [ -d "${INSTALL_DIR}/alertmanager/alertmanager.yml" ]; then
  rm -rf "${INSTALL_DIR}/alertmanager/alertmanager.yml"
fi
mkdir -p "${INSTALL_DIR}/alertmanager"
if [ ! -f "${INSTALL_DIR}/alertmanager/alertmanager.yml" ]; then
  cat > "${INSTALL_DIR}/alertmanager/alertmanager.yml" << 'AMEOF'
global:
  resolve_timeout: 5m
route:
  receiver: 'default'
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
receivers:
  - name: 'default'
AMEOF
fi
if [ -d "${INSTALL_DIR}/tempo/tempo.yaml" ]; then
  rm -rf "${INSTALL_DIR}/tempo/tempo.yaml"
fi
mkdir -p "${INSTALL_DIR}/tempo"
if [ ! -f "${INSTALL_DIR}/tempo/tempo.yaml" ]; then
  cat > "${INSTALL_DIR}/tempo/tempo.yaml" << 'TEMPOEOF'
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

ingester:
  max_block_duration: 5m

compactor:
  compaction:
    block_retention: 72h    # Keep traces for 3 days

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/blocks
    wal:
      path: /var/tempo/wal

metrics_generator:
  registry:
    external_labels:
      source: tempo
  storage:
    path: /var/tempo/generator/wal
    remote_write:
      - url: http://prometheus:9090/api/v1/write
        send_exemplars: true
TEMPOEOF
fi
# Repair Docker-created directories for Loki/Alloy/Tempo config bind mounts.
# Docker creates mount targets as directories when the source file doesn't exist.
# The actual config files are deployed via the release bundle (bundle-manifest.yml).
for _config_pair in "loki/loki.yaml" "alloy/config.alloy" "tempo/tempo.yaml" "otel-collector/otel-collector-config.yaml"; do
  _config_path="${INSTALL_DIR}/${_config_pair}"
  if [ -d "$_config_path" ]; then
    rm -rf "$_config_path"
  fi
done
# Remove file-provisioned Grafana dashboards that are now API-managed by BootProvisioner.
# Grafana rejects API writes to file-provisioned dashboards ("Cannot save provisioned dashboard").
# These dashboards are now generated dynamically per-org by the Elixir dashboard factory.
for _stale_dashboard in "calltelemetry-system-health.json" "alarm-overview.json" "oban-job-health.json"; do
  _dash_path="${INSTALL_DIR}/grafana/dashboards/${_stale_dashboard}"
  if [ -f "$_dash_path" ]; then
    rm -f "$_dash_path"
  fi
done
mkdir -p "${INSTALL_DIR}/prometheus"
ensure_prometheus_rules_file() {
  local path="$1"
  if [ -d "$path" ]; then
    rm -rf "$path"
  fi
  if [ ! -f "$path" ]; then
    echo 'groups: []' > "$path"
  fi
}
ensure_prometheus_rules_file "${INSTALL_DIR}/prometheus/alert_rules.yml"
ensure_prometheus_rules_file "${INSTALL_DIR}/prometheus/custom_rules.yml"

# --- Self-healing NetworkManager fix ---
# OVA images sometimes ship with permissions=user:root:; or autoconnect=false
# in the NM connection profile, which prevents auto-connect on boot and breaks
# DNS resolution. Fix on every cli.sh invocation so networking survives reboots.
nm_heal_connections() {
  command -v nmcli &>/dev/null || return 0
  local changed=0
  # Walk all ethernet connection files, not just the active one
  for _NM_FILE in /etc/NetworkManager/system-connections/*.nmconnection; do
    [ -f "$_NM_FILE" ] || continue
    if grep -q 'permissions=user:root:;' "$_NM_FILE" 2>/dev/null; then
      sudo sed -i 's/permissions=user:root:;//' "$_NM_FILE" 2>/dev/null
      changed=1
    fi
    if grep -q 'autoconnect=false' "$_NM_FILE" 2>/dev/null; then
      sudo sed -i 's/autoconnect=false/autoconnect=true/' "$_NM_FILE" 2>/dev/null
      changed=1
    fi
  done
  [ "$changed" = "1" ] && nmcli connection reload 2>/dev/null || true
}
nm_heal_connections

# --- Self-healing NM Docker bridge fix ---
# NetworkManager auto-creates connection profiles for Docker bridge interfaces
# (docker0, br-*, veth*) and races Docker for ownership at boot. On firewalld-
# enabled OVAs this triggers ZONE_CONFLICT and breaks container networking.
# Fix: write the conf.d unmanaged-devices rule so NM never claims these interfaces.
# Also ensure daemon.json uses the nftables firewall backend to avoid iptables/nft
# conflicts on RHEL 9 / AlmaLinux 9 OVAs.
nm_heal_docker_bridges() {
  command -v nmcli &>/dev/null || return 0
  local NM_DOCKER_CONF="/etc/NetworkManager/conf.d/docker-unmanaged.conf"
  local changed=0

  if [ ! -f "$NM_DOCKER_CONF" ]; then
    sudo tee "$NM_DOCKER_CONF" > /dev/null << 'NMDEOF'
[keyfile]
unmanaged-devices=interface-name:docker*;interface-name:br-*;interface-name:veth*
NMDEOF
    changed=1
  fi

  if [ "$changed" = "1" ]; then
    sudo nmcli general reload 2>/dev/null || true
  fi

  # Ensure daemon.json has correct bip/address-pools, and nftables backend
  # if Docker 29+ is available. Avoids iptables/nftables conflicts on RHEL 9.
  local DAEMON_JSON="/etc/docker/daemon.json"
  local docker_major
  docker_major=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)
  if [ -f "$DAEMON_JSON" ] && command -v python3 &>/dev/null; then
    if ! python3 -c "import json,sys; d=json.load(open('$DAEMON_JSON')); sys.exit(0 if (d.get('firewall-backend')=='nftables' or int('${docker_major:-0}')<29) and d.get('bip')=='100.64.0.1/24' else 1)" 2>/dev/null; then
      python3 - "$DAEMON_JSON" "${docker_major:-0}" << 'PYEOF'
import json, sys
path = sys.argv[1]
docker_major = int(sys.argv[2])
with open(path) as f:
    d = json.load(f)
changed = False
if docker_major >= 29 and d.get("firewall-backend") != "nftables":
    d["firewall-backend"] = "nftables"
    changed = True
if d.get("bip") != "100.64.0.1/24":
    d["bip"] = "100.64.0.1/24"
    d["default-address-pools"] = [{"base": "100.64.0.0/14", "size": 24}]
    changed = True
if changed:
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
PYEOF
      sudo systemctl reload-or-restart docker 2>/dev/null || true
    fi
  fi
}
nm_heal_docker_bridges

# Some Docker hosts can leave project veth interfaces detached from the Compose
# bridge after a service restart. Containers still resolve each other, but TCP
# fails with "No route to host". Reattach any orphaned project veths before
# health checks so appliance upgrades can recover without operator intervention.
# This is harmless on normal Docker hosts where masters are already correct.
repair_compose_bridge_add_candidate() {
  local -n candidates_ref="$1"
  local candidate="$2"
  local existing
  [ -n "$candidate" ] || return 0
  for existing in "${candidates_ref[@]}"; do
    [ "$existing" = "$candidate" ] && return 0
  done
  candidates_ref+=("$candidate")
}

repair_compose_bridge_once() {
  command -v docker >/dev/null 2>&1 || return 0
  command -v ip >/dev/null 2>&1 || return 0

  local network="${CT_COMPOSE_NETWORK:-calltelemetry_ct}"
  local bridge
  bridge=$(docker network inspect "$network" --format 'br-{{.Id}}' 2>/dev/null | cut -c1-15 || true)
  [ -n "$bridge" ] || return 0
  [ -d "/sys/class/net/$bridge" ] || return 0

  local changed=0
  local candidates=()

  local name endpoint prefix pid peer_ifindex path
  while read -r name endpoint; do
    [ -n "$name" ] || continue

    if [ -n "$endpoint" ]; then
      for prefix in 7 12; do
        repair_compose_bridge_add_candidate candidates "veth${endpoint:0:$prefix}"
      done
    fi

    if command -v nsenter >/dev/null 2>&1; then
      pid=$(docker inspect --format '{{.State.Pid}}' "$name" 2>/dev/null || true)
      if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ]; then
        peer_ifindex=$(nsenter -t "$pid" -n ip -o link show eth0 2>/dev/null | sed -n 's/.*@if\([0-9][0-9]*\):.*/\1/p' | head -1)
        if [ -n "$peer_ifindex" ]; then
          for path in /sys/class/net/veth*; do
            [ -e "$path" ] || continue
            [ "$(cat "$path/ifindex" 2>/dev/null || true)" = "$peer_ifindex" ] && repair_compose_bridge_add_candidate candidates "${path##*/}"
          done
        fi
      fi
    fi
  done < <(docker network inspect "$network" --format '{{range .Containers}}{{printf "%s %s\n" .Name .EndpointID}}{{end}}' 2>/dev/null)

  local iface master master_link
  for iface in "${candidates[@]}"; do
    path="/sys/class/net/$iface"
    [ -e "$path" ] || continue
    master_link=$(readlink "$path/master" 2>/dev/null || true)
    master=""
    [ -n "$master_link" ] && master=$(basename "$master_link")
    [ "$master" = "$bridge" ] && continue
    [ -n "$master" ] && continue

    if ip link set dev "$iface" master "$bridge" 2>/dev/null; then
      ip link set dev "$iface" up 2>/dev/null || true
      changed=1
    fi
  done

  ip link set dev "$bridge" up 2>/dev/null || true
  [ "$changed" -eq 1 ] && log_verbose_ok "Repaired Docker bridge attachments on $bridge"
}

# PostgreSQL version configuration
POSTGRES_OVERRIDE_FILE="docker-compose.override.yml"
POSTGRES_DEFAULT_VERSION="17"
POSTGRES_SUPPORTED_VERSIONS="14 15 16 17 18"
POSTGRES_OVERRIDE_URL="${GCS_BASE_URL}"

# Get current PostgreSQL version from override file, or default
get_postgres_version() {
  if [ -f "$POSTGRES_OVERRIDE_FILE" ]; then
    # Extract version from calltelemetry/postgres:XX image line
    local version=$(grep -o 'calltelemetry/postgres:[0-9]\+' "$POSTGRES_OVERRIDE_FILE" | grep -o '[0-9]\+$')
    if [ -n "$version" ]; then
      echo "$version"
      return
    fi
  fi
  echo "$POSTGRES_DEFAULT_VERSION"
}

# Set PostgreSQL version by downloading override file
set_postgres_version() {
  local version="$1"
  if ! echo "$POSTGRES_SUPPORTED_VERSIONS" | grep -qw "$version"; then
    echo "Invalid PostgreSQL version: $version"
    echo "Supported versions: $POSTGRES_SUPPORTED_VERSIONS"
    return 1
  fi

  local override_url="${POSTGRES_OVERRIDE_URL}/postgres-${version}.yaml"

  echo "Downloading PostgreSQL $version override..."
  if wget -q "$override_url" -O "$POSTGRES_OVERRIDE_FILE"; then
    echo "PostgreSQL version set to $version"
    echo "Override file: $POSTGRES_OVERRIDE_FILE"
    return 0
  else
    echo "Failed to download override file from: $override_url"
    return 1
  fi
}

# Get current PostgreSQL image (checks override first, then main compose)
get_current_postgres_image() {
  # Check override file first
  if [ -f "$POSTGRES_OVERRIDE_FILE" ]; then
    local override_image=$(grep -o 'image: *"[^"]*"' "$POSTGRES_OVERRIDE_FILE" | head -1 | sed 's/image: *"\([^"]*\)"/\1/')
    if [ -n "$override_image" ]; then
      echo "$override_image"
      return
    fi
  fi
  # Fall back to main compose file
  if [ -f "$ORIGINAL_FILE" ]; then
    grep -A1 "^  db:" "$ORIGINAL_FILE" | grep "image:" | sed 's/.*image: *"\?\([^"]*\)"\?.*/\1/' | head -1
  else
    echo "unknown"
  fi
}

POSTGRES_COMPAT_SCRIPT="postgres-bitnami-convert.sh"

resolve_latest_ct_media_go_version() {
  local hub_api="https://hub.docker.com/v2/repositories/calltelemetry/ct-media-go/tags?page_size=100"
  local tags=""

  if command -v curl >/dev/null 2>&1; then
    tags=$(curl -fsSL "$hub_api" 2>/dev/null | grep -o '"name":"[^"]*"' | sed 's/"name":"\([^"]*\)"/\1/')
  elif command -v wget >/dev/null 2>&1; then
    tags=$(wget -qO- "$hub_api" 2>/dev/null | grep -o '"name":"[^"]*"' | sed 's/"name":"\([^"]*\)"/\1/')
  fi

  local tag
  tag=$(printf '%s\n' "$tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  if echo "$tag" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$tag"
    return 0
  fi

  return 1
}

normalize_ct_media_bundle() {
  local appliance_version="$1"
  local current_media_version
  current_media_version="$(env_get "CT_MEDIA_VERSION")"

  local legacy_image=false
  if grep -q 'calltelemetry/ct-media:' "$TEMP_FILE" 2>/dev/null; then
    legacy_image=true
  fi

  local legacy_version=false
  if [ -z "$current_media_version" ] || echo "$current_media_version" | grep -q -- '-rc'; then
    legacy_version=true
  fi

  if [ "$legacy_image" = false ] && [ "$legacy_version" = false ]; then
    return 0
  fi

  local replacement_version=""
  if ! replacement_version="$(resolve_latest_ct_media_go_version)"; then
    log_fail "Legacy ct-media bundle detected, but failed to resolve the latest ct-media-go release."
    echo "   Please set CT_MEDIA_VERSION manually to a valid ct-media-go semver release and retry."
    return 1
  fi

  echo "Normalizing legacy media bundle references to ct-media-go:${replacement_version}..."
  env_set "CT_MEDIA_VERSION" "$replacement_version"

  if grep -q 'calltelemetry/ct-media:' "$TEMP_FILE" 2>/dev/null; then
    sed -i -E "s|calltelemetry/ct-media:[^\"[:space:]]*|calltelemetry/ct-media-go:${replacement_version}|g" "$TEMP_FILE"
  fi

  if grep -q 'calltelemetry/ct-media-go:' "$TEMP_FILE" 2>/dev/null; then
    sed -i -E "s|calltelemetry/ct-media-go:[^\"[:space:]]*|calltelemetry/ct-media-go:${replacement_version}|g" "$TEMP_FILE"
  fi

  if grep -q 'calltelemetry/ct-media-go:\${CT_MEDIA_VERSION' "$TEMP_FILE" 2>/dev/null; then
    :
  fi

  log_ok "Legacy media references upgraded for appliance ${appliance_version}"
}

# Repair missing PostgreSQL config files in existing data dirs created by older
# appliance/database image combinations. Only missing files are restored.
repair_postgres_compat() {
  local pg_data="${INSTALL_DIR}/${POSTGRES_DATA_DIR}/data"
  local image="${1:-$(get_current_postgres_image)}"
  shift || true

  if [ ! -f "${pg_data}/PG_VERSION" ]; then
    return 0
  fi

  if [ -f "${pg_data}/postgresql.conf" ] && [ -f "${pg_data}/pg_hba.conf" ] && [ -f "${pg_data}/pg_ident.conf" ]; then
    return 0
  fi

  # Search INSTALL_DIR, then next to cli.sh. We deliberately do NOT search
  # PWD: this function may run under sudo/root and executing an arbitrary
  # helper from a user-controlled CWD is a local-privilege-escalation risk.
  # download_bundle places the helper in INSTALL_DIR, so the trusted paths
  # are sufficient under normal operation.
  #
  # Resolve CURRENT_SCRIPT_PATH to an absolute path before taking dirname, so
  # the script_dir fallback works even when cli.sh was invoked via a relative
  # path or bare name on $PATH.
  local repair_script=""
  local script_dir=""
  local resolved_script_path=""
  if [ -n "${CURRENT_SCRIPT_PATH:-}" ]; then
    if command -v realpath >/dev/null 2>&1; then
      resolved_script_path="$(realpath "$CURRENT_SCRIPT_PATH" 2>/dev/null)" || resolved_script_path=""
    elif command -v readlink >/dev/null 2>&1; then
      resolved_script_path="$(readlink -f "$CURRENT_SCRIPT_PATH" 2>/dev/null)" || resolved_script_path=""
    fi
    if [ -z "$resolved_script_path" ]; then
      case "$CURRENT_SCRIPT_PATH" in
        /*) resolved_script_path="$CURRENT_SCRIPT_PATH" ;;
        */*) resolved_script_path="$(cd "$(dirname "$CURRENT_SCRIPT_PATH")" 2>/dev/null && pwd)/$(basename "$CURRENT_SCRIPT_PATH")" || resolved_script_path="" ;;
        *) resolved_script_path="$(command -v -- "$CURRENT_SCRIPT_PATH" 2>/dev/null)" || resolved_script_path="" ;;
      esac
    fi
    if [ -n "$resolved_script_path" ]; then
      script_dir="$(cd "$(dirname "$resolved_script_path")" 2>/dev/null && pwd)" || script_dir=""
    fi
  fi

  for candidate in \
    "${INSTALL_DIR}/${POSTGRES_COMPAT_SCRIPT}" \
    "${script_dir:+${script_dir}/${POSTGRES_COMPAT_SCRIPT}}"; do
    [ -z "$candidate" ] && continue
    if [ -f "$candidate" ]; then
      repair_script="$candidate"
      break
    fi
  done

  if [ -z "$repair_script" ]; then
    log_warn "PostgreSQL compatibility repair helper needed but not found in ${INSTALL_DIR}${script_dir:+ or ${script_dir}}."
    echo "       Data directory is missing canonical config files (postgresql.conf / pg_hba.conf / pg_ident.conf);"
    echo "       startup or migrations may fail. Re-run the upgrade with a bundle that includes"
    echo "       ${POSTGRES_COMPAT_SCRIPT}, or install it manually into ${INSTALL_DIR} and re-run."
    return 0
  fi

  chmod +x "$repair_script" 2>/dev/null || true

  echo "Repairing missing PostgreSQL config files in ${pg_data} (helper: ${repair_script})..."
  if bash "$repair_script" --image "$image" --data-dir "$pg_data" "$@"; then
    return 0
  fi

  log_fail "PostgreSQL compatibility repair failed."
  echo "   Run manually: ${repair_script} --image ${image} --data-dir ${pg_data}"
  return 1
}

# TimescaleDB preload handling is now owned by the ct-docker postgres image
# (shared_preload_libraries baked into postgresql.conf.sample) plus the
# compose command-line override (`-c shared_preload_libraries='timescaledb'`).
# The old `ensure_timescale_preload_config` helper
# used to sed-patch stale bundles and drifted postgres-data/postgresql.conf
# files — that class of drift no longer exists on any bundle we ship, so the
# helper has been removed.
#
# We still verify at runtime — it's a cheap belt-and-suspenders check that
# catches the case where something unexpectedly stripped the command-line
# override (custom docker-compose.override.yml, swapped base image, etc.).
# The check is silent on success — operators only hear about it when it
# fails, in which case migrations would fail anyway and the clear message
# here saves a lot of debugging.
# TimescaleDB preload is guaranteed by the bundle's docker-compose.yml:
#
#   command: >
#     postgres
#     -c shared_preload_libraries='timescaledb'
#
# This flag is passed directly to the postgres binary on container start.
# If the image can't load timescale (wrong base image, missing extension,
# etc.), postgres fails startup and compose reports the container unhealthy
# via its built-in healthcheck (pg_isready). There's no way for the
# container to be "up" without the preload applied — the preload IS the
# command.
#
# The old `verify_timescale_runtime_preload` helper tried to verify preload
# by shelling in with psql and reading SHOW shared_preload_libraries. In
# practice that polling loop ate 120s silently whenever psql didn't respond
# fast enough (slow WAL replay, auth race, custom POSTGRES_USER, etc.),
# failed with "Current value: unavailable", and aborted the upgrade on
# appliances that were actually healthy. The resulting partial upgrade left
# migrations un-applied — much worse than the problem the guard tried to
# prevent. Retired.
#
# If timescale really is missing at runtime, migrations themselves will
# fail fast with a clear hypertable error — much more actionable than the
# old guard's opaque "unavailable" message.

# JTAPI feature state — now driven by COMPOSE_PROFILES in .env
JTAPI_STATE_FILE=".jtapi-enabled"
ENV_FILE="${INSTALL_DIR}/.env"

# Restore .env ownership to the install user after a root-mode write.
# Without this, `sudo cli.sh jtapi enable` (or any other sudo path that
# calls env_set/env_remove) leaves .env owned by root, which then breaks
# the next non-root command that needs to update it (e.g. `storage
# enable`, `otel enable`, `logging <level>`).
#
# Uses INSTALL_USER (resolved from the detected appliance directory at
# script top) rather than SUDO_USER. SUDO_USER reflects whichever admin
# ran sudo, which may differ from the actual install owner — chowning to
# that admin could lock the true owner out of later non-root edits.
# No-op when not root, and chown failures are swallowed.
_env_restore_owner() {
  [ -f "$ENV_FILE" ] || return 0
  if [ "$(id -u)" -eq 0 ] && [ -n "${INSTALL_USER:-}" ]; then
    local install_group
    install_group=$(id -gn "$INSTALL_USER" 2>/dev/null || true)
    chown "${INSTALL_USER}${install_group:+:$install_group}" "$ENV_FILE" 2>/dev/null || true
  fi
}

# Read a key from .env (returns empty string if not found).
# Tolerates legacy indented entries (older bundles wrote leading-space
# headers) and returns the LAST matching value — env_set always appends,
# so the tail wins over any stale indented duplicate.
env_get() {
  local key="$1"
  if [ -f "$ENV_FILE" ]; then
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" 2>/dev/null \
      | tail -1 \
      | sed -E "s/^[[:space:]]*${key}[[:space:]]*=//"
  fi
}

# Set or update a key in .env (creates file if needed).
# Deletes ALL existing entries for the key (including indented or
# whitespace-prefixed legacy entries) then appends the canonical form.
# This prevents silent duplicates when upgrading from older bundles
# that shipped an indented header block. Restores INSTALL_USER ownership
# when invoked as root so later non-root commands can still edit .env.
env_set() {
  local key="$1" value="$2"
  if [ ! -f "$ENV_FILE" ]; then
    echo "${key}=${value}" > "$ENV_FILE"
    _env_restore_owner
    return
  fi
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" 2>/dev/null; then
    sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$ENV_FILE"
  fi
  echo "${key}=${value}" >> "$ENV_FILE"
  _env_restore_owner
}

# Set a key in .env only if it is not already set (no-clobber)
env_set_default() {
  local key="$1" value="$2"
  if [ -z "$(env_get "$key")" ]; then
    env_set "$key" "$value"
  fi
}

# POSTGRES_PASSWORD handling during upgrade is safety-critical.
#
# Legacy compose files (rc266 and earlier) used `${POSTGRES_PASSWORD:-postgres}`,
# so appliances that never set POSTGRES_PASSWORD in .env were initdb'd with
# the literal string "postgres". New compose files drop the fallback
# (`${POSTGRES_PASSWORD:?required}`) and will refuse to start without the
# value in .env.
#
# Strategy on upgrade: adopt, don't rotate.
# Rotating the DB password mid-upgrade was too brittle — it added another
# moving part (ALTER USER must land before the compose restart, with every
# consumer picking up the new value in sync) and we don't have a clean
# transaction boundary across those layers. Instead we simply record the
# *current* working password into .env so the new compose can interpolate it;
# the DB and its stored hashes are left untouched. Operators who want to
# replace the legacy "postgres" default with a random value can do so
# explicitly via a dedicated rotate command after the upgrade settles.
#
# Behavior:
#   - If POSTGRES_PASSWORD is already set in .env: keep it (customer value wins).
#   - Else if a postgres data volume exists AND the legacy default "postgres"
#     still authenticates: write POSTGRES_PASSWORD=postgres into .env and
#     surface a note recommending a later rotate.
#   - Else if a postgres data volume exists but "postgres" does NOT auth:
#     refuse to overwrite .env. The operator must set POSTGRES_PASSWORD
#     manually to the existing DB password, then re-run update.
#   - Else (no DB volume — fresh install): generate a random password.
ensure_postgres_password() {
  if [ -n "$(env_get POSTGRES_PASSWORD)" ]; then
    return 0
  fi

  local pg_data_dir="${INSTALL_DIR}/${POSTGRES_DATA_DIR}/data"
  if [ -f "${pg_data_dir}/PG_VERSION" ]; then
    # Existing install — adopt the working password into .env; DO NOT rotate.
    # Distinguish "db container not running" from "auth failed" before we
    # blame the legacy password — the two conditions have different
    # recovery paths and conflating them produces misleading errors.
    if [ -z "$(_find_running_db_container)" ]; then
      log_fail "POSTGRES_PASSWORD is not set in ${ENV_FILE}, and the db"
      echo "       container is not running — cli.sh cannot probe for the"
      echo "       legacy default. Start the stack (cli.sh start / restart)"
      echo "       and re-run update, or set POSTGRES_PASSWORD in"
      echo "       ${ENV_FILE} manually to the existing DB password."
      return 1
    fi
    if _postgres_auth_works "postgres"; then
      env_set "POSTGRES_PASSWORD" "postgres"
      log_ok "Adopted legacy DB password into .env (${ENV_FILE})"
      echo "     The DB role was not modified. Consider rotating the weak"
      echo "     default later — see 'cli.sh help' for the rotate command."
      return 0
    fi
    log_fail "POSTGRES_PASSWORD is not set in ${ENV_FILE} and the legacy"
    echo "       default 'postgres' does not authenticate against the running"
    echo "       database (db container is up but the password was already"
    echo "       changed). Set POSTGRES_PASSWORD in ${ENV_FILE} to the current"
    echo "       DB password and re-run update. cli.sh will not guess or"
    echo "       rewrite this value because doing so would break auth."
    return 1
  fi

  # Fresh install — no PG data yet — generate a random password.
  local pg_pw
  if ! pg_pw=$(generate_secret_hex 16); then
    return 1
  fi
  env_set "POSTGRES_PASSWORD" "$pg_pw"
}

ensure_grafana_password() {
  if [ -n "$(env_get GRAFANA_PASSWORD)" ]; then
    return 0
  fi

  local gf_pw
  if ! gf_pw=$(generate_secret_hex 16); then
    return 1
  fi

  env_set "GRAFANA_PASSWORD" "$gf_pw"
  env_remove "GRAFANA_TOKEN"
  CT_GRAFANA_PASSWORD_WAS_GENERATED=1
  log_ok "Generated GRAFANA_PASSWORD"
}

__test_ensure_grafana_password() {
  local old_env_file="${ENV_FILE:-}"
  local tmp_env first_pw second_pw

  tmp_env=$(mktemp) || return 1
  ENV_FILE="$tmp_env"
  printf 'GRAFANA_TOKEN=stale-token\n' >"$ENV_FILE"

  if ! ensure_grafana_password; then
    ENV_FILE="$old_env_file"
    rm -f "$tmp_env"
    return 1
  fi

  first_pw="$(env_get GRAFANA_PASSWORD)"
  if [ -z "$first_pw" ]; then
    echo "__test_ensure_grafana_password: GRAFANA_PASSWORD was not generated"
    ENV_FILE="$old_env_file"
    rm -f "$tmp_env"
    return 1
  fi

  if [ -n "$(env_get GRAFANA_TOKEN)" ]; then
    echo "__test_ensure_grafana_password: GRAFANA_TOKEN was not removed"
    ENV_FILE="$old_env_file"
    rm -f "$tmp_env"
    return 1
  fi

  if ! ensure_grafana_password; then
    ENV_FILE="$old_env_file"
    rm -f "$tmp_env"
    return 1
  fi

  second_pw="$(env_get GRAFANA_PASSWORD)"
  if [ "$first_pw" != "$second_pw" ]; then
    echo "__test_ensure_grafana_password: GRAFANA_PASSWORD was regenerated"
    ENV_FILE="$old_env_file"
    rm -f "$tmp_env"
    return 1
  fi

  printf 'GRAFANA_PASSWORD=%s\n' "$first_pw"
  printf 'CT_GRAFANA_PASSWORD_WAS_GENERATED=%s\n' "${CT_GRAFANA_PASSWORD_WAS_GENERATED:-0}"
  ENV_FILE="$old_env_file"
  rm -f "$tmp_env"
}

generate_secret_hex() {
  local bytes="${1:-16}"
  local secret=""

  if command -v openssl >/dev/null 2>&1; then
    secret=$(openssl rand -hex "$bytes" 2>/dev/null || true)
  fi

  if [ -z "$secret" ] && command -v python3 >/dev/null 2>&1; then
    secret=$(python3 - "$bytes" <<'PY' 2>/dev/null || true
import secrets
import sys

print(secrets.token_hex(int(sys.argv[1])))
PY
)
  fi

  if [ -z "$secret" ]; then
    log_fail "Unable to generate a secure secret; install openssl or python3 and retry."
    return 1
  fi

  printf '%s' "$secret"
}

# Find the currently-running db container by its compose service label.
# Avoids `docker compose ps` / `docker compose exec` because those validate
# the full compose file, which may reference env vars (e.g. POSTGRES_PASSWORD
# under `${...:?required}`) that are not yet present in .env during the
# ensure_postgres_password rotation path — the exact failure mode this
# function has to operate inside. Returns the container ID or empty string.
_find_running_db_container() {
  docker ps \
    --filter 'label=com.docker.compose.service=db' \
    --filter 'status=running' \
    --format '{{.ID}}' 2>/dev/null | head -1
}

# Probe whether the `calltelemetry` role currently authenticates to the running
# db container with the given password. Returns 0 on success, non-zero on any
# auth failure (or if the db container is not running / not reachable).
# Uses direct `docker exec` so it works regardless of compose-file validity.
_postgres_auth_works() {
  local candidate_pw="$1"
  [ -n "$candidate_pw" ] || return 1
  local cid
  cid=$(_find_running_db_container)
  [ -n "$cid" ] || return 1
  # TCP auth (-h db) — Unix-socket auth would often pass via pg_hba `trust`
  # and mask a real password mismatch, so we deliberately go via TCP.
  docker exec -e PGPASSWORD="$candidate_pw" "$cid" \
    psql -h db -U calltelemetry -d calltelemetry_prod -Atc 'select 1' \
    >/dev/null 2>&1
}

# Return the POSTGRES_PASSWORD cli.sh should use for its own psql/pg_dump
# invocations against the running db container. Single source of truth:
# whatever is in .env. Never falls back to "postgres" — ensure_postgres_password
# is responsible for making sure .env has a value before any caller needs it
# (it runs in ensure_postgres_defaults at the top of `update`, and
# independently in `postgres profile` and `storage enable`). A missing value
# here means ensure_postgres_password either wasn't called yet or was
# deliberately refused (existing DB whose password we don't know); in either
# case, silently falling back to "postgres" would paper over a real problem.
# Callers that empty-check the output can decide whether to abort or prompt.
_db_password() {
  env_get POSTGRES_PASSWORD
}

# Pull a docker image with a compact progress indicator.
# Replaces `docker pull "$img"` whose default output streams a layer-by-layer
# progress bar that dominates the upgrade log. We want one line per image:
#
#   Downloading calltelemetry/web:0.8.6-rc269 ....... done
#
# plus a single error trailer if it fails. The underlying pull is still
# `docker pull --quiet` so any exit status, network error, or manifest
# problem is preserved — we just keep stdout manageable.
install_user_home_for_update() {
  [ -n "${INSTALL_USER:-}" ] || return 1
  [ "$INSTALL_USER" != "root" ] || return 1
  getent passwd "$INSTALL_USER" 2>/dev/null | cut -d: -f6
}

docker_config_uses_credential_helper() {
  local docker_config_dir="$1"
  [ -n "$docker_config_dir" ] || return 1
  [ -f "${docker_config_dir}/config.json" ] || return 1
  grep -Eq '"credsStore"[[:space:]]*:|"credHelpers"[[:space:]]*:' "${docker_config_dir}/config.json" 2>/dev/null
}

run_docker_client_for_update() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${INSTALL_USER:-}" ] && [ "$INSTALL_USER" != "root" ]; then
    local install_home
    install_home=$(install_user_home_for_update || true)
    if [ -n "$install_home" ] && [ -d "$install_home" ]; then
      if docker_config_uses_credential_helper "${install_home}/.docker"; then
        "$@"
        return $?
      fi
      HOME="$install_home" DOCKER_CONFIG="${install_home}/.docker" "$@"
      return $?
    fi
  fi
  "$@"
}

# Login/logout do not need Docker daemon socket access. Keep auth under the
# install user's credential-helper context so helper-backed Docker configs work.
run_docker_auth_for_update() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${INSTALL_USER:-}" ] && [ "$INSTALL_USER" != "root" ]; then
    local install_home
    install_home=$(install_user_home_for_update || true)
    if [ -n "$install_home" ] && [ -d "$install_home" ]; then
      sudo -u "$INSTALL_USER" env HOME="$install_home" DOCKER_CONFIG="${install_home}/.docker" "$@"
      return $?
    fi
  fi
  "$@"
}

pull_image_quiet() {
  local img="$1"
  [ -n "$img" ] || return 1
  printf "  Downloading %s " "$img"
  local log rc pid
  log=$(mktemp 2>/dev/null || echo "/tmp/pull-$$-${RANDOM}.log")
  ( run_docker_client_for_update docker pull --quiet "$img" >"$log" 2>&1 ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf "."
    sleep 1
  done
  wait "$pid"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf " done\n"
    rm -f "$log"
  else
    printf " FAIL\n"
    # Surface just the failure lines, not the whole progress log.
    grep -E "Error|error|denied|not found|unauthorized|timeout|rate limit" "$log" 2>/dev/null | head -5
  fi
  PULL_IMAGE_LAST_LOG="$log"
  return "$rc"
}

docker_for_pulls() {
  # Use the install user's docker config (credentials/registry-mirror) but
  # keep root daemon access. sudo -u INSTALL_USER would break on appliances
  # where that user is not a member of the docker group, regressing the
  # digest-pinned tag/inspect path after a successful pull.
  run_docker_client_for_update docker "$@"
}

_image_digest_manifest_path() {
  echo "${INSTALL_DIR}/image-digests.tsv"
}

_image_digest_manifest_tmp_path() {
  echo "${INSTALL_DIR}/image-digests.tsv.tmp"
}

_pull_image_at_digest() {
  local image="$1" digest="$2"
  local pinned_ref="${image%@*}@${digest}"

  if ! pull_image_quiet "$pinned_ref"; then
    return 1
  fi

  if ! docker_for_pulls tag "$pinned_ref" "$image" >/dev/null 2>&1; then
    log_fail "Failed to tag verified image ${pinned_ref} as ${image}"
    return 1
  fi

  if ! docker_for_pulls image inspect "$image" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null | grep -F "@${digest}" >/dev/null; then
    log_fail "Digest verification failed for ${image}; expected ${digest}"
    return 1
  fi

  return 0
}

docker_login_for_pulls() {
  local username="$1"
  local token="$2"
  printf '%s' "$token" | run_docker_auth_for_update docker login -u "$username" --password-stdin
}

docker_logout_for_pulls() {
  run_docker_auth_for_update docker logout
}

compose_pull_for_update() {
  local compose_file="$1"
  run_docker_client_for_update $DOCKER_COMPOSE_CMD -f "$compose_file" pull --quiet
}

should_refresh_service_image() {
  case "$1" in
    calltelemetry/*|docker.io/calltelemetry/*|index.docker.io/calltelemetry/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

image_pull_failure_kind() {
  local log="${1:-}"
  [ -n "$log" ] || return 1

  if grep -Eqi "permission denied while trying to connect to the Docker daemon|dial unix .*docker\\.sock.*permission denied|docker daemon socket.*permission denied" "$log" 2>/dev/null; then
    echo "docker_permission"
  elif grep -Eqi "cannot connect to the docker daemon|is the docker daemon running|dial unix .*docker\\.sock.*(connect: no such file|connect: connection refused)" "$log" 2>/dev/null; then
    echo "docker_unreachable"
  elif grep -Eqi "rate limit|toomanyrequests" "$log" 2>/dev/null; then
    echo "rate_limit"
  elif grep -Eqi "unauthorized|denied|authentication required" "$log" 2>/dev/null; then
    echo "registry_auth"
  elif grep -Eqi "not found|manifest unknown" "$log" 2>/dev/null; then
    echo "not_found"
  elif grep -Eqi "timeout|timed out" "$log" 2>/dev/null; then
    echo "timeout"
  else
    return 1
  fi
}

print_image_pull_failure() {
  local img="$1" log="${2:-}"
  local reason="Docker could not download the required service image."
  local next_step="Check registry access and retry the update."
  local failure_kind
  failure_kind=$(image_pull_failure_kind "$log" || true)

  if [ "$failure_kind" = "rate_limit" ]; then
    reason="Docker Hub pull rate limit reached while downloading $img."
    next_step="Log in to Docker Hub, then retry the update."
  elif [ "$failure_kind" = "docker_permission" ]; then
    reason="Docker could not access the local Docker daemon while downloading $img."
    next_step="Verify /var/run/docker.sock access for the update process (permissions, ACLs, or SELinux), then retry the update."
  elif [ "$failure_kind" = "docker_unreachable" ]; then
    reason="The local Docker daemon was unreachable while downloading $img."
    next_step="Start or repair the Docker daemon, then retry the update."
  elif [ "$failure_kind" = "registry_auth" ]; then
    reason="Docker registry authentication failed while downloading $img."
    next_step="Verify Docker Hub credentials, then retry the update."
  elif [ "$failure_kind" = "not_found" ]; then
    reason="The image $img was not found in the registry."
    next_step="Verify the release image was published, then retry the update."
  elif [ "$failure_kind" = "timeout" ]; then
    reason="The registry request timed out while downloading $img."
    next_step="Check network access to Docker Hub, then retry the update."
  fi

  print_failure_card \
    "Could not download required service image" \
    "$reason" \
    "The update did not complete." \
    "$next_step" \
    "${log:-not available}"
}

# Suggest the cli.sh subcommands most relevant to the phase that failed.
# Emits 4–8 lines of targeted next-steps so the operator doesn't have to
# re-read the full help to find the right tool. The always-useful ones
# (status, logs) are shown first; phase-specific suggestions follow.
# $1 = failed_phases string (space-separated: containers database migrations
#      health-check traceroute-health rpc stale-compose)
_print_troubleshoot_suggestions() {
  local phases=" $1 "
  local script="${CURRENT_SCRIPT_PATH:-cli.sh}"

  echo "  Next steps — relevant cli.sh commands:"
  echo ""
  echo "    ${script} status              App + container health summary"
  echo "    ${script} docker              Container / image / network state"

  if [[ "$phases" == *" containers "* || "$phases" == *" stale-compose "* ]]; then
    echo "    ${script} logs <service> --tail 100    (services listed by 'status')"
    if [[ "$phases" == *" stale-compose "* ]]; then
      echo "    ${script} update              Re-pull the current release bundle"
      echo "    ${script} rollback            Restore previous docker-compose.yml"
    fi
  fi

  if [[ "$phases" == *" database "* ]]; then
    echo ""
    echo "    ${script} db                  Database status (connections, size)"
    echo "    ${script} logs db --tail 100  Recent postgres errors"
    echo "    ${script} db size             Disk space / bloat summary"
  fi

  if [[ "$phases" == *" migrations "* ]]; then
    echo ""
    echo "    ${script} migrate             Pending vs applied migration summary"
    echo "    ${script} migrate history     Last 10 applied migrations"
    echo "    ${script} migrate watch       Live migration progress"
    echo "    ${script} logs web --tail 200 Web container logs (migration errors"
    echo "                                  surface here as Postgrex/Ecto traces)"
  fi

  if [[ "$phases" == *" health-check "* || "$phases" == *" rpc "* ]]; then
    echo ""
    echo "    ${script} logs web --tail 200 Web boot / health errors"
    echo "    ${script} status              Re-check after a minute — app boot"
    echo "                                  can take 2–3 min after migrations"
  fi

  if [[ "$phases" == *" traceroute-health "* ]]; then
    echo ""
    echo "    ${script} logs traceroute --tail 100   Traceroute service logs"
  fi

  # If jtapi is opted in, surface its dedicated troubleshoot helper.
  if is_jtapi_enabled 2>/dev/null; then
    echo ""
    echo "    ${script} jtapi troubleshoot  Full JTAPI diagnostic pass"
    echo "                                  (CTI login, BIB registration, media)"
  fi

  # Recovery knobs, always worth knowing about.
  echo ""
  echo "  If the failure persists:"
  echo "    ${script} rollback            Revert to the previous compose"
  echo "    ${script} restart             Full docker compose down/up cycle"
}

# Collect a full-state snapshot when an upgrade / startup fails, write it to
# a timestamped file under INSTALL_DIR, and point the operator at support.
#
# Runs on a best-effort basis — every section is wrapped so a broken
# container can't prevent the rest of the log from being written. Secret
# values in .env are replaced with `<redacted>`; variable NAMES are preserved
# because they reveal which features are enabled (COMPOSE_PROFILES, etc.).
#
# $1 = short reason string (e.g. "container startup timed out")
# $2 = space-separated failed phase tokens (for targeted suggestions)
collect_upgrade_diagnostics() {
  local reason="${1:-unspecified upgrade failure}"
  local phases="${2:-}"
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local dump="${INSTALL_DIR}/upgrade-diag-${ts}.log"
  local db_cid web_cid
  db_cid=$($DOCKER_COMPOSE_CMD ps -q db 2>/dev/null | head -1)
  web_cid=$($DOCKER_COMPOSE_CMD ps -q web 2>/dev/null | head -1)

  # Each helper wraps a command in a titled block that survives failures.
  _diag_section() {
    local title="$1"; shift
    echo ""
    echo "=== ${title} ==="
    "$@" 2>&1 || echo "[section failed: $*]"
  }

  # Redact values of sensitive env keys in `docker inspect` Env output.
  _diag_redact_env() {
    sed -E 's/((PASSWORD|TOKEN|SECRET|API_KEY|DATABASE_URL|CONNECTION_STRING|COOKIE|PRIVATE_KEY)[A-Z0-9_]*=)[^ ]*/\1<redacted>/gI'
  }

  # All psql-based sections share this wrapper; we only exec into db if it is
  # up, otherwise we emit a clear skip marker.
  _diag_psql() {
    local label="$1" sql="$2"
    _diag_section "$label" sh -c "
      if [ -n '${db_cid}' ]; then
        ${DOCKER_COMPOSE_CMD} exec -T -e PGPASSWORD='$(_db_password)' db \
          psql -h db -U calltelemetry -d calltelemetry_prod -c \"${sql}\" 2>&1
      else
        echo '(db container not running — skipped)'
      fi"
  }

  {
    echo "CallTelemetry upgrade diagnostic"
    echo "Generated:   $(date -Iseconds 2>/dev/null || date)"
    echo "Reason:      ${reason}"
    echo "Phases:      ${phases:-(unspecified)}"
    echo "Host:        $(hostname 2>/dev/null)"
    echo "Kernel:      $(uname -a 2>/dev/null)"
    echo "INSTALL_DIR: ${INSTALL_DIR}"
    echo "cli.sh:      ${CURRENT_SCRIPT_PATH} (version ${CLI_VERSION})"
    echo "Compose:     ${DOCKER_COMPOSE_CMD}"

    # -----------------------------------------------------------------
    # Host / OS state
    # -----------------------------------------------------------------
    _diag_section "/etc/os-release" sh -c "cat /etc/os-release 2>/dev/null | head -10 || echo '(no /etc/os-release)'"

    _diag_section "uptime + load" uptime

    _diag_section "time / clock sync" sh -c "timedatectl status 2>/dev/null | head -12 || date"

    _diag_section "SELinux state" sh -c "command -v getenforce >/dev/null 2>&1 && getenforce || echo '(SELinux not installed)'"

    _diag_section "disk free (root + install dir)" sh -c "df -h / '${INSTALL_DIR}' 2>/dev/null | sort -u"

    _diag_section "memory" free -h

    _diag_section "listening TCP ports (postgres/web/caddy/seaweed)" sh -c "
      if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk '{print \$4}' | grep -E ':(4080|5432|80|443|8080|9333|9000)\$' | sort -u
      elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -E ':(4080|5432|80|443|8080|9333|9000) '
      else
        echo '(neither ss nor netstat available)'
      fi"

    # -----------------------------------------------------------------
    # CallTelemetry config
    # -----------------------------------------------------------------
    _diag_section ".env (keys only, values redacted)" sh -c "
      if [ -f '${ENV_FILE}' ]; then
        awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print \$1\"=<redacted>\"}' '${ENV_FILE}'
      else
        echo '(no .env at ${ENV_FILE})'
      fi"

    _diag_section "COMPOSE_PROFILES" sh -c "grep -E '^COMPOSE_PROFILES=' '${ENV_FILE}' 2>/dev/null || echo '(not set — no opt-in profiles active)'"

    _diag_section "compose / env / cli.sh fingerprint" sh -c "
      for f in '${INSTALL_DIR}/docker-compose.yml' '${ENV_FILE}' '${CURRENT_SCRIPT_PATH}'; do
        if [ -f \"\$f\" ]; then
          printf '%s  %s  %s\n' \"\$(sha256sum \"\$f\" 2>/dev/null | cut -c1-16)\" \
            \"\$(stat -c '%s %y' \"\$f\" 2>/dev/null)\" \"\$f\"
        fi
      done"

    _diag_section "recent compose backups (rollback candidates)" sh -c "
      ls -latr '${INSTALL_DIR}/backups/' 2>/dev/null \
        | grep -E 'docker-compose-[0-9]{4}' | tail -10 \
        || echo '(no compose backups under ${INSTALL_DIR}/backups/)'"

    _diag_section "full rendered compose (secrets redacted)" sh -c "
      COMPOSE_PROFILES=\"\$(grep -E '^COMPOSE_PROFILES=' '${ENV_FILE}' 2>/dev/null | tail -1 | cut -d= -f2-)\" \
        ${DOCKER_COMPOSE_CMD} $(get_compose_files) config 2>&1 \
        | sed -E 's/((PASSWORD|TOKEN|SECRET|API_KEY|COOKIE|PRIVATE_KEY)[A-Za-z0-9_]*[:=]\\s?)[^[:space:]]+/\\1<redacted>/gI'"

    _diag_section "compose services (active profiles applied)" sh -c "
      COMPOSE_PROFILES=\"\$(grep -E '^COMPOSE_PROFILES=' '${ENV_FILE}' 2>/dev/null | tail -1 | cut -d= -f2-)\" \
        ${DOCKER_COMPOSE_CMD} $(get_compose_files) config --services 2>&1"

    # -----------------------------------------------------------------
    # Docker engine state
    # -----------------------------------------------------------------
    _diag_section "docker version" sh -c "
      docker version --format 'client {{.Client.Version}} / server {{.Server.Version}} (api {{.Server.APIVersion}}, os/arch {{.Server.Os}}/{{.Server.Arch}})' 2>/dev/null \
        || docker --version 2>/dev/null"

    _diag_section "docker info (abridged)" sh -c "
      docker info 2>/dev/null | grep -E '^ ?(Server Version|Storage Driver|Cgroup (Driver|Version)|Logging Driver|Swarm|Runtimes|Default Runtime|Kernel Version|Operating System|OSType|Architecture|CPUs|Total Memory|Docker Root Dir|Images|Containers|Running|Paused|Stopped)' || echo '(docker info unavailable)'"

    _diag_section "docker system df" docker system df

    _diag_section "docker ps -a" docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

    _diag_section "docker compose ps" $DOCKER_COMPOSE_CMD ps

    _diag_section "recent docker events (last 15m)" sh -c "
      docker events --since 15m --until 0s --format '{{.Time}} {{.Type}}/{{.Action}} {{.Actor.Attributes.name}} {{.Status}}' 2>/dev/null | tail -40 \
        || echo '(docker events unavailable)'"

    # -----------------------------------------------------------------
    # Per-container state (exit codes, restarts, health)
    # -----------------------------------------------------------------
    _diag_section "per-container state (status / exit / restarts / health)" sh -c "
      printf '%-32s %-10s %-6s %-8s %-10s %s\n' NAME STATUS EXIT RESTART HEALTH IMAGE
      for c in \$(docker ps -a --format '{{.Names}}' | grep -E '^(claw|calltelemetry)-'); do
        docker inspect \"\$c\" --format \\
          '{{printf \"%-32s %-10s %-6s %-8s %-10s %s\" .Name .State.Status (printf \"%d\" .State.ExitCode) (printf \"%d\" .RestartCount) (or .State.Health.Status \"-\") .Config.Image}}' 2>/dev/null \
          | sed 's|^/||'
      done | sort"

    _diag_section "web container env (secrets redacted)" sh -c "
      if [ -n '${web_cid}' ]; then
        docker inspect '${web_cid}' --format '{{range .Config.Env}}{{println .}}{{end}}' \
          | sed -E 's/((PASSWORD|TOKEN|SECRET|API_KEY|DATABASE_URL|CONNECTION_STRING|COOKIE|PRIVATE_KEY)[A-Z0-9_]*=)[^ ]*/\1<redacted>/gI'
      else
        echo '(web container not running)'
      fi"

    _diag_section "db container env (secrets redacted)" sh -c "
      if [ -n '${db_cid}' ]; then
        docker inspect '${db_cid}' --format '{{range .Config.Env}}{{println .}}{{end}}' \
          | sed -E 's/((PASSWORD|TOKEN|SECRET|API_KEY|PRIVATE_KEY)[A-Z0-9_]*=)[^ ]*/\1<redacted>/gI'
      else
        echo '(db container not running)'
      fi"

    # -----------------------------------------------------------------
    # Container logs (full tail + filtered error signal)
    # -----------------------------------------------------------------
    _diag_section "db container logs (last 200)" sh -c "
      if [ -n '${db_cid}' ]; then docker logs --tail 200 '${db_cid}'; else echo '(db container not running)'; fi"

    _diag_section "db FATAL/ERROR (last 30)" sh -c "
      if [ -n '${db_cid}' ]; then
        docker logs --tail 1000 '${db_cid}' 2>&1 | grep -E 'FATAL|ERROR|PANIC|cannot|failed' | tail -30
      else echo '(db container not running)'; fi"

    _diag_section "web container logs (last 200)" sh -c "
      if [ -n '${web_cid}' ]; then docker logs --tail 200 '${web_cid}'; else echo '(web container not running)'; fi"

    _diag_section "web errors (last 30)" sh -c "
      if [ -n '${web_cid}' ]; then
        docker logs --tail 1000 '${web_cid}' 2>&1 | grep -E '(severity\":\"error\"|\\[error\\]|\\*\\* \\()' | tail -30
      else echo '(web container not running)'; fi"

    # Additional container logs if active
    for svc in caddy vue-web traceroute nats ct-syslog-ingest jtapi-sidecar ct-media seaweedfs; do
      local cid
      cid=$($DOCKER_COMPOSE_CMD ps -q "$svc" 2>/dev/null | head -1)
      if [ -n "$cid" ]; then
        _diag_section "${svc} logs (last 80)" docker logs --tail 80 "$cid"
      fi
    done

    # -----------------------------------------------------------------
    # Postgres internals (only if db is reachable)
    # -----------------------------------------------------------------
    _diag_psql "postgres version" "SELECT version();"

    _diag_psql "postgres settings (selected)" \
      "SELECT name, setting FROM pg_settings WHERE name IN ('max_connections','shared_buffers','effective_cache_size','work_mem','maintenance_work_mem','shared_preload_libraries','password_encryption','ssl','timezone','server_version') ORDER BY name;"

    _diag_psql "extensions installed" "\dx"

    _diag_psql "databases (size + encoding)" \
      "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size, datcollate, datctype FROM pg_database WHERE datistemplate IS FALSE ORDER BY pg_database_size(datname) DESC;"

    _diag_psql "roles" \
      "SELECT rolname, rolcanlogin, rolsuper, rolreplication FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%' ORDER BY rolname;"

    _diag_psql "pg_stat_database (calltelemetry_prod)" \
      "SELECT datname, numbackends, xact_commit, xact_rollback, deadlocks, conflicts, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes FROM pg_stat_database WHERE datname='calltelemetry_prod';"

    _diag_psql "connection count by user / state" \
      "SELECT usename, state, application_name, count(*) FROM pg_stat_activity GROUP BY 1,2,3 ORDER BY count(*) DESC;"

    _diag_psql "schema_migrations (count + last 20)" \
      "SELECT COUNT(*) AS applied FROM schema_migrations; SELECT version, inserted_at FROM schema_migrations ORDER BY version DESC LIMIT 20;"

    # If web is up we can compare against the release's expected count.
    _diag_section "expected migration count (from release binary)" sh -c "
      if [ -n '${web_cid}' ]; then
        ${DOCKER_COMPOSE_CMD} exec -T web sh -lc 'find / -path \"*/priv/repo/migrations/[0-9]*.exs\" -type f 2>/dev/null | wc -l' 2>/dev/null
      else
        echo '(web container not running — skipped)'
      fi"

    _diag_psql "pg_stat_activity (non-idle, oldest 40)" \
      "SELECT pid, usename, application_name, state, wait_event_type, wait_event, now()-query_start AS duration, LEFT(query, 200) AS query FROM pg_stat_activity WHERE state IS DISTINCT FROM 'idle' AND pid <> pg_backend_pid() ORDER BY query_start NULLS LAST LIMIT 40;"

    _diag_psql "top 20 tables by size" \
      "SELECT n.nspname||'.'||c.relname AS table, pg_size_pretty(pg_total_relation_size(c.oid)) AS size, c.reltuples::bigint AS est_rows FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema') ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 20;"

    _diag_psql "blocking locks (if any)" \
      "SELECT blocked.pid AS blocked, blocker.pid AS blocker, blocked_a.usename AS blocked_user, LEFT(blocked_a.query,80) AS blocked_query, LEFT(blocker_a.query,80) AS blocker_query FROM pg_locks blocked JOIN pg_stat_activity blocked_a ON blocked_a.pid=blocked.pid JOIN pg_locks blocker ON blocker.locktype=blocked.locktype AND blocker.database IS NOT DISTINCT FROM blocked.database AND blocker.relation IS NOT DISTINCT FROM blocked.relation AND blocker.pid <> blocked.pid JOIN pg_stat_activity blocker_a ON blocker_a.pid=blocker.pid WHERE NOT blocked.granted LIMIT 20;"

    # -----------------------------------------------------------------
    # System journal (docker-related)
    # -----------------------------------------------------------------
    _diag_section "journalctl docker service (last 50)" sh -c "
      journalctl -u docker --no-pager --since '15m ago' 2>/dev/null | tail -50 \
        || echo '(journalctl unavailable or no docker unit)'"

    _diag_section "systemd units (docker, calltelemetry, firewalld)" sh -c "
      for unit in docker calltelemetry firewalld; do
        if systemctl list-unit-files --no-pager 2>/dev/null | grep -q \"^\${unit}\\.service\"; then
          printf '%-20s %s\n' \"\$unit\" \"\$(systemctl is-active \"\$unit\" 2>/dev/null)/\$(systemctl is-enabled \"\$unit\" 2>/dev/null)\"
        fi
      done"

    _diag_section "previous upgrade-diag logs (recurrence check)" sh -c "
      ls -latr '${INSTALL_DIR}'/upgrade-diag-*.log 2>/dev/null | tail -10 \
        || echo '(no prior diagnostic logs — this is the first failure)'"

    echo ""
    echo "=== end of diagnostic ==="
  } >"$dump" 2>&1

  chmod 644 "$dump" 2>/dev/null || true

  echo ""
  echo "=========================================================="
  echo "  Upgrade FAILED — ${reason}"
  echo "=========================================================="
  echo ""
  _print_troubleshoot_suggestions "$phases"
  echo ""
  echo "  Diagnostic bundle written to:"
  echo "    ${dump}"
  echo ""
  echo "  If the troubleshoot steps above don't resolve it, please"
  echo "  email jason@calltelemetry.com and attach this file. It"
  echo "  contains docker state, compose services, db/web logs,"
  echo "  schema migration history, and pg_stat_activity — everything"
  echo "  we need to triage and ship a fix. Secrets in .env are"
  echo "  redacted."
  echo "=========================================================="
  echo ""
}

# Rotate the calltelemetry role password on the running db container.
# $1 = current working password, $2 = new password.
#
# Sends the new password via psql's -v variable mechanism and references it in
# SQL with `:'pw'` (psql's quoted-literal interpolation). This keeps the
# password value out of shell interpolation entirely — any quoting/escaping
# surprises in the hex value are handled by psql, not bash/sh. Earlier
# versions of this function tried to dollar-quote the value through a
# sh -c ... "$$NEW_PW$$" chain, which — because the outer sh -c argument was
# single-quoted — passed the literal 8-char string `{NEW_PW}` through to
# psql as a dollar-quoted SQL literal, silently setting the DB password to
# `{NEW_PW}` and bricking auth. Lesson: never pipe secrets through nested
# quoting layers when psql offers a first-class parameter facility.
_postgres_rotate_password() {
  local current_pw="$1" new_pw="$2"
  [ -n "$current_pw" ] && [ -n "$new_pw" ] || return 1
  local cid
  cid=$(_find_running_db_container)
  [ -n "$cid" ] || return 1
  docker exec -i -e PGPASSWORD="$current_pw" "$cid" \
    psql -h db -U calltelemetry -d calltelemetry_prod \
      -v ON_ERROR_STOP=1 \
      -v "pw=$new_pw" \
      -c "ALTER USER calltelemetry WITH PASSWORD :'pw'" \
      >/dev/null 2>&1
}

_update_cli_tools_quiet() {
  local log_file
  log_file=$(mktemp 2>/dev/null || echo "/tmp/ct-cli-tools-$$.log")

  printf 'Updating CLI Tools...'
  if (
    local required_node_major current_node_major new_node new_major npm_bin
    required_node_major=22
    current_node_major=$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo "0")
    current_node_major=${current_node_major:-0}

    if [ "$current_node_major" -lt "$required_node_major" ] 2>/dev/null; then
      sudo rpm -e --nodeps npm nodejs-full-i18n 2>/dev/null || true
      sudo rpm -e --nodeps nodejs 2>/dev/null || true
      sudo dnf module reset nodejs -y
      sudo dnf module enable nodejs:22 -y
      sudo dnf install -y nodejs --allowerasing
    fi

    new_node=$(node --version 2>/dev/null || echo "none")
    new_major=$(echo "$new_node" | sed 's/v\([0-9]*\).*/\1/' || echo "0")
    [ "$new_major" -ge "$required_node_major" ] 2>/dev/null || {
      echo "Node.js migration failed (got ${new_node}, need v${required_node_major}+)"
      exit 1
    }

    if command -v npm &>/dev/null; then
      npm_bin="npm"
    elif [ -x /usr/bin/npm ]; then
      npm_bin="/usr/bin/npm"
    elif [ -x /usr/lib/node_modules/npm/bin/npm-cli.js ]; then
      npm_bin="/usr/lib/node_modules/npm/bin/npm-cli.js"
    else
      echo "npm not found after Node.js validation"
      exit 1
    fi

    [ -f /usr/local/bin/ct ] && sudo rm -f /usr/local/bin/ct
    sudo "$npm_bin" install -g @calltelemetry/cli
  ) >"$log_file" 2>&1; then
    printf ' done\n'
    log_verbose_ok "CLI Tools ready"
  else
    printf ' warning\n'
    log_warn "CLI Tools update failed (non-critical)"
    if cli_verbose; then
      sed 's/^/  /' "$log_file"
    else
      echo "  Re-run with --verbose to see Node.js/npm details."
    fi
  fi

  rm -f "$log_file"
}

# Ensure baseline PG connection settings exist in .env during upgrades.
# Uses env_set_default so existing customer overrides are preserved.
# Values match the "small" profile — conservative defaults for 4-8GB appliances.
ensure_postgres_defaults() {
  echo "Ensuring PostgreSQL defaults..."
  if ! ensure_postgres_password; then
    log_fail "Failed to ensure PostgreSQL password; aborting defaults apply"
    return 1
  fi
  env_set_default "PG_PROFILE" "small"
  env_set_default "PG_MAX_CONNECTIONS" "100"
  env_set_default "DB_POOL_SIZE" "15"
  env_set_default "DB_MIGRATION_POOL_SIZE" "20"
  env_set_default "DB_CALL_CONTROL_POOL_SIZE" "15"
  env_set_default "DB_BACKGROUND_POOL_SIZE" "15"
  env_set_default "DB_DISCOVERY_POOL_SIZE" "15"
  env_set_default "DB_OBAN_POOL_SIZE" "15"
  env_set_default "PG_BGWRITER_LRU_MAXPAGES" "200"
  env_set_default "PG_BGWRITER_DELAY" "100"
  env_set_default "PG_WAL_COMPRESSION" "on"
  env_set_default "PG_TRACK_IO_TIMING" "on"
  env_set_default "PG_TRACK_FUNCTIONS" "all"
  env_set_default "PG_LOG_MIN_DURATION_STATEMENT" "1000"
  env_set_default "PG_AUTOVACUUM_VACUUM_SCALE_FACTOR" "0.01"
  env_set_default "PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR" "0.005"
  log_verbose_ok "PostgreSQL defaults applied (existing values preserved)"
}

# Correct PG_MAX_CONNECTIONS so it always equals (pool_sum + 25), with a 200
# floor. Runs once per upgrade after ensure_postgres_defaults, so stale values
# (e.g. a hand-set 305 that no longer matches the pool sizes) get fixed.
_migrate_pg_max_connections() {
  local pool_main pool_migration pool_cc pool_bg pool_disc pool_oban pool_sum pool_floor pool_min pg_max
  pool_main=$(env_get "DB_POOL_SIZE");                    pool_main=${pool_main:-15}
  pool_migration=$(env_get "DB_MIGRATION_POOL_SIZE");     pool_migration=${pool_migration:-20}
  pool_cc=$(env_get "DB_CALL_CONTROL_POOL_SIZE");         pool_cc=${pool_cc:-15}
  pool_bg=$(env_get "DB_BACKGROUND_POOL_SIZE");           pool_bg=${pool_bg:-15}
  pool_disc=$(env_get "DB_DISCOVERY_POOL_SIZE");          pool_disc=${pool_disc:-15}
  pool_oban=$(env_get "DB_OBAN_POOL_SIZE");               pool_oban=${pool_oban:-15}
  pool_sum=$(( pool_main + pool_migration + pool_cc + pool_bg + pool_disc + pool_oban ))
  pool_floor=$(( pool_sum + 25 ))
  pool_min=$(( pool_floor > 200 ? pool_floor : 200 ))
  pg_max=$(env_get "PG_MAX_CONNECTIONS"); pg_max=${pg_max:-0}
  if [ "$pg_max" != "$pool_min" ]; then
    env_set "PG_MAX_CONNECTIONS" "$pool_min"
    echo "  ✔ PG_MAX_CONNECTIONS set to $pool_min (pool sum $pool_sum + 25 overhead, floor 200; was: ${pg_max:-unset})"
  else
    log_verbose_ok "PG_MAX_CONNECTIONS already correct ($pool_min)"
  fi
}

# Apply a PostgreSQL connection sizing profile (small/medium/large)
apply_postgres_profile() {
  local profile="$1"
  case "$profile" in
    small)
      env_set "PG_PROFILE" "small"
      env_set "PG_MAX_CONNECTIONS" "100"
      env_set "DB_POOL_SIZE" "15"
      env_set "DB_MIGRATION_POOL_SIZE" "20"
      env_set "DB_CALL_CONTROL_POOL_SIZE" "15"
      env_set "DB_BACKGROUND_POOL_SIZE" "15"
      env_set "DB_DISCOVERY_POOL_SIZE" "15"
      env_set "DB_OBAN_POOL_SIZE" "15"
      ;;
    medium)
      env_set "PG_PROFILE" "medium"
      env_set "PG_MAX_CONNECTIONS" "200"
      env_set "DB_POOL_SIZE" "20"
      env_set "DB_MIGRATION_POOL_SIZE" "20"
      env_set "DB_CALL_CONTROL_POOL_SIZE" "20"
      env_set "DB_BACKGROUND_POOL_SIZE" "20"
      env_set "DB_DISCOVERY_POOL_SIZE" "20"
      env_set "DB_OBAN_POOL_SIZE" "20"
      ;;
    large)
      env_set "PG_PROFILE" "large"
      env_set "PG_MAX_CONNECTIONS" "300"
      env_set "DB_POOL_SIZE" "25"
      env_set "DB_MIGRATION_POOL_SIZE" "25"
      env_set "DB_CALL_CONTROL_POOL_SIZE" "25"
      env_set "DB_BACKGROUND_POOL_SIZE" "25"
      env_set "DB_DISCOVERY_POOL_SIZE" "25"
      env_set "DB_OBAN_POOL_SIZE" "25"
      ;;
    *)
      echo "Usage: cli.sh postgres profile <small|medium|large|show>"
      return 1
      ;;
  esac
  echo "PostgreSQL profile set to: $profile"
  echo "  max_connections:       $(env_get PG_MAX_CONNECTIONS)"
  echo "  db_pool (main):        $(env_get DB_POOL_SIZE)"
  echo "  db_pool (migration):   $(env_get DB_MIGRATION_POOL_SIZE)"
  echo "  db_pool (callctl):     $(env_get DB_CALL_CONTROL_POOL_SIZE)"
  echo "  db_pool (background):  $(env_get DB_BACKGROUND_POOL_SIZE)"
  echo "  db_pool (discovery):   $(env_get DB_DISCOVERY_POOL_SIZE)"
  echo "  db_pool (oban):        $(env_get DB_OBAN_POOL_SIZE)"
  echo ""
  echo "Restarting services to apply new profile..."
  if ! ensure_postgres_password; then
    log_fail "Failed to ensure PostgreSQL password; aborting profile apply"
    return 1
  fi
  $DOCKER_COMPOSE_CMD down db 2>/dev/null
  $DOCKER_COMPOSE_CMD up -d 2>/dev/null
  log_ok "Services restarted with $profile profile"
}

# Remove a key from .env.
# Also strips legacy indented/whitespace-prefixed entries so `jtapi disable`
# and friends fully clear stale duplicates written by older bundles.
# Restores INSTALL_USER ownership when invoked as root.
env_remove() {
  local key="$1"
  if [ -f "$ENV_FILE" ]; then
    sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$ENV_FILE"
    _env_restore_owner
  fi
}

# Migrate legacy .jtapi-enabled state file to .env COMPOSE_PROFILES.
#
# Runs on every CLI invocation and at the top of every jtapi subcommand,
# which means it can be triggered by a non-root user. Since the migration
# rewrites `.env` and removes the legacy state file, it must be gated on
# root — otherwise a non-root `./cli.sh jtapi enable` (or even
# `./cli.sh status`) would mutate state before `require_root` bails on
# the actual subcommand. When not root, we silently skip and let the
# next sudo invocation pick it up.
migrate_jtapi_state() {
  [ "$(id -u)" -eq 0 ] || return 0
  if [ -f "$JTAPI_STATE_FILE" ]; then
    echo "Migrating JTAPI state from .jtapi-enabled to .env COMPOSE_PROFILES..."
    local profiles
    profiles=$(env_get "COMPOSE_PROFILES")
    if ! echo "$profiles" | grep -q "jtapi"; then
      if [ -n "$profiles" ]; then
        env_set "COMPOSE_PROFILES" "${profiles},jtapi"
      else
        env_set "COMPOSE_PROFILES" "jtapi"
      fi
    fi
    # Set JTAPI env vars if not already present
    [ -z "$(env_get JTAPI_MODE)" ] && env_set "JTAPI_MODE" "direct"
    [ -z "$(env_get JTAPI_SIDECAR_ENDPOINT)" ] && env_set "JTAPI_SIDECAR_ENDPOINT" "jtapi-sidecar:50051"
    [ -z "$(env_get JTAPI_SIDECAR_URL)" ] && env_set "JTAPI_SIDECAR_URL" "http://jtapi-sidecar:8080"
    [ -z "$(env_get S3_ENABLED)" ] && env_set "S3_ENABLED" "true"
    [ -z "$(env_get CT_MEDIA_ENDPOINT)" ] && env_set "CT_MEDIA_ENDPOINT" "ct-media:50053"
    rm -f "$JTAPI_STATE_FILE"
    echo "Migration complete. .jtapi-enabled removed."
  fi
}

is_jtapi_enabled() {
  local profiles
  profiles=$(env_get "COMPOSE_PROFILES")
  echo "$profiles" | grep -q "jtapi"
}

# Ensure IPv4 forwarding is enabled — Docker requires this for bridge networking.
# A kernel update or security hardening can reset this to 0, killing Docker on next boot.
ensure_ip_forward() {
  local current
  current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
  if [ "$current" != "1" ]; then
    echo "[cli.sh] Enabling IPv4 forwarding (was disabled — Docker requires this)"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  fi
  # Always ensure persistent config exists
  if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.d/99-docker-ipforward.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-docker-ipforward.conf 2>/dev/null || true
  fi
}

# Build the compose file flags — overlay no longer needed (profiles handle JTAPI)
get_compose_files() {
  echo "-f docker-compose.yml"
}

# Update systemd ExecStart/ExecStop (simplified — no overlay to toggle)
fix_systemd_compose_files() {
  local SERVICE_FILE="/etc/systemd/system/docker-compose-app.service"
  [ -f "$SERVICE_FILE" ] || return 0

  local compose_files
  compose_files=$(get_compose_files)

  local cmd_path
  if [ "$DOCKER_COMPOSE_CMD" = "docker compose" ]; then
    cmd_path="/usr/bin/docker compose"
  else
    cmd_path="/usr/bin/docker-compose"
  fi

  local new_start="ExecStart=$cmd_path $compose_files up -d"
  local new_stop="ExecStop=$cmd_path $compose_files down"

  if ! grep -qF "$new_start" "$SERVICE_FILE" 2>/dev/null; then
    sudo cp "$SERVICE_FILE" "${SERVICE_FILE}.backup" 2>/dev/null
    # Strip any leftover -f docker-compose-jtapi.yml from systemd
    sudo sed -i "s|^ExecStart=.*|$new_start|" "$SERVICE_FILE"
    sudo sed -i "s|^ExecStop=.*|$new_stop|" "$SERVICE_FILE"
    sudo systemctl daemon-reload
    echo "Updated systemd service compose files"
  fi
}

# ── jtapi_cmd decomposition ─────────────────────────────────────────────
#
# jtapi_cmd() was a 412-line function dominated by one massive `case`
# over subcommands (enable / disable / status / troubleshoot). The
# troubleshoot branch alone was 270 lines of diagnostic sections, which
# made reading or testing any single concern require scrolling past the
# other three.
#
# Each subcommand branch is now its own helper so the dispatcher is ~20
# lines and each concern is individually grep-discoverable.
#
# Helpers:
#   _jtapi_cmd_enable        — validate compose defines jtapi services,
#                              flip COMPOSE_PROFILES + JTAPI_* env vars,
#                              restart + force-recreate web
#   _jtapi_cmd_disable       — remove jtapi from COMPOSE_PROFILES +
#                              clear JTAPI_* env vars + restart
#   _jtapi_cmd_status        — short "enabled/disabled + ps" summary
#   _jtapi_cmd_troubleshoot  — 11-section diagnostic dump (feature state,
#                              container health, NATS, JAR status, sidecar,
#                              SeaweedFS, ct-media, web env, CTI creds,
#                              runtime logs, health API)
#   _jtapi_cmd_usage         — help text for the `*)` default branch

_jtapi_cmd_enable() {
  require_root "jtapi enable" || return 1

  # Pre-flight: this appliance's docker-compose.yml must define the
  # `jtapi`-profile services. If the compose file predates the profile
  # architecture (older OVAs), setting COMPOSE_PROFILES=jtapi is a
  # silent no-op — the user sees "JTAPI enabled" but no sidecar comes
  # up. Validate BEFORE we mutate .env or touch systemd.
  #
  # Capture stderr with the exit status so we can distinguish a
  # legitimate "no jtapi services" verdict from an unrelated compose
  # failure (missing file, invalid YAML, docker not installed). A
  # silent fallback would surface a misleading "update first" hint
  # when the real problem is something else.
  local expected_svcs="jtapi-sidecar ct-media seaweedfs"
  local compose_output compose_status
  compose_output=$(COMPOSE_PROFILES=jtapi $DOCKER_COMPOSE_CMD $(get_compose_files) config --services 2>&1)
  compose_status=$?
  if [ "$compose_status" -ne 0 ]; then
    log_fail "Unable to inspect docker-compose.yml for JTAPI profile services."
    echo ""
    echo "  docker compose config exited with status $compose_status. Output:"
    echo ""
    echo "$compose_output" | sed 's/^/    /'
    echo ""
    echo "  Fix the compose file (or docker install) and retry."
    return 1
  fi
  local missing_svcs=""
  local svc
  for svc in $expected_svcs; do
    if ! echo "$compose_output" | grep -qx "$svc"; then
      missing_svcs="${missing_svcs:+$missing_svcs }$svc"
    fi
  done
  if [ -n "$missing_svcs" ]; then
    log_fail "docker-compose.yml is missing required JTAPI profile services:"
    for svc in $missing_svcs; do
      echo "  - $svc"
    done
    echo ""
    echo "This appliance's compose file predates the JTAPI profile architecture."
    echo "Update the appliance first, then retry:"
    echo ""
    echo "    sudo $CURRENT_SCRIPT_PATH update"
    echo "    sudo $CURRENT_SCRIPT_PATH jtapi enable"
    echo ""
    return 1
  fi

  # Add jtapi to COMPOSE_PROFILES
  local profiles
  profiles=$(env_get "COMPOSE_PROFILES")
  if ! echo "$profiles" | grep -q "jtapi"; then
    if [ -n "$profiles" ]; then
      env_set "COMPOSE_PROFILES" "${profiles},jtapi"
    else
      env_set "COMPOSE_PROFILES" "jtapi"
    fi
  fi
  # Set JTAPI env vars
  env_set "JTAPI_MODE" "direct"
  env_set "JTAPI_SIDECAR_ENDPOINT" "jtapi-sidecar:50051"
  env_set "JTAPI_SIDECAR_URL" "http://jtapi-sidecar:8080"
  env_set "S3_ENABLED" "true"
  env_set "CT_MEDIA_ENDPOINT" "ct-media:50053"
  # Clean up legacy state file if present
  rm -f "$JTAPI_STATE_FILE"
  fix_systemd_compose_files
  log_ok "JTAPI enabled — restarting services..."
  echo ""
  if ! restart_service "jtapi enable"; then
    log_fail "Service restart failed. JTAPI config was saved but services may not be running."
    echo "   Retry with: systemctl restart docker-compose-app.service"
    return 1
  fi
  # Force recreate web to pick up new env vars. Capture compose output
  # so the operator sees the real docker/compose error on failure
  # instead of only our generic log_fail line.
  sleep 3
  local recreate_output recreate_rc
  recreate_output=$($DOCKER_COMPOSE_CMD $(get_compose_files) up -d --force-recreate web 2>&1)
  recreate_rc=$?
  if [ "$recreate_rc" -ne 0 ]; then
    log_fail "Web recreate failed after enabling JTAPI."
    printf '%s\n' "$recreate_output" | sed 's/^/    /'
    echo "   JTAPI .env settings were saved, but the web container may still"
    echo "   be using the old environment. Retry with:"
    echo "     sudo systemctl restart docker-compose-app.service"
    return 1
  fi
  echo "Services restarted."
  echo ""
  echo "Next steps:"
  echo "  1. Wait for sidecar to start (~90s)"
  echo "  2. Upload JTAPI JAR via UI (Settings > JTAPI)"
  echo "  3. Sidecar auto-restarts when JAR is received"
  echo "  4. Add CUCM server via UI (Settings > JTAPI > Servers)"
  echo "  5. Sidecar auto-connects when credentials appear in NATS KV"
}

_jtapi_cmd_disable() {
  require_root "jtapi disable" || return 1

  # Remove jtapi from COMPOSE_PROFILES. Split on comma, drop "jtapi",
  # rejoin — the old `sed 's/,*jtapi,*//'` was greedy on BOTH sides of
  # the match, so a middle-position jtapi like `otel,jtapi,storage`
  # collapsed to `otelstorage` (both neighbors silently dropped).
  local profiles new_profiles
  profiles=$(env_get "COMPOSE_PROFILES")
  local -a _profile_arr=()
  local -a _kept=()
  local p
  IFS=',' read -r -a _profile_arr <<<"$profiles"
  for p in "${_profile_arr[@]}"; do
    [ "$p" != "jtapi" ] && [ -n "$p" ] && _kept+=("$p")
  done
  new_profiles=$(IFS=','; echo "${_kept[*]}")
  env_set "COMPOSE_PROFILES" "$new_profiles"
  # Clear JTAPI env vars. S3_ENABLED is shared with the storage feature
  # (SeaweedFS profile) — only flip it off if storage is ALSO being
  # disabled. Otherwise a `cli.sh jtapi disable` on a box that also
  # runs the storage profile would silently regress object-storage
  # behavior across the app.
  env_remove "JTAPI_MODE"
  env_remove "JTAPI_SIDECAR_ENDPOINT"
  env_remove "JTAPI_SIDECAR_URL"
  if ! is_storage_enabled; then
    env_remove "S3_ENABLED"
  fi
  env_remove "CT_MEDIA_ENDPOINT"
  # Clean up legacy state file if present
  rm -f "$JTAPI_STATE_FILE"
  fix_systemd_compose_files
  log_ok "JTAPI disabled — restarting services..."
  if ! restart_service "jtapi disable"; then
    log_fail "Service restart failed. JTAPI config was saved but services may not be running."
    echo "   Retry with: systemctl restart docker-compose-app.service"
    return 1
  fi
  echo "JTAPI services removed."
}

_jtapi_cmd_status() {
  if is_jtapi_enabled; then
    echo "JTAPI: enabled"
    $DOCKER_COMPOSE_CMD $(get_compose_files) ps jtapi-sidecar ct-media seaweedfs 2>/dev/null || true
  else
    echo "JTAPI: disabled"
  fi
}

_jtapi_cmd_usage() {
  echo "Usage: $0 jtapi {enable|disable|status|troubleshoot [--section NAME]}"
  echo ""
  echo "Commands:"
  echo "  enable        Enable JTAPI sidecar, ct-media, and SeaweedFS services"
  echo "  disable       Disable JTAPI services"
  echo "  status        Show JTAPI status and service health"
  echo "  troubleshoot  Run comprehensive JTAPI diagnostics"
  echo "                Use --section <name> to run just one section"
  echo "                Run 'cli.sh jtapi troubleshoot --help' for section list"
}

# ── _jtapi_cmd_troubleshoot decomposition ────────────────────────────────
#
# The troubleshoot subcommand was a 308-line linear dump across 11
# numbered diagnostic sections. Same pattern as the earlier decomps:
# one section's state bled into the next (CT_NETWORK was set in section 3
# and reused in 4 + 11), and there was no way to run just one section
# when you knew what you were looking for.
#
# Each numbered section is now its own helper. The orchestrator accepts
# `--section NAME` to run only that one, which is what support escalation
# actually needs 90% of the time ("just show me the sidecar logs, not
# the whole 300-line wall of text").
#
# Helpers (in dispatch order):
#   _troubleshoot_feature_state       — profile + compose-file check
#   _troubleshoot_container_health    — docker inspect + restart counts
#   _troubleshoot_nats_connectivity   — health endpoint + KV + ObjectStore
#   _troubleshoot_jar_status          — docker volume + NATS object info
#   _troubleshoot_sidecar_health      — actuator health + last 20 log lines
#   _troubleshoot_seaweedfs_health    — cluster healthz
#   _troubleshoot_ct_media_health     — ps state + last 10 log lines
#   _troubleshoot_web_env             — web container JTAPI env vars
#   _troubleshoot_cti_credentials     — CallManager CTI creds via release RPC
#   _troubleshoot_runtime_logs        — NATS sup + JAR mgr + gRPC log scan
#   _troubleshoot_health_api          — /api/org/1/jtapi/sidecar/health
#
# Shared helper:
#   _troubleshoot_ct_network          — compose-network detection, replaces
#                                       the previous per-section `if/else`
#                                       fallback chains

_troubleshoot_ct_network() {
  # Derive the docker-compose network name to attach `docker run` sidecars
  # (nats-box) to. Preference order:
  #   1) Live nats container's actual network
  #   2) The deterministic project-derived `<project>_ct` network if it
  #      exists (CodeRabbit finding on PR #54: a host-wide `_ct` scan
  #      on machines with parallel/stale compose projects can return the
  #      wrong stack and produce misleading JTAPI diagnostics)
  #   3) Any other `_ct`-suffixed network on the host
  #   4) The project-derived name as the last-resort default
  local net default_net
  default_net="${COMPOSE_PROJECT_NAME:-$(basename "$INSTALL_DIR")}_ct"
  net=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps --format '{{.Networks}}' nats 2>/dev/null | head -1 | cut -d',' -f1)
  if [ -z "$net" ]; then
    if docker network inspect "$default_net" >/dev/null 2>&1; then
      net="$default_net"
    else
      net=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep '_ct$' | head -1)
    fi
  fi
  if [ -z "$net" ]; then
    net="$default_net"
  fi
  printf '%s' "$net"
}

_troubleshoot_feature_state() {
  echo "--- Feature State ---"
  if is_jtapi_enabled; then
    log_ok "JTAPI enabled (COMPOSE_PROFILES includes jtapi)"
  else
    log_fail "JTAPI disabled (COMPOSE_PROFILES does not include jtapi)"
  fi
  echo "  COMPOSE_PROFILES=$(env_get COMPOSE_PROFILES)"
  echo "  Compose files: $(get_compose_files)"
  echo ""
}

_troubleshoot_container_health() {
  echo "--- Container Health ---"
  export DEFAULT_IPV4="${DEFAULT_IPV4:-}"
  local svc cid cstate exit_code
  for svc in jtapi-jar-init jtapi-sidecar ct-media seaweedfs; do
    cid=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps -q "$svc" 2>/dev/null)
    if [ -z "$cid" ]; then
      # Init container may not show in ps after completion — check all containers
      cid=$(docker ps -a --filter "name=${svc}" --format '{{.ID}}' 2>/dev/null | head -1)
    fi

    if [ -z "$cid" ]; then
      if [ "$svc" = "jtapi-jar-init" ]; then
        log_warn "$svc: not found (may have been cleaned up after successful run)"
      else
        log_fail "$svc: not found (not deployed or not in compose files)"
      fi
    else
      cstate=$(docker inspect --format='{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
      exit_code=$(docker inspect --format='{{.State.ExitCode}}' "$cid" 2>/dev/null || echo "N/A")

      if [ "$svc" = "jtapi-jar-init" ]; then
        # Init container is expected to exit with code 0
        if [ "$cstate" = "exited" ] && [ "$exit_code" = "0" ]; then
          log_ok "$svc: completed successfully (exit 0)"
        elif [ "$cstate" = "exited" ]; then
          log_fail "$svc: failed (exit $exit_code)"
        else
          log_warn "$svc: $cstate"
        fi
      elif [ "$cstate" = "running" ]; then
        log_ok "$svc: running"
      else
        log_fail "$svc: $cstate (exit $exit_code)"
      fi
    fi
  done
  echo ""
  echo "  Container restart counts:"
  local restart_count
  for svc in jtapi-sidecar ct-media seaweedfs; do
    restart_count=$(docker inspect --format='{{.RestartCount}}' "$($DOCKER_COMPOSE_CMD $(get_compose_files) ps -q "$svc" 2>/dev/null)" 2>/dev/null || echo "N/A")
    echo "    $svc: $restart_count restarts"
  done
  echo ""
}

_troubleshoot_nats_connectivity() {
  echo "--- NATS Connectivity ---"
  # Check NATS is accepting connections via health endpoint
  local nats_health
  nats_health=$($DOCKER_COMPOSE_CMD $(get_compose_files) exec -T nats wget -q -O- http://127.0.0.1:8222/healthz 2>&1)
  if echo "$nats_health" | grep -qi "ok\|status"; then
    log_ok "NATS server is healthy"
  else
    # Fallback: check container health status (pgrep not available in nats:2.11 image)
    local nats_status
    nats_status=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps nats --format '{{.Status}}' 2>/dev/null || echo "unknown")
    echo "  NATS: $nats_status"
  fi
  echo ""

  # Use nats-box for KV/ObjectStore checks (nats CLI not in server image)
  local CT_NETWORK
  CT_NETWORK=$(_troubleshoot_ct_network)

  echo "  NATS KV buckets:"
  local kv_output kv_rc
  kv_output=$(docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 nats -s nats://nats:4222 kv ls 2>&1)
  kv_rc=$?
  printf '%s\n' "$kv_output" | sed 's/^/    /'
  [ "$kv_rc" -eq 0 ] || log_fail "Could not list KV buckets"
  echo ""

  echo "  NATS ObjectStore (jtapi-jars-1):"
  local objstore_result
  objstore_result=$(docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 nats -s nats://nats:4222 object ls jtapi-jars-1 2>&1)
  if echo "$objstore_result" | grep -q "jtapi.jar"; then
    echo "    ✓ jtapi.jar found in NATS ObjectStore"
  elif echo "$objstore_result" | grep -qi "not found\|no such\|error"; then
    log_warn "jtapi-jars-1 bucket: $objstore_result"
  else
    echo "    $objstore_result" | sed 's/^/    /'
  fi
  echo ""

  echo "--- NATS ObjectStore Buckets ---"
  local buckets_output buckets_rc
  buckets_output=$(docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 \
    sh -c 'nats -s nats://nats:4222 object ls 2>&1' 2>&1)
  buckets_rc=$?
  printf '%s\n' "$buckets_output" | sed 's/^/    /'
  [ "$buckets_rc" -eq 0 ] || echo "    Failed to list ObjectStore buckets"
  echo ""

  echo "--- jtapi-jars-1 bucket contents ---"
  local jar_bucket_output jar_bucket_rc
  jar_bucket_output=$(docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 \
    sh -c 'nats -s nats://nats:4222 object ls jtapi-jars-1 2>&1' 2>&1)
  jar_bucket_rc=$?
  printf '%s\n' "$jar_bucket_output" | sed 's/^/    /'
  [ "$jar_bucket_rc" -eq 0 ] || echo "    Bucket jtapi-jars-1 not found or empty"
  echo ""
}

_troubleshoot_jar_status() {
  echo "--- JAR Status ---"
  local jar_vol_check
  jar_vol_check=$(docker run --rm -v calltelemetry_jtapi-jars:/jars alpine ls -la /jars/jtapi.jar 2>&1)
  if echo "$jar_vol_check" | grep -q "jtapi.jar"; then
    log_ok "JAR found in Docker volume"
    echo "    $jar_vol_check"
  else
    log_fail "JAR not found in Docker volume"
    echo "    $jar_vol_check"
  fi
  echo ""
  echo "  NATS ObjectStore JAR info:"
  local CT_NETWORK obj_output obj_rc
  CT_NETWORK=$(_troubleshoot_ct_network)
  obj_output=$(docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 nats -s nats://nats:4222 object info jtapi-jars-1 jtapi.jar 2>&1)
  obj_rc=$?
  printf '%s\n' "$obj_output" | sed 's/^/    /'
  [ "$obj_rc" -eq 0 ] || log_fail "Could not query NATS ObjectStore"
  echo ""
}

_troubleshoot_sidecar_health() {
  echo "--- Sidecar Health ---"
  local sidecar_health
  sidecar_health=$($DOCKER_COMPOSE_CMD $(get_compose_files) exec -T jtapi-sidecar wget -q -O- http://127.0.0.1:8080/actuator/health 2>&1 || echo "Sidecar not responding")
  if echo "$sidecar_health" | grep -qi '"status":"UP"\|"status":"up"'; then
    log_ok "Sidecar health: $sidecar_health"
  else
    log_warn "Sidecar health: $sidecar_health"
  fi
  echo ""
  echo "  Last 20 lines of sidecar logs:"
  $DOCKER_COMPOSE_CMD $(get_compose_files) logs --tail=20 jtapi-sidecar 2>&1 | sed 's/^/    /'
  echo ""
}

_troubleshoot_seaweedfs_health() {
  echo "--- SeaweedFS Health ---"
  local seaweedfs_health sw_rc
  seaweedfs_health=$($DOCKER_COMPOSE_CMD $(get_compose_files) exec -T seaweedfs curl -sf http://127.0.0.1:9333/cluster/healthz 2>&1)
  sw_rc=$?
  if [ "$sw_rc" -eq 0 ]; then
    log_ok "SeaweedFS is healthy"
  else
    log_fail "SeaweedFS health check failed: $seaweedfs_health"
  fi
  echo ""
  # The probe below hits /cluster/healthz, not the buckets API, so
  # label the section accordingly to match what's printed (Copilot
  # finding on PR #54).
  echo "  SeaweedFS cluster status:"
  local sw_output
  sw_output=$($DOCKER_COMPOSE_CMD $(get_compose_files) exec -T seaweedfs curl -sf http://localhost:9333/cluster/healthz 2>&1)
  sw_rc=$?
  printf '%s\n' "$sw_output" | sed 's/^/    /'
  [ "$sw_rc" -eq 0 ] || log_warn "Could not check SeaweedFS cluster status"
  echo ""
}

_troubleshoot_ct_media_health() {
  echo "--- ct-media Health ---"
  local media_state
  media_state=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps --format '{{.State}}' ct-media 2>/dev/null || echo "not found")
  if [ "$media_state" = "running" ]; then
    log_ok "ct-media is running"
  else
    log_fail "ct-media state: ${media_state:-not found}"
  fi
  echo ""
  echo "  Last 10 lines of ct-media logs:"
  $DOCKER_COMPOSE_CMD $(get_compose_files) logs --tail=10 ct-media 2>&1 | sed 's/^/    /'
  echo ""
}

_troubleshoot_web_env() {
  echo "--- Web Service JTAPI Config ---"
  echo "  Environment variables:"
  # Capture stderr too (2>&1) so a failing `docker compose exec` surfaces
  # its error text in this diagnostic dump — the whole point of the
  # troubleshoot section is to show the operator what actually went wrong.
  local env_output env_rc
  env_output=$($DOCKER_COMPOSE_CMD $(get_compose_files) exec -T web env 2>&1)
  env_rc=$?
  if [ "$env_rc" -eq 0 ]; then
    printf '%s\n' "$env_output" | grep -E 'JTAPI|S3_|CT_MEDIA|NATS_URL' | sort | sed 's/^/    /'
  else
    log_fail "Could not read web container env"
    printf '%s\n' "$env_output" | sed 's/^/    /'
  fi
  echo ""
}

_troubleshoot_cti_credentials() {
  echo "--- CallManager CTI Credentials ---"
  local release_bin
  release_bin=$(get_release_binary)
  local cti_output cti_rc
  cti_output=$($DOCKER_COMPOSE_CMD $(get_compose_files) exec -T web "$release_bin" rpc '
    alias Cdrcisco.Repo
    alias Cdrcisco.JTAPI.Servers
    import Ecto.Query

    servers = Repo.all(from s in Cdrcisco.JTAPI.Server, preload: [:callmanager])

    if servers == [] do
      IO.puts("No JTAPI servers configured")
    else
      Enum.each(servers, fn server ->
        cm = server.callmanager
        IO.puts("JTAPI Server: #{server.name || server.hostname}")
        IO.puts("  CallManager: #{if cm, do: cm.name || cm.hostname, else: "NOT LINKED"}")
        IO.puts("  CTI Username: #{if cm && cm.cti_username && cm.cti_username != "", do: cm.cti_username, else: "NOT SET"}")
        IO.puts("  CTI Password: #{if cm && cm.cti_password, do: "****", else: "NOT SET"}")
        IO.puts("  Status: #{server.status || "unknown"}")
      end)
    end
  ' 2>&1)
  cti_rc=$?
  printf '%s\n' "$cti_output" | sed 's/^/  /'
  [ "$cti_rc" -eq 0 ] || log_fail "Could not query JTAPI server configuration (web container may not be running)"
  echo ""
}

_troubleshoot_runtime_logs() {
  echo ""
  echo "=== JTAPI Runtime Diagnostics (from web logs) ==="
  echo ""

  # Check for NatsSupervisor startup messages
  echo "--- NATS Supervisor Startup ---"
  local nats_sup_logs
  nats_sup_logs=$($DOCKER_COMPOSE_CMD $(get_compose_files) logs web --tail=200 2>/dev/null | grep -i "NatsSupervisor\|jtapi_gnat\|JtapiGreeting" | tail -5)
  if [ -n "$nats_sup_logs" ]; then
    echo "$nats_sup_logs"
  else
    echo "  No JTAPI NATS supervisor messages found in recent logs"
  fi

  # Check for ObjectStore / JarManager errors
  echo ""
  echo "--- JAR Manager / ObjectStore Errors ---"
  local jar_logs
  jar_logs=$($DOCKER_COMPOSE_CMD $(get_compose_files) logs web --tail=500 2>/dev/null | grep -i "JarManager\|ObjectStore\|object_store\|jtapi.*jar\|bucket" | tail -10)
  if [ -n "$jar_logs" ]; then
    echo "$jar_logs"
  else
    echo "  No JAR/ObjectStore errors found in recent logs"
  fi

  # Check for gRPC client errors
  echo ""
  echo "--- gRPC Client Status ---"
  local grpc_logs
  grpc_logs=$($DOCKER_COMPOSE_CMD $(get_compose_files) logs web --tail=200 2>/dev/null | grep -i "DirectGrpcClient\|grpc.*connect\|GRPC.*error\|sidecar.*endpoint" | tail -5)
  if [ -n "$grpc_logs" ]; then
    echo "$grpc_logs"
  else
    echo "  No gRPC client messages found in recent logs"
  fi
}

_troubleshoot_health_api() {
  echo ""
  echo "=== JTAPI Health API Response ==="
  echo ""

  local CT_NETWORK health_response
  CT_NETWORK=$(_troubleshoot_ct_network)

  # Call the health endpoint directly (org_id=1 for OVA single-org)
  health_response=$(docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 \
    sh -c 'wget -q -O- http://web:4080/api/org/1/jtapi/sidecar/health 2>&1' 2>/dev/null)

  if [ -n "$health_response" ]; then
    if command -v jq &>/dev/null; then
      echo "$health_response" | jq '.' 2>/dev/null || echo "$health_response"
    else
      echo "$health_response"
    fi
  else
    echo "  Failed to reach health endpoint (may require auth token)"
    echo "  Try: curl -s http://localhost/api/org/1/jtapi/sidecar/health (with auth header)"
  fi
  echo ""
}

_troubleshoot_usage() {
  echo "Usage: $0 jtapi troubleshoot [--section <name>]"
  echo ""
  echo "Without --section, runs all 11 diagnostic sections."
  echo ""
  echo "Available sections:"
  echo "  feature       Feature state (profiles, env vars, compose files)"
  echo "  containers    Container health + restart counts"
  echo "  nats          NATS connectivity + KV + ObjectStore buckets"
  echo "  jar           JAR Docker volume + NATS ObjectStore jar info"
  echo "  sidecar       JTAPI sidecar actuator health + last 20 log lines"
  echo "  seaweedfs     SeaweedFS cluster health"
  echo "  ct-media      ct-media container state + last 10 log lines"
  echo "  web-env       Web container JTAPI-related env vars"
  echo "  cti           CallManager CTI credentials (release RPC query)"
  echo "  logs          Web log scan for NATS sup / JAR mgr / gRPC errors"
  echo "  health-api    /api/org/1/jtapi/sidecar/health response"
  echo ""
  echo "Example:"
  echo "  cli.sh jtapi troubleshoot --section nats"
}

_jtapi_cmd_troubleshoot() {
  local section=""
  # Track whether --section was passed (even with an empty value) so an
  # empty value (e.g. `--section=`) can be flagged as a malformed
  # invocation rather than silently running all sections (Copilot
  # finding on PR #54).
  local section_seen=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --section)
        section_seen=1
        # Guard the missing-value path BEFORE shift 2 so bash doesn't
        # leak "shift: can't shift that many" to stderr ahead of our
        # usage text (CodeRabbit finding on PR #54).
        if [ $# -lt 2 ]; then
          log_fail "--section requires a value"
          _troubleshoot_usage
          return 1
        fi
        section="$2"
        shift 2
        ;;
      --section=*)
        section_seen=1
        section="${1#--section=}"
        shift
        ;;
      -h|--help|help)
        _troubleshoot_usage
        return 0
        ;;
      *)
        log_fail "Unknown argument: $1"
        _troubleshoot_usage
        return 1
        ;;
    esac
  done

  if [ "$section_seen" = "1" ] && [ -z "$section" ]; then
    log_fail "--section requires a non-empty value"
    _troubleshoot_usage
    return 1
  fi

  if [ -z "$section" ]; then
    echo "=== JTAPI Troubleshooting ==="
    echo ""
    _troubleshoot_feature_state
    _troubleshoot_container_health
    _troubleshoot_nats_connectivity
    _troubleshoot_jar_status
    _troubleshoot_sidecar_health
    _troubleshoot_seaweedfs_health
    _troubleshoot_ct_media_health
    _troubleshoot_web_env
    _troubleshoot_cti_credentials
    _troubleshoot_runtime_logs
    _troubleshoot_health_api
    echo "=== Troubleshooting Complete ==="
    return 0
  fi

  case "$section" in
    feature|state)              _troubleshoot_feature_state ;;
    containers|container)       _troubleshoot_container_health ;;
    nats|nats-connectivity)     _troubleshoot_nats_connectivity ;;
    jar|jar-status)             _troubleshoot_jar_status ;;
    sidecar|sidecar-health)     _troubleshoot_sidecar_health ;;
    seaweedfs|seaweedfs-health) _troubleshoot_seaweedfs_health ;;
    ct-media|ct-media-health|media) _troubleshoot_ct_media_health ;;
    web-env|web|env)            _troubleshoot_web_env ;;
    cti|cti-credentials|credentials) _troubleshoot_cti_credentials ;;
    logs|runtime|runtime-logs) _troubleshoot_runtime_logs ;;
    health-api|health|api)      _troubleshoot_health_api ;;
    *)
      log_fail "Unknown section: $section"
      _troubleshoot_usage
      return 1
      ;;
  esac
}

jtapi_cmd() {
  local subcmd="${1:-}"
  # Suppress "shift: can't shift that many" stderr noise when invoked
  # without a subcommand (e.g. `cli.sh jtapi`) — matches the
  # `shift 2>/dev/null || true` idiom used elsewhere (Copilot finding).
  shift 2>/dev/null || true

  # Auto-migrate legacy state file on any jtapi command
  migrate_jtapi_state

  # Forward remaining args ("$@") to subcommand handlers so troubleshoot
  # receives flags like --section. enable/disable/status don't take args
  # today but passing them through costs nothing and keeps the pattern
  # uniform if they grow flags later.
  case "$subcmd" in
    enable)       _jtapi_cmd_enable "$@" ;;
    disable)      _jtapi_cmd_disable "$@" ;;
    status)       _jtapi_cmd_status "$@" ;;
    troubleshoot) _jtapi_cmd_troubleshoot "$@" ;;
    *)            _jtapi_cmd_usage ;;
  esac
}

# ─── profile_up / profile_down helpers ───────────────────────────────────────

# profile_up <service> [service...]
#   Starts the given services using the current COMPOSE_PROFILES from .env.
#   Non-blocking: returns once containers are started (not necessarily healthy).
profile_up() {
  local compose_file
  compose_file=$(get_compose_files)
  $DOCKER_COMPOSE_CMD $compose_file up -d "$@" 2>&1 | grep -v "^time=" || true
}

# profile_down <container> [container...]
#   Stops and removes the named containers directly.
#   Bypasses docker compose --remove-orphans which doesn't evict profile-gated containers.
profile_down() {
  local containers=("$@")
  local running=()
  for c in "${containers[@]}"; do
    if docker inspect "$c" >/dev/null 2>&1; then
      running+=("$c")
    fi
  done
  if [ ${#running[@]} -eq 0 ]; then
    return 0
  fi
  docker stop "${running[@]}" >/dev/null 2>&1 || true
  docker rm   "${running[@]}" >/dev/null 2>&1 || true
}

# ─── ~/.ct/preferences.json helpers ──────────────────────────────────────────
# Compatible with the @calltelemetry/cli (ct) preferences format.
# Uses python3 for reliable JSON read/write without requiring jq.
CT_PREFS_FILE="${HOME}/.ct/preferences.json"

# Read a boolean key from preferences.json; echoes "true" or "false".
prefs_get() {
  local key="$1"
  python3 -c "
import json, sys
try:
    with open('${CT_PREFS_FILE}') as f:
        p = json.load(f)
    v = p.get('${key}')
    print('true' if v else 'false')
except Exception:
    print('none')
" 2>/dev/null || echo "none"
}

# Write a boolean key to preferences.json (creates dir/file if needed).
prefs_set() {
  local key="$1" value="$2"   # value: "true" | "false"
  python3 - << INNER_EOF 2>/dev/null
import json, os
d = os.path.expanduser("~/.ct")
f = os.path.join(d, "preferences.json")
os.makedirs(d, exist_ok=True)
try:
    with open(f) as fh:
        prefs = json.load(fh)
except Exception:
    prefs = {}
prefs["${key}"] = ("${value}" == "true")
with open(f, "w") as fh:
    json.dump(prefs, fh, indent=2)
    fh.write("\n")
INNER_EOF
}

# ─── Storage (SeaweedFS) commands ─────────────────────────────────────────────

is_storage_enabled() {
  local profiles
  profiles=$(env_get "COMPOSE_PROFILES")
  echo "$profiles" | grep -q "storage"
}

sync_prefs_to_env_storage() {
  local pref_val
  pref_val=$(prefs_get "storage")

  case "$pref_val" in
    true)
      local profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      if ! echo "$profiles" | grep -q "storage"; then
        if [ -n "$profiles" ]; then
          env_set "COMPOSE_PROFILES" "${profiles},storage"
        else
          env_set "COMPOSE_PROFILES" "storage"
        fi
      fi
      ;;
    false)
      local profiles new_profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      new_profiles=$(echo "$profiles" | sed 's/,*storage,*//' | sed 's/^,//' | sed 's/,$//')
      if [ "$profiles" != "$new_profiles" ]; then
        env_set "COMPOSE_PROFILES" "$new_profiles"
      fi
      ;;
    *)
      # Key absent in prefs — do not override .env
      ;;
  esac
}

storage_cmd() {
  local subcmd="${1:-status}"
  shift 2>/dev/null || true

  case "$subcmd" in
    enable)
      local profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      if ! echo "$profiles" | grep -q "storage"; then
        if [ -n "$profiles" ]; then
          env_set "COMPOSE_PROFILES" "${profiles},storage"
        else
          env_set "COMPOSE_PROFILES" "storage"
        fi
      fi
      env_set "S3_ENABLED" "true"
      env_set "S3_ENDPOINT" "http://seaweedfs:8333"
      prefs_set "storage" "true"
      fix_systemd_compose_files
      echo "✅ Storage (SeaweedFS) enabled — starting services..."
      profile_up seaweedfs
      echo "Storage services started."
      ;;
    disable)
      local profiles new_profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      new_profiles=$(echo "$profiles" | sed 's/,*storage,*//' | sed 's/^,//' | sed 's/,$//')
      env_set "COMPOSE_PROFILES" "$new_profiles"
      env_set "S3_ENABLED" "false"
      prefs_set "storage" "false"
      fix_systemd_compose_files
      echo "✅ Storage (SeaweedFS) disabled — stopping services..."
      profile_down calltelemetry-seaweedfs-1
      echo "SeaweedFS stopped."
      ;;
    status)
      if is_storage_enabled; then
        echo "Storage: enabled"
        $DOCKER_COMPOSE_CMD $(get_compose_files) ps seaweedfs 2>/dev/null || true
      else
        echo "Storage: disabled"
      fi
      ;;
    *)
      echo "Usage: $0 storage {enable|disable|status}"
      echo ""
      echo "Commands:"
      echo "  enable   Start SeaweedFS S3-compatible object store"
      echo "  disable  Stop SeaweedFS"
      echo "  status   Show storage status"
      ;;
  esac
}

# ─── Syslog stack commands ───────────────────────────────────────────────────

is_syslog_enabled() {
  local profiles
  profiles=$(env_get "COMPOSE_PROFILES")
  echo "$profiles" | grep -q "syslog"
}

compose_profiles_without() {
  local profiles="$1"
  local remove_profile="$2"
  local -a profile_arr=()
  local -a kept=()
  local profile

  IFS=',' read -r -a profile_arr <<<"$profiles"
  for profile in "${profile_arr[@]}"; do
    [ -z "$profile" ] && continue
    [ "$profile" = "$remove_profile" ] && continue
    kept+=("$profile")
  done

  local IFS=','
  printf '%s' "${kept[*]}"
}

sync_prefs_to_env_syslog() {
  local pref_val
  pref_val=$(prefs_get "syslog")

  case "$pref_val" in
    true)
      local profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      if ! echo "$profiles" | grep -q "syslog"; then
        if [ -n "$profiles" ]; then
          env_set "COMPOSE_PROFILES" "${profiles},syslog"
        else
          env_set "COMPOSE_PROFILES" "syslog"
        fi
      fi
      ;;
    false)
      local profiles new_profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      new_profiles=$(compose_profiles_without "$profiles" "syslog")
      if [ "$profiles" != "$new_profiles" ]; then
        env_set "COMPOSE_PROFILES" "$new_profiles"
      fi
      ;;
    *)
      # Key absent in prefs — do not override .env
      ;;
  esac
}

syslog_cmd() {
  local subcmd="${1:-status}"
  shift 2>/dev/null || true

  case "$subcmd" in
    enable)
      local profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      if ! echo "$profiles" | grep -q "syslog"; then
        if [ -n "$profiles" ]; then
          env_set "COMPOSE_PROFILES" "${profiles},syslog"
        else
          env_set "COMPOSE_PROFILES" "syslog"
        fi
      fi
      prefs_set "syslog" "true"
      fix_systemd_compose_files
      log_ok "Syslog stack enabled; starting services..."
      profile_up loki alloy ct-syslog-ingest
      echo "Syslog ingest, Loki, and Alloy started."
      ;;
    disable)
      local profiles new_profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      new_profiles=$(compose_profiles_without "$profiles" "syslog")
      env_set "COMPOSE_PROFILES" "$new_profiles"
      prefs_set "syslog" "false"
      fix_systemd_compose_files
      log_ok "Syslog stack disabled; stopping services..."
      profile_down calltelemetry-ct-syslog-ingest-1
      if ! is_otel_enabled; then
        profile_down calltelemetry-alloy-1 calltelemetry-loki-1
      fi
      echo "Syslog services stopped."
      ;;
    status)
      if is_syslog_enabled; then
        echo "Syslog: enabled"
        $DOCKER_COMPOSE_CMD $(get_compose_files) ps ct-syslog-ingest loki alloy 2>/dev/null || true
      else
        echo "Syslog: disabled"
      fi
      ;;
    *)
      echo "Usage: $0 syslog {enable|disable|status}"
      echo ""
      echo "Commands:"
      echo "  enable   Start ct-syslog-ingest, Loki, and Alloy"
      echo "  disable  Stop syslog ingest and shared logging services when unused"
      echo "  status   Show syslog stack status"
      ;;
  esac
}

# ─── Otel (observability) stack commands ─────────────────────────────────────

is_otel_enabled() {
  local profiles
  profiles=$(env_get "COMPOSE_PROFILES")
  echo "$profiles" | grep -q "otel"
}

sync_prefs_to_env_otel() {
  local pref_val
  pref_val=$(prefs_get "otel")

  case "$pref_val" in
    true)
      local profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      if ! echo "$profiles" | grep -q "otel"; then
        if [ -n "$profiles" ]; then
          env_set "COMPOSE_PROFILES" "${profiles},otel"
        else
          env_set "COMPOSE_PROFILES" "otel"
        fi
      fi
      ;;
    false)
      local profiles new_profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      new_profiles=$(echo "$profiles" | sed 's/,*otel,*//' | sed 's/^,//' | sed 's/,$//')
      if [ "$profiles" != "$new_profiles" ]; then
        env_set "COMPOSE_PROFILES" "$new_profiles"
      fi
      ;;
    *)
      # Key absent in prefs — do not override .env
      ;;
  esac
}

otel_cmd() {
  local subcmd="${1:-status}"
  shift 2>/dev/null || true

  case "$subcmd" in
    enable)
      local profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      if ! echo "$profiles" | grep -q "otel"; then
        if [ -n "$profiles" ]; then
          env_set "COMPOSE_PROFILES" "${profiles},otel"
        else
          env_set "COMPOSE_PROFILES" "otel"
        fi
      fi
      env_set "PROM_EX_UPLOAD_DASHBOARDS" "true"
      prefs_set "otel" "true"
      fix_systemd_compose_files
      echo "✅ Otel stack enabled — starting services..."
      profile_up prometheus grafana loki alloy tempo otel-collector node-exporter nats-exporter postgres-exporter alertmanager
      echo "Prometheus, Grafana, Loki, Alloy, Tempo, and exporters started."
      ;;
    disable)
      local profiles new_profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      new_profiles=$(echo "$profiles" | sed 's/,*otel,*//' | sed 's/^,//' | sed 's/,$//')
      env_set "COMPOSE_PROFILES" "$new_profiles"
      env_set "PROM_EX_UPLOAD_DASHBOARDS" "false"
      prefs_set "otel" "false"
      fix_systemd_compose_files
      echo "✅ Otel stack disabled — stopping services..."
      if is_syslog_enabled; then
        profile_down \
          calltelemetry-prometheus-1 calltelemetry-grafana-1 calltelemetry-tempo-1 \
          calltelemetry-otel-collector-1 calltelemetry-node-exporter-1 \
          calltelemetry-nats-exporter-1 calltelemetry-postgres-exporter-1 \
          calltelemetry-alertmanager-1
      else
        profile_down \
          calltelemetry-prometheus-1 calltelemetry-grafana-1 calltelemetry-loki-1 \
          calltelemetry-alloy-1 calltelemetry-tempo-1 calltelemetry-otel-collector-1 \
          calltelemetry-node-exporter-1 calltelemetry-nats-exporter-1 \
          calltelemetry-postgres-exporter-1 calltelemetry-alertmanager-1
      fi
      echo "Otel services stopped."
      ;;
    status)
      if is_otel_enabled; then
        echo "Otel: enabled"
        $DOCKER_COMPOSE_CMD $(get_compose_files) ps prometheus grafana loki alloy tempo otel-collector node-exporter nats-exporter postgres-exporter alertmanager 2>/dev/null || true
      else
        echo "Otel: disabled"
      fi
      ;;
    *)
      echo "Usage: $0 otel {enable|disable|status}"
      echo ""
      echo "Commands:"
      echo "  enable   Start Prometheus, Grafana, Loki, Alloy, Tempo, otel-collector, and exporters"
      echo "  disable  Stop the full otel stack (~900 MiB freed)"
      echo "  status   Show otel stack status"
      ;;
  esac
}

ensure_bind_mount_files() {
  # Ensure files that Docker bind-mounts exist as FILES (not directories).
  # Docker auto-creates missing bind-mount paths as directories, which
  # causes "not a directory" OCI runtime errors on container start.

  # AlertManager config
  mkdir -p alertmanager
  if [ -d "alertmanager/alertmanager.yml" ]; then
    rm -rf "alertmanager/alertmanager.yml"
  fi
  if [ ! -f "alertmanager/alertmanager.yml" ]; then
    cat > alertmanager/alertmanager.yml << 'AMEOF'
global:
  resolve_timeout: 5m
route:
  receiver: 'default'
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
receivers:
  - name: 'default'
AMEOF
    echo "Created default alertmanager/alertmanager.yml"
  fi

  # Tempo config
  mkdir -p tempo
  if [ -d "tempo/tempo.yaml" ]; then
    rm -rf "tempo/tempo.yaml"
  fi
  if [ ! -f "tempo/tempo.yaml" ]; then
    cat > tempo/tempo.yaml << 'TEMPOEOF'
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

ingester:
  max_block_duration: 5m

compactor:
  compaction:
    block_retention: 72h    # Keep traces for 3 days

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/blocks
    wal:
      path: /var/tempo/wal

metrics_generator:
  registry:
    external_labels:
      source: tempo
  storage:
    path: /var/tempo/generator/wal
    remote_write:
      - url: http://prometheus:9090/api/v1/write
        send_exemplars: true
TEMPOEOF
    echo "Created default tempo/tempo.yaml"
  fi

  # Prometheus config
  mkdir -p prometheus
  if [ ! -f "prometheus/prometheus.yml" ]; then
    cat > prometheus/prometheus.yml << 'PROMEOF'
global:
  scrape_interval: 30s
  evaluation_interval: 30s
scrape_configs:
  - job_name: 'calltelemetry'
    static_configs:
      - targets: ['web:4080']
PROMEOF
    echo "Created default prometheus/prometheus.yml"
  fi

  # Prometheus alert rules
  [ -d "prometheus/alert_rules.yml" ] && rm -rf "prometheus/alert_rules.yml"
  if [ ! -f "prometheus/alert_rules.yml" ]; then
    cat > prometheus/alert_rules.yml << 'RULESEOF'
groups: []
RULESEOF
    echo "Created default prometheus/alert_rules.yml"
  fi
}

ensure_grafana_permissions() {
  local dirs=("$@")

  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue

    if sudo chown -R 472:472 "$dir" 2>/dev/null; then
      sudo chmod -R u+rwX,go+rX "$dir" 2>/dev/null
      echo "Grafana directory permissions normalized for $dir (uid/gid 472)."
    elif sudo chmod -R a+rX "$dir" 2>/dev/null; then
      echo "Grafana directory permissions relaxed for $dir (world-readable fallback)."
    else
      log_warn "Unable to adjust permissions for $dir automatically."
      echo "   Please run: sudo chown -R 472:472 '$dir' && sudo chmod -R u+rwX,go+rX '$dir'"
    fi
  done
}

sanitize_metadata_artifacts() {
  local dirs=("$@")
  local cleaned=0

  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    [ -e "$dir" ] || continue

    while IFS= read -r path; do
      [ -n "$path" ] || continue
      rm -rf "$path"
      cleaned=$((cleaned + 1))
    done < <(find "$dir" \
      \( -type f \( -name '._*' -o -name '.DS_Store' \) \) -o \
      \( -type d -name '__MACOSX' \) \
      2>/dev/null)
  done

  if [ "$cleaned" -gt 0 ]; then
    echo "Removed $cleaned metadata artifact(s) from extracted assets."
  fi
}

sanitize_grafana_assets() {
  sanitize_metadata_artifacts "$@"
}

extract_tarball() {
  local archive="$1"
  local destination="$2"
  shift 2

  local err_file
  err_file="$(mktemp)"
  local status=0

  if ! tar -xzf "$archive" -C "$destination" "$@" 2>"$err_file"; then
    status=$?
  fi

  if [ -s "$err_file" ]; then
    local filtered
    filtered="$(grep -v "^tar: Ignoring unknown extended header keyword 'LIBARCHIVE\\.xattr\\." "$err_file" || true)"
    if [ -n "$filtered" ]; then
      printf '%s\n' "$filtered" >&2
    fi
  fi

  rm -f "$err_file"
  return "$status"
}

# Ensure necessary directories exist and have correct permissions
mkdir -p "$BACKUP_DIR"
mkdir -p "$BACKUP_FOLDER_PATH"

# Minimum Docker API version required (1.44 = Docker 25.0+)
MIN_API_VERSION="1.44"

# Check if Docker API version is sufficient
check_docker_api_version() {
  local api_version=$(docker version --format '{{.Client.APIVersion}}' 2>/dev/null || echo "0")
  if [ "$(printf '%s\n' "$MIN_API_VERSION" "$api_version" | sort -V | head -n1)" = "$MIN_API_VERSION" ]; then
    return 0  # Version is sufficient
  else
    return 1  # Version is too old
  fi
}

# Install/upgrade standalone docker-compose to latest version
install_latest_docker_compose() {
  echo "Docker API version is too old (requires $MIN_API_VERSION+). Installing latest docker-compose standalone..."
  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
  sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
  echo "docker-compose standalone installed."
}

# Detect docker compose command (modern plugin vs legacy standalone)
# Modern: docker compose (plugin, API 1.44+)
# Legacy: docker-compose (standalone binary)
detect_docker_compose() {
  # First check if docker compose plugin is available AND API version is sufficient
  if docker compose version >/dev/null 2>&1 && check_docker_api_version; then
    echo "docker compose"
    return 0
  fi

  # Check if standalone docker-compose exists and works
  if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    echo "docker-compose"
    return 0
  fi

  # API too old or no compose available - install latest standalone.
  # In test mode (CLI_TEST_HARNESS_MODE=1, set when invoked with
  # CT_CLI_TEST_MODE=1 + a __test_* subcommand) skip this branch —
  # install_latest_docker_compose mutates the host (writes
  # /usr/local/bin/docker-compose). Tests must stay hermetic.
  # CodeRabbit hardening on PR #76.
  if [ "${CLI_TEST_HARNESS_MODE:-0}" != "1" ]; then
    install_latest_docker_compose
    if command -v docker-compose >/dev/null 2>&1; then
      echo "docker-compose"
      return 0
    fi
  fi

  # Neither available
  echo ""
  return 1
}

# Set the docker compose command to use throughout the script. In test
# mode (CLI_TEST_HARNESS_MODE=1) detect_docker_compose's install
# fallback is suppressed, so a missing docker on a CI runner returns
# empty rather than mutating the host. Tolerate empty here too — the
# abort below would prevent test dispatch from reaching the helper at
# all on a host without docker. CodeRabbit hardening on PR #76.
DOCKER_COMPOSE_CMD=$(detect_docker_compose)
if [ -z "$DOCKER_COMPOSE_CMD" ] && [ "${CLI_TEST_HARNESS_MODE:-0}" != "1" ]; then
  echo "Error: Neither 'docker compose' nor 'docker-compose' is available."
  echo "Please install Docker with the compose plugin:"
  echo "  https://docs.docker.com/compose/install/"
  exit 1
fi

# Auto-fix systemd service file to match detected docker compose command and working directory
# This ensures the service uses the same command syntax as the CLI and correct install path
fix_systemd_service_if_needed() {
  local SERVICE_FILE="/etc/systemd/system/docker-compose-app.service"

  [ -f "$SERVICE_FILE" ] || return 0

  local needs_reload=false
  local current_cmd=""
  local target_cmd=""

  # Check and fix WorkingDirectory if it doesn't match INSTALL_DIR
  local current_workdir=$(grep "^WorkingDirectory=" "$SERVICE_FILE" 2>/dev/null | cut -d= -f2)
  if [ -n "$current_workdir" ] && [ "$current_workdir" != "$INSTALL_DIR" ]; then
    echo "Updating systemd service WorkingDirectory from $current_workdir to $INSTALL_DIR..."
    sudo cp "$SERVICE_FILE" "${SERVICE_FILE}.backup" 2>/dev/null
    sudo sed -i "s|^WorkingDirectory=.*|WorkingDirectory=$INSTALL_DIR|g" "$SERVICE_FILE"
    needs_reload=true
  fi

  # Detect what the service file currently uses for docker compose command
  if grep -q "/usr/bin/docker-compose" "$SERVICE_FILE"; then
    current_cmd="docker-compose"
  elif grep -q "/usr/bin/docker compose" "$SERVICE_FILE"; then
    current_cmd="docker compose"
  else
    if [ "$needs_reload" = true ]; then
      sudo systemctl daemon-reload
      echo "Systemd service WorkingDirectory updated."
    fi
    return 0  # Unknown format, don't touch command
  fi

  # Determine what it should use based on what's available
  if [ "$DOCKER_COMPOSE_CMD" = "docker compose" ]; then
    target_cmd="docker compose"
  else
    target_cmd="docker-compose"
  fi

  # Update if mismatch
  if [ "$current_cmd" != "$target_cmd" ]; then
    echo "Updating systemd service to use '$target_cmd'..."
    if [ "$needs_reload" != true ]; then
      sudo cp "$SERVICE_FILE" "${SERVICE_FILE}.backup" 2>/dev/null
    fi

    if [ "$target_cmd" = "docker compose" ]; then
      sudo sed -i 's|/usr/bin/docker-compose|/usr/bin/docker compose|g' "$SERVICE_FILE"
    else
      sudo sed -i 's|/usr/bin/docker compose|/usr/bin/docker-compose|g' "$SERVICE_FILE"
    fi

    needs_reload=true
    echo "Systemd service updated to use '$target_cmd'."
  fi

  # Add restart-on-failure policy if missing (boot resilience)
  if ! grep -q "^Restart=" "$SERVICE_FILE" 2>/dev/null; then
    echo "Adding restart-on-failure policy to systemd service..."
    if [ "$needs_reload" != true ]; then
      sudo cp "$SERVICE_FILE" "${SERVICE_FILE}.backup" 2>/dev/null
    fi
    # Add Restart=on-failure and RestartSec=60 after TimeoutStartSec line
    if grep -q "^TimeoutStartSec=" "$SERVICE_FILE"; then
      sudo sed -i '/^TimeoutStartSec=/a Restart=on-failure\nRestartSec=60' "$SERVICE_FILE"
    else
      # Fallback: add before [Install] section
      sudo sed -i '/^\[Install\]/i Restart=on-failure\nRestartSec=60' "$SERVICE_FILE"
    fi
    needs_reload=true
    echo "Restart policy added (on-failure, 60s delay)."
  fi

  # Add an explicit stop timeout so compose can hand SIGTERM through cleanly.
  if ! grep -q "^TimeoutStopSec=" "$SERVICE_FILE" 2>/dev/null; then
    echo "Adding TimeoutStopSec=45 to systemd service..."
    if [ "$needs_reload" != true ]; then
      sudo cp "$SERVICE_FILE" "${SERVICE_FILE}.backup" 2>/dev/null
    fi
    if grep -q "^TimeoutStartSec=" "$SERVICE_FILE"; then
      sudo sed -i '/^TimeoutStartSec=/a TimeoutStopSec=45' "$SERVICE_FILE"
    else
      sudo sed -i '/^\[Install\]/i TimeoutStopSec=45' "$SERVICE_FILE"
    fi
    needs_reload=true
    echo "Stop timeout added."
  fi

  # Add network-online.target dependency if missing (boot ordering)
  if ! grep -q "network-online.target" "$SERVICE_FILE" 2>/dev/null; then
    echo "Adding network-online.target dependency to systemd service..."
    if [ "$needs_reload" != true ]; then
      sudo cp "$SERVICE_FILE" "${SERVICE_FILE}.backup" 2>/dev/null
    fi
    sudo sed -i '/^After=docker.service/a Wants=network-online.target\nAfter=network-online.target' "$SERVICE_FILE"
    needs_reload=true
    echo "Network dependency added."
  fi

  if [ "$needs_reload" = true ]; then
    sudo systemctl daemon-reload
  fi

  # Fix NetworkManager connection autoconnect issues (no-DHCP boot problem)
  nm_heal_connections
}

# Grafana is already exposed through Caddy at /grafana, so the direct host
# port binding is redundant and can collide with other software on :3000.
# Strip that binding from appliance compose files before CLI-managed restarts.
disable_grafana_host_port_binding() {
  local compose_file="${1:-$ORIGINAL_FILE}"
  [ -f "$compose_file" ] || return 0

  if ! grep -q 'grafana/grafana' "$compose_file" 2>/dev/null; then
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  awk '
    function flush_ports() {
      if (!ports_captured) {
        return
      }

      if (port_count > 0) {
        print ports_header
        for (i = 1; i <= port_count; i++) {
          print port_lines[i]
        }
      }

      delete port_lines
      port_count = 0
      ports_captured = 0
      ports_header = ""
    }

    function is_service_boundary(line) {
      return line ~ /^  [^[:space:]][^:]*:/ && line !~ /^  grafana:[[:space:]]*$/
    }

    BEGIN {
      in_grafana = 0
      ports_captured = 0
      port_count = 0
    }

    {
      if (in_grafana && is_service_boundary($0)) {
        flush_ports()
        in_grafana = 0
      }

      if ($0 ~ /^  grafana:[[:space:]]*$/) {
        in_grafana = 1
        print
        next
      }

      if (in_grafana) {
        if (ports_captured) {
          if ($0 ~ /^      - "?3000:3000"?[[:space:]]*$/ || $0 ~ /^      - "?[$][{]GRAFANA_HOST_PORT:-3000[}]:3000"?[[:space:]]*$/) {
            next
          }

          if ($0 ~ /^      - /) {
            port_lines[++port_count] = $0
            next
          }

          flush_ports()
        }

        if ($0 ~ /^    ports:[[:space:]]*$/) {
          ports_captured = 1
          ports_header = $0
          port_count = 0
          next
        }
      }

      print
    }

    END {
      if (in_grafana) {
        flush_ports()
      }
    }
  ' "$compose_file" > "$tmp_file"

  if cmp -s "$compose_file" "$tmp_file"; then
    rm -f "$tmp_file"
    return 0
  fi

  mv "$tmp_file" "$compose_file"
  log_ok "Removed direct Grafana host port binding; use /grafana via Caddy."
}

# Restart the docker-compose systemd service with error handling.
# Checks exit code, logs diagnostics on failure, retries once.
# Returns 0 on success, 1 on failure.
restart_service() {
  local context="${1:-}" # optional caller context for log messages
  local service="docker-compose-app.service"

  # Permission precheck — must run BEFORE any destructive step.
  # Without root, `systemctl restart` will fail with polkit "Access denied"
  # AFTER we've already removed all project containers, leaving the stack
  # down. The container-group user (e.g. `calltelemetry`) can `docker rm`
  # but cannot talk to systemd. Abort now and leave containers intact.
  require_root "restart_service${context:+ ($context)}" || return 1

  # Ensure bind-mount files exist before Docker starts (prevents directory auto-creation)
  if ! ensure_postgres_password; then
    log_fail "Failed to ensure PostgreSQL password; aborting service restart"
    return 1
  fi
  if ! ensure_grafana_password; then
    log_fail "Failed to ensure Grafana password; aborting service restart"
    return 1
  fi
  ensure_bind_mount_files
  disable_grafana_host_port_binding

  # Purge ghost containers before restart.
  # Image tag changes between versions can leave stale container IDs in Docker's
  # internal state AND orphaned directories in /var/lib/docker/containers/.
  # These ghosts cause "No such container" errors on compose up — production outage.
  echo "Cleaning up containers before restart..."

  # Step 1: Remove running/stopped project containers via Docker API
  local ghost_ids
  ghost_ids=$(docker ps -a --filter "label=com.docker.compose.project=calltelemetry" --format '{{.ID}}' 2>/dev/null)
  if [ -n "$ghost_ids" ]; then
    local count=$(echo "$ghost_ids" | wc -l | tr -d ' ')
    echo "$ghost_ids" | xargs -r docker rm -f >/dev/null 2>&1 || true
    echo "  Removed $count containers"
  fi

  # Step 2: Nuke orphaned container directories that survive docker rm.
  # Docker sometimes leaves /var/lib/docker/containers/<id>/ directories
  # after the container is removed. Compose still references these IDs
  # and fails with "No such container" on up.
  local compose_containers
  compose_containers=$(docker compose config --services 2>/dev/null | wc -l)
  local docker_containers
  docker_containers=$(ls /var/lib/docker/containers/ 2>/dev/null | wc -l)
  if [ "$docker_containers" -gt "$((compose_containers + 5))" ]; then
    echo "  Detected $docker_containers container dirs (expected ~$compose_containers) — pruning Docker state..."
    docker container prune -f 2>/dev/null || true
  fi

  # Surface which profiles are active so the operator understands the
  # expected restart duration — JTAPI adds jtapi-jar-init (~40-60s), otel
  # adds grafana/prometheus/loki/tempo (~20s each), etc.
  local active_profiles
  active_profiles=$(env_get COMPOSE_PROFILES)
  if [ -n "$active_profiles" ]; then
    echo "Restarting Docker Compose service (profiles: ${active_profiles}) ..."
  else
    echo "Restarting Docker Compose service ..."
  fi

  # Run systemctl restart in the background so we can emit a heartbeat —
  # the stop+start cycle is otherwise silent and routinely takes 60–90s
  # with JTAPI profile active, which looks indistinguishable from a hang.
  systemctl restart "$service" &
  local restart_pid=$!
  local elapsed=0
  while kill -0 "$restart_pid" 2>/dev/null; do
    log_heartbeat "\r  .. %ds elapsed" "$elapsed"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  wait "$restart_pid"
  local restart_exit=$?
  if cli_quiet; then
    echo "  Restart finished in ${elapsed}s"
  else
    printf "\r  .. %ds elapsed\n" "$elapsed"
  fi

  if [ "$restart_exit" -eq 0 ]; then
    repair_compose_bridge_once || true
    echo ""
    log_ok "Docker Compose service restarted successfully."
    return 0
  fi

  # First attempt failed — capture diagnostics
  log_warn "Service restart failed (exit code: $restart_exit). Gathering diagnostics..."
  echo ""

  # Show recent journal entries for context
  echo "--- systemd journal (last 15 lines) ---"
  journalctl -u "$service" --no-pager -n 15 2>/dev/null || true
  echo "--- end journal ---"
  echo ""

  # Check if the service file itself is valid
  if ! systemctl cat "$service" >/dev/null 2>&1; then
    log_fail "Service unit file is invalid or missing."
    echo "   Check: /etc/systemd/system/$service"
    return 1
  fi

  # Reload daemon in case unit file was modified
  echo "Reloading systemd daemon and retrying..."
  systemctl daemon-reload 2>/dev/null

  if systemctl restart "$service" 2>/dev/null; then
    repair_compose_bridge_once || true
    log_ok "Service restarted on retry."
    return 0
  fi

  # Second attempt also failed
  echo ""
  log_fail "Service restart failed after retry."
  echo "   Status: $(systemctl is-active "$service" 2>/dev/null || echo 'unknown')"
  echo "   Debug:  journalctl -u $service --no-pager -n 50"
  if [ -n "$context" ]; then
    echo "   Context: $context"
  fi
  return 1
}

# ===========================================================================
# OS Automatic Updates (systemd timer for dnf update)
# ===========================================================================

CT_OS_UPDATES_SERVICE="/etc/systemd/system/ct-os-updates.service"
CT_OS_UPDATES_TIMER="/etc/systemd/system/ct-os-updates.timer"

# Resolve a schedule keyword to a systemd OnCalendar expression and label
os_updates_resolve_schedule() {
  local schedule="$1"
  case "$schedule" in
    daily)
      OS_UPDATE_CALENDAR="*-*-* 03:00:00"
      OS_UPDATE_LABEL="Daily at 3:00 AM"
      ;;
    weekly)
      OS_UPDATE_CALENDAR="Sun *-*-* 03:00:00"
      OS_UPDATE_LABEL="Weekly (Sunday at 3:00 AM)"
      ;;
    monthly)
      OS_UPDATE_CALENDAR="*-*-01 03:00:00"
      OS_UPDATE_LABEL="Monthly (1st at 3:00 AM)"
      ;;
    *)
      # Treat as a custom OnCalendar string
      OS_UPDATE_CALENDAR="$schedule"
      OS_UPDATE_LABEL="Custom ($schedule)"
      ;;
  esac
}

os_updates_status() {
  echo "OS Automatic Updates"
  echo "===================="

  if systemctl is-enabled ct-os-updates.timer &>/dev/null; then
    echo "Status:     Enabled"

    # Extract schedule from timer file
    local calendar
    calendar=$(grep "^OnCalendar=" "$CT_OS_UPDATES_TIMER" 2>/dev/null | cut -d= -f2-)
    if [ -n "$calendar" ]; then
      # Map back to friendly label
      case "$calendar" in
        "*-*-* 03:00:00")       echo "Schedule:   Daily at 3:00 AM" ;;
        "Sun *-*-* 03:00:00")   echo "Schedule:   Weekly (Sunday at 3:00 AM)" ;;
        "*-*-01 03:00:00")      echo "Schedule:   Monthly (1st at 3:00 AM)" ;;
        *)                      echo "Schedule:   Custom ($calendar)" ;;
      esac
    fi

    # Next and last trigger times
    local next_run last_run
    next_run=$(systemctl show ct-os-updates.timer --property=NextElapseUSecRealtime --value 2>/dev/null)
    last_run=$(systemctl show ct-os-updates.timer --property=LastTriggerUSec --value 2>/dev/null)

    if [ -n "$next_run" ] && [ "$next_run" != "n/a" ]; then
      echo "Next run:   $next_run"
    fi
    if [ -n "$last_run" ] && [ "$last_run" != "n/a" ]; then
      echo "Last run:   $last_run"
    fi

    echo "Jitter:     up to 30 minutes"
  else
    echo "Status:     Disabled"
    echo ""
    echo "Enable with:"
    echo "  cli.sh os-updates enable daily      Every day at 3 AM"
    echo "  cli.sh os-updates enable weekly     Every Sunday at 3 AM"
    echo "  cli.sh os-updates enable monthly    1st of each month at 3 AM"
  fi

  echo ""

  # Show recent journal entries if any exist
  local log_lines
  log_lines=$(journalctl -u ct-os-updates.service --no-pager -n 5 --output=short-iso 2>/dev/null | grep -v "^-- ")
  if [ -n "$log_lines" ]; then
    echo "Recent update history:"
    echo "$log_lines" | sed 's/^/  /'
  fi
}

os_updates_enable() {
  local schedule="${1:-weekly}"

  os_updates_resolve_schedule "$schedule"

  echo "OS Automatic Updates"
  echo "===================="
  echo "Setting up $OS_UPDATE_LABEL OS updates..."
  echo ""

  # Write the service unit
  sudo tee "$CT_OS_UPDATES_SERVICE" > /dev/null <<EOF
[Unit]
Description=CallTelemetry Automatic OS Updates
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/dnf update -y --refresh
StandardOutput=journal
StandardError=journal
EOF
  echo "  Created:  $CT_OS_UPDATES_SERVICE"

  # Write the timer unit
  sudo tee "$CT_OS_UPDATES_TIMER" > /dev/null <<EOF
[Unit]
Description=CallTelemetry OS Update Schedule ($OS_UPDATE_LABEL)

[Timer]
OnCalendar=$OS_UPDATE_CALENDAR
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF
  echo "  Created:  $CT_OS_UPDATES_TIMER"

  # Reload, enable, and start
  sudo systemctl daemon-reload
  sudo systemctl enable ct-os-updates.timer &>/dev/null
  echo "  Enabled:  ct-os-updates.timer"
  sudo systemctl start ct-os-updates.timer
  echo "  Started:  ct-os-updates.timer"

  echo ""

  # Show next run
  local next_run
  next_run=$(systemctl show ct-os-updates.timer --property=NextElapseUSecRealtime --value 2>/dev/null)
  if [ -n "$next_run" ] && [ "$next_run" != "n/a" ]; then
    echo "Next scheduled update: $next_run"
  fi

  echo ""
  echo "To check status:  cli.sh os-updates"
  echo "To disable:       cli.sh os-updates disable"
  echo "To run now:       cli.sh os-updates run"
}

os_updates_disable() {
  echo "Disabling automatic OS updates..."

  if systemctl is-enabled ct-os-updates.timer &>/dev/null; then
    sudo systemctl stop ct-os-updates.timer 2>/dev/null
    echo "  Stopped:  ct-os-updates.timer"
    sudo systemctl disable ct-os-updates.timer &>/dev/null
    echo "  Disabled: ct-os-updates.timer"
  fi

  if [ -f "$CT_OS_UPDATES_TIMER" ]; then
    sudo rm -f "$CT_OS_UPDATES_TIMER"
    echo "  Removed:  $CT_OS_UPDATES_TIMER"
  fi

  if [ -f "$CT_OS_UPDATES_SERVICE" ]; then
    sudo rm -f "$CT_OS_UPDATES_SERVICE"
    echo "  Removed:  $CT_OS_UPDATES_SERVICE"
  fi

  sudo systemctl daemon-reload

  echo ""
  echo "Automatic OS updates have been disabled."
}

os_updates_run() {
  echo "Running OS update now..."
  echo "================================================"
  sudo dnf update -y --refresh
  local exit_code=$?
  echo "================================================"
  if [ $exit_code -eq 0 ]; then
    echo "OS update complete."
  else
    echo "OS update finished with exit code $exit_code."
  fi
}

os_updates_log() {
  echo "OS Update History (last 20 entries)"
  echo "===================================="
  journalctl -u ct-os-updates.service --no-pager -n 50 --output=short-iso 2>/dev/null || echo "No update history found."
}

os_updates_cmd() {
  local action="${1:-}"
  shift 2>/dev/null || true

  case "$action" in
    ""|status)
      os_updates_status
      ;;
    enable)
      os_updates_enable "$@"
      ;;
    disable)
      os_updates_disable
      ;;
    run)
      os_updates_run
      ;;
    log|logs|history)
      os_updates_log
      ;;
    *)
      echo "Unknown os-updates command: $action"
      echo ""
      echo "Usage: cli.sh os-updates <command>"
      echo ""
      echo "Commands:"
      echo "  status              Show current schedule (default)"
      echo "  enable <schedule>   Enable automatic updates (daily|weekly|monthly)"
      echo "  disable             Disable automatic updates"
      echo "  run                 Run OS update immediately"
      echo "  log                 Show recent update history"
      return 1
      ;;
  esac
}

# ─── Network configuration ──────────────────────────────────────────────────
NETWORK_CONN_NAME="ct-network"

network_get_iface() {
  nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep ':ethernet' | head -1 | cut -d: -f1
}

network_get_conn() {
  local iface
  iface=$(network_get_iface)
  nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${iface}$" | cut -d: -f1 | head -1
}

network_cmd() {
  local subcommand="${1:-status}"
  shift || true

  case "$subcommand" in
    ""|status)
      echo "=== Network Configuration ==="
      local iface
      iface=$(network_get_iface)
      echo "Interface : ${iface:-(none detected)}"
      echo "IP        : $(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}' || echo '(none)')"
      echo "Gateway   : $(ip route 2>/dev/null | grep default | head -1 | awk '{print $3}' || echo '(none)')"
      local conn
      conn=$(network_get_conn)
      if [ -n "$conn" ]; then
        echo "DNS       : $(nmcli -g ipv4.dns connection show "$conn" 2>/dev/null | tr ',' ' ')"
        echo "Domain    : $(nmcli -g ipv4.dns-search connection show "$conn" 2>/dev/null)"
      fi
      echo ""
      echo "Commands:"
      echo "  network address <ip/prefix> <gateway>  Set static IP and gateway"
      echo "  network dns-servers <dns1> [dns2]       Set DNS servers"
      echo "  network domain <domain>                 Set DNS search domain"
      echo "  network dhcp                            Switch to DHCP"
      echo "  network fix                             Fix NM autoconnect issues (boot problem)"
      ;;

    address)
      local addr="${1:-}"
      local gateway="${2:-}"
      if [ -z "$addr" ]; then
        read -rp "IP Address with prefix (e.g. 192.168.10.50/24): " addr </dev/tty
      fi
      if [ -z "$gateway" ]; then
        read -rp "Gateway (e.g. 192.168.10.1): " gateway </dev/tty
      fi
      if [ -z "$addr" ] || [ -z "$gateway" ]; then
        echo "Error: IP address and gateway are required."
        echo "Usage: cli.sh network address <ip/prefix> <gateway>"
        exit 1
      fi
      local iface
      iface=$(network_get_iface)
      if [ -z "$iface" ]; then
        echo "Error: No ethernet interface detected."
        exit 1
      fi
      nm_heal_connections
      nmcli connection delete "$NETWORK_CONN_NAME" 2>/dev/null || true
      nmcli connection add type ethernet con-name "$NETWORK_CONN_NAME" ifname "$iface" \
        ipv4.method manual \
        ipv4.addresses "$addr" \
        ipv4.gateway "$gateway" \
        connection.autoconnect yes \
        connection.autoconnect-priority 100
      nmcli connection up "$NETWORK_CONN_NAME"
      echo "Static IP $addr configured (gateway: $gateway). Will auto-connect on boot."
      echo "Next: cli.sh network dns-servers 8.8.8.8 4.4.4.4"
      ;;

    dns-servers)
      local dns_args=("$@")
      if [ "${#dns_args[@]}" -eq 0 ]; then
        read -rp "DNS servers (e.g. 8.8.8.8 4.4.4.4): " -a dns_args </dev/tty
      fi
      if [ "${#dns_args[@]}" -eq 0 ]; then
        echo "Error: At least one DNS server is required."
        echo "Usage: cli.sh network dns-servers <dns1> [dns2]"
        exit 1
      fi
      local dns_list
      dns_list=$(IFS=,; echo "${dns_args[*]}")
      local conn
      conn=$(network_get_conn)
      if [ -z "$conn" ]; then conn="$NETWORK_CONN_NAME"; fi
      nmcli connection modify "$conn" ipv4.dns "$dns_list"
      nmcli connection up "$conn" 2>/dev/null || true
      echo "DNS servers set: ${dns_args[*]}"
      ;;

    domain)
      local domain="${1:-}"
      if [ -z "$domain" ]; then
        read -rp "Search domain (e.g. example.local): " domain </dev/tty
      fi
      if [ -z "$domain" ]; then
        echo "Error: Domain is required."
        echo "Usage: cli.sh network domain <domain>"
        exit 1
      fi
      local conn
      conn=$(network_get_conn)
      if [ -z "$conn" ]; then conn="$NETWORK_CONN_NAME"; fi
      nmcli connection modify "$conn" ipv4.dns-search "$domain"
      nmcli connection up "$conn" 2>/dev/null || true
      echo "Search domain set: $domain"
      ;;

    dhcp)
      local iface
      iface=$(network_get_iface)
      if [ -z "$iface" ]; then
        echo "Error: No ethernet interface detected."
        exit 1
      fi
      nm_heal_connections
      nmcli connection delete "$NETWORK_CONN_NAME" 2>/dev/null || true
      nmcli connection add type ethernet con-name "$NETWORK_CONN_NAME" ifname "$iface" \
        ipv4.method auto \
        connection.autoconnect yes \
        connection.autoconnect-priority 100
      nmcli connection up "$NETWORK_CONN_NAME"
      echo "DHCP configured. IP: $(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}' || echo '(acquiring...)')"
      ;;

    fix)
      nm_heal_connections
      log_ok "NM connection profiles checked."
      ;;

    *)
      echo "Unknown network command: $subcommand"
      echo "Run 'cli.sh network' for usage."
      exit 1
      ;;
  esac
}

# Function to display help
show_help() {
  echo "Usage: cli.sh <command> [options]"
  echo
  echo "Application Commands:"
  echo "  status              Show application status and diagnostics"
  echo "  update              Update to latest stable release (default)"
  echo "  update --latest     Update to latest build (including pre-releases)"
  echo "  update --dev        Update to latest release candidate (dev channel)"
  echo "                      (--rc remains as a deprecated alias)"
  echo "  update <version>    Update to specific version (e.g., 0.8.4-rc191)"
  echo "                      Options: --force-upgrade, --no-cleanup, --ipv6,"
  echo "                               --backup-db, --no-backup-db,"
  echo "                               --verbose|-v (show full transcript)"
  echo "  rollback            Roll back to a pre-upgrade snapshot (compose by default;"
  echo "                      env/db optional via flags)"
  echo "                      Options: --with-env, --with-db, --snapshot <ts>, --list"
  echo "  reset               Stop application, remove data, and restart"
  echo "  restart             Restart all services (docker compose down/up)"
  echo "  stop                Stop all services"
  echo "  start               Start all services"
  echo
  echo "User Commands:"
  echo "  users                                    List all users (id, email, roles, last login)"
  echo "  bootstrap-admin <email> <password>       Idempotently provision the first admin (creates org if none)"
  echo "  reset-password <email> <new-password>    Reset a user's password (admin override; no email is sent)"
  echo
  echo "Database Commands:"
  echo "  db                  Show database status (default)"
  echo "  db backup           Create a database backup"
  echo "  db restore <file>   Restore from a backup file"
  echo "  db list             List available backups"
  echo "  db compact          Vacuum and compact the database"
  echo "  db tables [name]    Show table sizes"
  echo "  db purge <tbl> <d>  Purge records older than <d> days from table"
  echo "  db size             Show database size"
  echo
  echo "Migration Commands:"
  echo "  migrate             Show migration status (default)"
  echo "  migrate run         Run pending migrations + partition drain"
  echo "  migrate drain       Run partition drain only (idempotent, safe to re-run)"
  echo "  migrate rollback [n] Rollback n migrations (default: 1)"
  echo "  migrate history     Show last 10 migrations from database"
  echo "  migrate watch       Watch migration progress continuously"
  echo
  echo "Configuration Commands:"
  echo "  logging [level]     Show or set logging level (debug/info/warning/error)"
  echo "  ipv6 [enable|disable] Show or toggle IPv6 support"
  echo "  network             Show current network configuration"
  echo "  network address <ip/prefix> <gw>  Set static IP and gateway"
  echo "  network dns-servers <dns1> [dns2] Set DNS servers"
  echo "  network domain <domain>           Set DNS search domain"
  echo "  network dhcp                      Switch to DHCP (automatic IP)"
  echo "  postgres            Show current PostgreSQL version"
  echo "  postgres set <ver>  Set PostgreSQL version (14, 15, 16, 17, 18)"
  echo "  postgres upgrade <ver> Upgrade PostgreSQL to new major version (backup required)"
  echo "  certs               Show certificate status and expiry"
  echo "  certs reset         Delete and regenerate self-signed certificates"
  echo "  jtapi               Show JTAPI feature status"
  echo "  jtapi enable        Enable JTAPI sidecar, ct-media, and SeaweedFS services"
  echo "  jtapi disable       Disable JTAPI services"
  echo "  jtapi troubleshoot  Run comprehensive JTAPI diagnostics"
  echo "  storage             Show SeaweedFS storage status"
  echo "  storage enable      Start SeaweedFS S3-compatible object store"
  echo "  storage disable     Stop SeaweedFS"
  echo "  syslog              Show syslog stack status"
  echo "  syslog enable       Start ct-syslog-ingest, Loki, and Alloy"
  echo "  syslog disable      Stop syslog ingest and shared logging services when unused"
  echo "  otel                Show observability stack status"
  echo "  otel enable         Start Prometheus, Grafana, Loki, Alloy, Tempo, and exporters"
  echo "  otel disable        Stop otel stack (~900 MiB freed)"
  echo
  echo "Maintenance Commands:"
  echo "  version             Print cli.sh version (${CLI_VERSION})"
  echo "  selfupdate          Update CLI script to latest version"
  echo "  fix-service         Update systemd service to use modern docker compose"
  echo "  docker              Show Docker status (containers, images, networks)"
  echo "  docker network      Show detailed network configuration"
  echo "  docker prune        Remove unused Docker resources"
  echo
  echo "OS Update Commands:"
  echo "  os-updates              Show automatic update schedule"
  echo "  os-updates enable <s>   Enable auto-updates (daily|weekly|monthly)"
  echo "  os-updates disable      Disable automatic OS updates"
  echo "  os-updates run          Run OS update now (dnf update)"
  echo "  os-updates log          Show recent update history"
  echo
  echo "Offline/Air-Gap Commands:"
  echo "  offline fetch <version>     Download pre-built bundle from cloud (fast)"
  echo "  offline download [version]  Build full bundle with Docker images (slow)"
  echo "  offline apply <bundle.tar>  Apply an offline bundle to this system"
  echo "  offline list                List images in current docker-compose.yml"
  echo
  echo "Diagnostic Commands:"
  echo "  diag network                Run comprehensive network diagnostics"
  echo "  diag service                Display systemd service and container logs"
  echo "  diag tesla <ipv4|ipv6> <url>    Test TCP + HTTP connectivity"
  echo "  diag raw_tcp <ipv4|ipv6> <url>  Test raw TCP socket only"
  echo "  diag capture <secs> [filter] [file]  Capture packets with tcpdump"
  echo "  diag database               Run comprehensive database diagnostics"
  echo "  diag db-watch               Live database activity monitor (refreshes every 2s)"
  echo
  echo "Advanced Commands:"
  echo "  build-appliance     Download and execute the prep script"
  echo "  prep-cluster-node   Prepare cluster node with necessary tools"
  echo
  echo "Use 'cli.sh <command> --help' for more information on a command."
}

# Function to update the CLI script
cli_update() {
  echo "Checking for script updates..."
  tmp_file=$(mktemp)

  # Download the latest script. Prefer wget when present, but fall back to
  # curl on wget failures so tool-specific TLS/proxy issues do not strand
  # self-update.
  if command -v wget >/dev/null 2>&1 && wget -q "$SCRIPT_URL" -O "$tmp_file"; then
    :
  elif command -v curl >/dev/null 2>&1 && curl -fsSL "$SCRIPT_URL" -o "$tmp_file"; then
    :
  else
    echo "Failed to download CLI update. Please check your internet connection."
    rm -f "$tmp_file"
    return 1
  fi

  # Verify download succeeded and file has content
  if [ ! -s "$tmp_file" ]; then
    echo "Downloaded file is empty. Update failed."
    rm -f "$tmp_file"
    return 1
  fi

  # Ensure the target directory exists
  target_dir=$(dirname "$CURRENT_SCRIPT_PATH")
  if [ ! -d "$target_dir" ]; then
    echo "Creating directory: $target_dir"
    mkdir -p "$target_dir"
  fi

  # Check if update is needed
  if [ -f "$CURRENT_SCRIPT_PATH" ]; then
    if diff "$tmp_file" "$CURRENT_SCRIPT_PATH" > /dev/null 2>&1; then
      echo "CLI script is up-to-date."
      rm -f "$tmp_file"
      return 0
    fi
    echo "Update available for the CLI script. Updating now..."
  else
    echo "Installing CLI script to: $CURRENT_SCRIPT_PATH"
  fi

  # Install/update the script
  if cp "$tmp_file" "$CURRENT_SCRIPT_PATH" && chmod +x "$CURRENT_SCRIPT_PATH"; then
    echo "CLI script updated: $CURRENT_SCRIPT_PATH"
  else
    echo "Failed to install CLI script to: $CURRENT_SCRIPT_PATH"
    rm -f "$tmp_file"
    return 1
  fi

  rm -f "$tmp_file"
}

# Pre-flight self-update for the update command.
# Downloads the latest cli.sh from GCS and re-execs so that hotfixes
# (e.g. postgres compat, preload repair) are always applied regardless
# of which release the customer is upgrading FROM.
self_update_and_reexec() {
  # Guard: skip if we already re-exec'd this invocation
  if [ "${_CT_CLI_REEXECED:-}" = "1" ]; then
    return 0
  fi

  if [ "${CT_SKIP_CLI_SELF_UPDATE:-0}" = "1" ]; then
    log_info "Local audit mode: using this cli.sh; self-update is disabled."
    return 0
  fi

  echo "Checking for cli.sh updates before upgrade..."
  local tmp_file
  tmp_file=$(mktemp)

  # Try wget first, then curl
  if ! wget -q "$SCRIPT_URL" -O "$tmp_file" 2>/dev/null && \
     ! curl -sfL "$SCRIPT_URL" -o "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    if [ -t 0 ]; then
      log_warn "Could not download latest cli.sh from GCS."
      echo -n "Continue with current (possibly outdated) cli.sh? [y/N] "
      read -r answer
      case "$answer" in
        [yY]*) echo "Continuing with local cli.sh..."; return 0 ;;
        *)     echo "Aborting upgrade."; exit 1 ;;
      esac
    else
      log_warn "Could not fetch latest cli.sh (non-interactive). Continuing with local version."
      return 0
    fi
  fi

  # Verify download
  if [ ! -s "$tmp_file" ]; then
    log_warn "Downloaded cli.sh is empty. Continuing with local version."
    rm -f "$tmp_file"
    return 0
  fi

  # Check if update needed
  if diff -q "$tmp_file" "$CURRENT_SCRIPT_PATH" >/dev/null 2>&1; then
    log_ok "cli.sh is up-to-date."
    rm -f "$tmp_file"
    return 0
  fi

  # Replace and re-exec
  echo "Newer cli.sh available. Updating and restarting upgrade..."
  if [ "${CT_CLI_FROM_STDIN:-0}" = "1" ]; then
    if cp "$tmp_file" "$CURRENT_SCRIPT_PATH" && chmod +x "$CURRENT_SCRIPT_PATH"; then
      rm -f "$tmp_file"
      log_ok "cli.sh updated: $CURRENT_SCRIPT_PATH"
      return 0
    else
      log_warn "Failed to update cli.sh. Continuing with streamed version."
      rm -f "$tmp_file"
      return 0
    fi
  fi
  if cp "$tmp_file" "$CURRENT_SCRIPT_PATH" && chmod +x "$CURRENT_SCRIPT_PATH"; then
    rm -f "$tmp_file"
    export _CT_CLI_REEXECED=1
    exec "$CURRENT_SCRIPT_PATH" update "$@"
  else
    log_warn "Failed to update cli.sh. Continuing with current version."
    rm -f "$tmp_file"
    return 0
  fi
}

# Function to extract image tags from a docker-compose file
# Resolves ${VAR:-default} patterns using values from .env
extract_images() {
  local compose_file="$1"
  # Resolve .env path from compose file directory (handle bare filenames without /)
  local compose_dir
  if echo "$compose_file" | grep -q '/'; then
    compose_dir="${compose_file%/*}"
  else
    compose_dir="."
  fi
  local env_file="${compose_dir}/.env"

  # Source .env to get version variables (if it exists)
  local env_vars=""
  if [ -f "$env_file" ]; then
    env_vars=$(grep -E '^[A-Z_]+=.' "$env_file" | grep -v '^#')
  fi

  # Extract raw image lines from services active for the current profile set,
  # then resolve env vars. A plain grep over image lines incorrectly pulls
  # opt-in profile images such as JTAPI on default installs.
  local active_profiles
  active_profiles="${COMPOSE_PROFILES:-$(printf '%s\n' "$env_vars" | awk -F= '$1 == "COMPOSE_PROFILES" { print $2; exit }')}"
  awk -v active_profiles="$active_profiles" '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function profile_enabled(profiles,   n, active, i, p) {
      if (profiles == "") return 1
      if (active_profiles == "") return 0
      n = split(active_profiles, active, ",")
      for (i = 1; i <= n; i++) {
        p = trim(active[i])
        if (p != "" && (profiles ~ "(^|[^A-Za-z0-9_-])" p "([^A-Za-z0-9_-]|$)")) return 1
      }
      return 0
    }
    function flush_service() {
      if (image != "" && image ~ /^calltelemetry\// && profile_enabled(profiles)) print image
      image = ""
      profiles = ""
    }
    /^  [A-Za-z0-9_.-]+:/ {
      flush_service()
      in_service = 1
      next
    }
    in_service && /^  [^[:space:]]/ {
      flush_service()
      in_service = 0
    }
    in_service && /^[[:space:]]+profiles:/ {
      profiles = $0
      next
    }
    in_service && /^[[:space:]]+image:/ {
      image = $0
      sub(/^[[:space:]]+image:[[:space:]]*/, "", image)
      gsub(/"/, "", image)
      next
    }
    END { flush_service() }
  ' "$compose_file" | grep -v "^$" | while read -r img; do
    # Resolve ${VAR:-default} patterns
    resolved="$img"
    while echo "$resolved" | grep -qE '\$\{[A-Z0-9_]+:-[^}]*\}'; do
      var_expr=$(echo "$resolved" | grep -oE '\$\{[A-Z0-9_]+:-[^}]*\}' | head -1)
      var_name=$(echo "$var_expr" | sed 's/\${//;s/:-.*//')
      var_default=$(echo "$var_expr" | sed 's/.*:-//;s/}//')
      var_value=$(echo "$env_vars" | grep "^${var_name}=" | head -1 | cut -d= -f2-)
      [ -z "$var_value" ] && var_value="$var_default"
      resolved=$(echo "$resolved" | sed "s|\${${var_name}:-[^}]*}|${var_value}|")
    done

    # Resolve ${VAR} patterns (no default — must come from .env)
    while echo "$resolved" | grep -qE '\$\{[A-Z0-9_]+\}'; do
      var_expr=$(echo "$resolved" | grep -oE '\$\{[A-Z0-9_]+\}' | head -1)
      var_name="${var_expr#\$\{}"
      var_name="${var_name%\}}"
      var_value=$(echo "$env_vars" | grep "^${var_name}=" | head -1 | cut -d= -f2-)
      if [ -n "$var_value" ]; then
        resolved=$(echo "$resolved" | sed "s|\${${var_name}}|${var_value}|")
      else
        break  # No value found, stop resolving
      fi
    done

    echo "$resolved"
  done
}

# Check if a single Docker image is available (local or remote).
# Prints the status line on stdout, returns 0 on available / 1 on not.
#
# Tier order — firewall-first:
#   1. docker image inspect    — already pulled locally, no network at all
#   2. Docker Hub v2 API (HTTPS) — cheap HEAD, typically unaffected by
#      corporate proxies that block the Docker daemon socket path
#   3. docker manifest inspect — uses the Docker daemon's network, which
#      is the thing that's usually blocked in restricted environments;
#      kept as final fallback for private images where the Hub API
#      requires auth
#
# This is the inverse of the historical order; the previous arrangement
# made firewall users pay the 10s manifest-inspect timeout on every
# image before falling through to the HTTPS path they could actually
# reach. Reordering + shortening timeouts cuts worst-case pre-flight
# time by ~5×. Run under parallel dispatch in check_image_availability.
check_single_image() {
  local image="$1"
  local probe_timeout="${IMAGE_CHECK_TIMEOUT:-3}"

  # Tier 1 — local cache (instant)
  if docker image inspect "$image" >/dev/null 2>&1; then
    log_ok "Available (local)"
    return 0
  fi

  # Tier 2 — Docker Hub v2 API via HTTPS (firewall-friendly, no Docker)
  local repo="${image%%:*}"        # e.g. calltelemetry/postgres
  local tag="${image##*:}"         # e.g. 14
  [ "$tag" = "$image" ] && tag="latest"
  local hub_url="https://hub.docker.com/v2/repositories/${repo}/tags/${tag}"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsIL --max-time "$probe_timeout" -o /dev/null -w '' "$hub_url" 2>/dev/null; then
      log_ok "Available (hub API)"
      return 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --timeout="$probe_timeout" --spider "$hub_url" 2>/dev/null; then
      log_ok "Available (hub API)"
      return 0
    fi
  fi

  # Tier 3 — docker manifest inspect (slowest / most firewall-prone;
  # final fallback because it authenticates via the Docker daemon and
  # thus proves pull-path access even for private images the Hub API
  # won't expose without auth).
  if timeout "$probe_timeout" bash -c "DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect '$image'" >/dev/null 2>&1; then
    log_ok "Available (registry)"
    return 0
  fi

  log_fail "Not available"
  return 1
}

# Check availability for every image in the compose file.
# Dispatches check_single_image concurrently (one background job per image)
# and streams results back to stdout once all have completed. Output is
# deterministic and matches the compose ordering so logs remain stable.
#
# Worst-case time ≈ IMAGE_CHECK_TIMEOUT (default 3s), regardless of image
# count, down from N × (timeout_tier2 + timeout_tier3) sequentially.
check_image_availability() {
  local compose_file="$1"
  local images; images=$(extract_images "$compose_file")

  echo "Checking image availability..."

  # Capture each image's output + exit code to numbered files so we can
  # print in compose-order after all parallel probes finish. Using
  # numbered files keeps ordering deterministic and avoids interleaved
  # bytes when probes finish at similar times.
  #
  # Robustness:
  #   - Validate mktemp success so we never glob `/*` as a fallback
  #   - Register an EXIT trap so a SIGINT mid-run doesn't leak /tmp dirs
  #   - Store the actual exit code of check_single_image (in a .rc
  #     sidecar file), and count failures from those — not from greping
  #     the output for '✗', which is brittle if someone ever changes
  #     the marker character or a probe emits '✗' to stderr.
  local tmp
  if ! tmp=$(mktemp -d 2>/dev/null) || [ ! -d "$tmp" ]; then
    log_fail "Unable to create temp directory for image availability checks" >&2
    return 1
  fi
  local idx=0
  local image
  for image in $images; do
    idx=$((idx + 1))
    (
      # check_single_image's own tiers are bounded by IMAGE_CHECK_TIMEOUT,
      # so the longest any probe runs is ~2 × that (tier2 + tier3).
      local slot
      slot="$tmp/$(printf '%04d' "$idx")"
      local result rc
      result=$(check_single_image "$image" 2>&1)
      rc=$?
      printf '  Checking %s... %s\n' "$image" "$result" > "$slot"
      printf '%d\n' "$rc" > "${slot}.rc"
    ) &
  done
  wait

  local failed=0
  local unavailable=""
  local f
  for f in "$tmp"/[0-9]*; do
    [ -e "$f" ] || continue
    # Skip the .rc sidecars in the display loop
    case "$f" in *.rc) continue;; esac
    # Per-image result line is verbose-only; failures still surface via
    # the unavailable list below (and log_fail).
    cli_verbose && cat "$f"
    local rc=1
    [ -f "${f}.rc" ] && rc=$(cat "${f}.rc")
    if [ "$rc" -ne 0 ]; then
      failed=$((failed + 1))
      # sed trims "  Checking <image>... …" → "<image>"
      unavailable="$unavailable$(sed -E 's/^  Checking (.+)\.\.\. .*/\1/' "$f")\n"
    fi
  done

  if [ "$failed" -eq 0 ]; then
    rm -rf "$tmp"
    log_ok "All images are available"
    return 0
  fi
  log_fail "$failed image(s) not available:"
  echo -e "$unavailable"
  rm -rf "$tmp"
  return 1
}

# Download and extract the pre-built config bundle from GCS
# This consolidates all config files: docker-compose.yml, prometheus, grafana, cli.sh, etc.
# ── download_bundle decomposition ───────────────────────────────────────
#
# 253-line download_bundle() did four jobs: fetch the tarball, extract
# it, merge version pins into .env, and deploy a long list of config
# assets. This splits each job into its own helper so the orchestrator
# is ~35 lines, each phase is individually testable, and we can bolt
# on SHA-256 verification as a new step without buried diff noise.
#
# Helpers:
#   _bundle_fetch              — wget→curl→error chain to fetch the
#                                tarball + sidecar .sha256 from GCS
#   _bundle_verify_checksum    — sha256sum -c; warn (not fail) on missing
#                                sidecar, fail hard on mismatch (new —
#                                previously unverified in this path)
#   _bundle_extract_tarball    — extract + sanitize metadata + move
#                                docker-compose.yml to TEMP_FILE for
#                                validation. Fails if compose.yml is
#                                missing from the bundle.
#   _bundle_merge_env_pins     — merge *_VERSION keys from bundle .env
#                                into live .env; preserves user
#                                customizations (secrets, profiles)
#   _bundle_deploy_configs     — per-asset copy/move of all the config
#                                files (prometheus, grafana, Caddyfile,
#                                otel, tempo, loki, alloy, nats.conf,
#                                .env.example, cli.sh self-update,
#                                postgres-bitnami-convert.sh,
#                                seaweedfs-s3.json)

_bundle_fetch() {
  local version="$1"
  local bundle_name="$2"
  local bundle_url="${GCS_BUNDLE_BASE_URL}/${version}/${bundle_name}"

  # The section header `▸ Downloading release bundle` is already printed by
  # the caller (log_step). The wget/curl progress bar below is the actual
  # progress indicator — no need for a redundant intro line.
  log_verbose "Downloading config bundle for version $version..."

  # wget→curl: try wget first, but if wget is installed and *fails*,
  # fall back to curl rather than aborting (CodeRabbit finding on PR
  # #77 — `if-elif` never reached the curl branch when wget existed
  # but errored). Detect failure either way before declaring lost.
  local fetched=0
  if command -v wget >/dev/null 2>&1; then
    if wget -q --show-progress "$bundle_url" -O "$bundle_name" 2>&1; then
      fetched=1
    else
      rm -f "$bundle_name"
    fi
  fi
  if [ "$fetched" -ne 1 ] && command -v curl >/dev/null 2>&1; then
    if curl -fL --progress-bar "$bundle_url" -o "$bundle_name"; then
      fetched=1
    else
      rm -f "$bundle_name"
    fi
  fi
  if [ "$fetched" -ne 1 ]; then
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
      echo "Error: Neither wget nor curl is available"
      return 1
    fi
    echo ""
    log_fail "Failed to download bundle from GCS"
    echo "URL: $bundle_url"
    echo ""
    echo "Possible causes:"
    echo "  - Version $version may not exist"
    echo "  - Network connectivity issue"
    echo ""
    echo "Check available releases at:"
    echo "  https://github.com/calltelemetry/calltelemetry/releases"
    return 1
  fi

  log_verbose_ok "Bundle downloaded"

  # Fetch the .sha256 sidecar if available. Failure to fetch is non-fatal
  # (older releases may not have shipped a sidecar) — _bundle_verify_checksum
  # treats a missing sidecar as a warn-and-proceed. Same wget→curl chain
  # so a flaky wget doesn't silently skip integrity verification when
  # curl could have fetched the sidecar fine.
  local checksum_url="${bundle_url}.sha256"
  local checksum_file="${bundle_name}.sha256"
  if command -v wget >/dev/null 2>&1; then
    wget -q "$checksum_url" -O "$checksum_file" 2>/dev/null || rm -f "$checksum_file"
  fi
  if [ ! -f "$checksum_file" ] && command -v curl >/dev/null 2>&1; then
    curl -sfL "$checksum_url" -o "$checksum_file" 2>/dev/null || rm -f "$checksum_file"
  fi

  return 0
}

_bundle_verify_checksum() {
  local bundle_name="$1"
  local checksum_file="${bundle_name}.sha256"

  if [ ! -f "$checksum_file" ]; then
    log_warn "No .sha256 sidecar for this bundle — skipping integrity check"
    return 0
  fi

  if ! command -v sha256sum >/dev/null 2>&1; then
    log_warn "sha256sum not available — skipping integrity check"
    rm -f "$checksum_file"
    return 0
  fi

  # The build writes `<hash>  <filename>` format which sha256sum -c expects.
  # Quiet mode: we log success/failure ourselves for a cleaner operator view.
  if sha256sum -c "$checksum_file" >/dev/null 2>&1; then
    log_verbose_ok "Bundle checksum verified"
    rm -f "$checksum_file"
    return 0
  fi

  log_fail "Bundle checksum MISMATCH — refusing to install potentially corrupt archive"
  echo "  Expected (from $checksum_file):"
  sed 's/^/    /' "$checksum_file"
  echo "  Got:"
  printf '    %s  %s\n' "$(sha256sum "$bundle_name" | awk '{print $1}')" "$bundle_name"
  echo ""
  # download_bundle() already removes the bundle when this helper returns
  # nonzero (Copilot finding on PR #77). Tell the operator that, instead
  # of instructing them to rm a file that's about to be cleaned up.
  echo "  The downloaded bundle will be removed automatically."
  echo "  Re-run update to fetch a fresh copy."
  rm -f "$checksum_file"
  return 1
}

_bundle_extract_tarball() {
  local bundle_name="$1"
  local extract_dir="$2"

  # Per-phase progress is gated behind cli_verbose to keep the
  # quiet-by-default transcript from PR #69 intact — orchestrator
  # prints a single "All config files extracted" summary at the end
  # (Copilot finding on PR #77).
  log_verbose "Extracting config files..."
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  if ! extract_tarball "$bundle_name" "$extract_dir" --strip-components=1; then
    log_fail "Failed to extract bundle"
    return 1
  fi

  sanitize_metadata_artifacts "$extract_dir"

  # Move docker-compose.yml to TEMP_FILE for validation by the caller.
  # A bundle missing compose.yml is unusable — hard-fail.
  if [ ! -f "$extract_dir/docker-compose.yml" ]; then
    log_fail "Bundle missing docker-compose.yml"
    return 1
  fi
  mv "$extract_dir/docker-compose.yml" "$TEMP_FILE"
  log_verbose_ok "docker-compose.yml"
  return 0
}

_bundle_merge_env_pins() {
  local extract_dir="$1"

  # Merge version pins from bundle's .env into the live .env.
  # Only *_VERSION keys are merged (auto-discovered — catches new keys
  # like CT_SYSLOG_INGEST_VERSION without needing a script update).
  # Everything else in the existing .env (secrets, profiles, network,
  # operator overrides) is preserved.
  if [ ! -f "$extract_dir/.env" ]; then
    return 0
  fi

  if [ ! -f "$ENV_FILE" ]; then
    cp "$extract_dir/.env" "$ENV_FILE"
    # Restore .env ownership to INSTALL_USER — cp under sudo leaves it
    # root:root, which then breaks subsequent non-root env_set/env_remove
    # calls. Same idiom env_set/env_remove use (Copilot finding on PR #77).
    _env_restore_owner
    log_verbose_ok ".env (created from bundle)"
    return 0
  fi

  grep -E '^[A-Z_]+_VERSION=' "$extract_dir/.env" | grep -v '^#' | while IFS='=' read -r key val; do
    if [ -n "$key" ] && [ -n "$val" ]; then
      env_set "$key" "$val"
    fi
  done
  log_verbose_ok ".env (version pins merged)"
}

_bundle_deploy_configs() {
  local extract_dir="$1"

  # .env.example -> always overwrite template
  if [ -f "$extract_dir/.env.example" ]; then
    cp "$extract_dir/.env.example" ./.env.example
    log_verbose_ok ".env.example"
  fi

  # cli.sh -> update current script
  if [ -f "$extract_dir/cli.sh" ]; then
    if ! diff -q "$extract_dir/cli.sh" "$CURRENT_SCRIPT_PATH" >/dev/null 2>&1; then
      local bundled_cli_version current_cli_version
      bundled_cli_version=$(sed -n 's/^CLI_VERSION="\([^"]*\)".*/\1/p' "$extract_dir/cli.sh" | head -1)
      current_cli_version=$(sed -n 's/^CLI_VERSION="\([^"]*\)".*/\1/p' "$CURRENT_SCRIPT_PATH" 2>/dev/null | head -1)
      if [ -n "$bundled_cli_version" ] && [ -n "$current_cli_version" ] &&
         [ "$(printf '%s\n' "$bundled_cli_version" "$current_cli_version" | sort -V | head -n1)" = "$bundled_cli_version" ] &&
         [ "$bundled_cli_version" != "$current_cli_version" ]; then
        log_verbose_ok "cli.sh (kept newer ${current_cli_version}; skipped bundled ${bundled_cli_version})"
      else
        # Resolve symlinks before atomic mv. If CURRENT_SCRIPT_PATH is a
        # symlink (e.g. /usr/local/bin/ct-cli -> /opt/calltelemetry/cli.sh),
        # mv -f against the symlink path would replace the symlink itself
        # with a regular file, breaking any callers that rely on the link.
        # Stage next to the real target and replace the underlying file
        # so the symlink chain stays intact.
        local target_path staged_cli
        target_path=$(readlink -f "$CURRENT_SCRIPT_PATH" 2>/dev/null)
        [ -n "$target_path" ] || target_path="$CURRENT_SCRIPT_PATH"
        staged_cli="${target_path}.new.$$"
        if cp "$extract_dir/cli.sh" "$staged_cli" && chmod +x "$staged_cli" && mv -f "$staged_cli" "$target_path"; then
          log_verbose_ok "cli.sh (updated)"
        else
          rm -f "$staged_cli"
          log_warn "cli.sh (failed to update — check permissions and disk space)"
        fi
      fi
    else
      log_verbose_ok "cli.sh (no changes)"
    fi
  fi

  # postgres-bitnami-convert.sh -> install/update compatibility repair helper.
  # Write to INSTALL_DIR explicitly so repair_postgres_compat can always find it
  # regardless of the caller's CWD. Surface cp/chmod failures so we don't claim
  # success on a permissions/disk error — repair_postgres_compat would then
  # fall back to a stale helper or warn about a missing one.
  if [ -f "$extract_dir/${POSTGRES_COMPAT_SCRIPT}" ]; then
    local dst="${INSTALL_DIR}/${POSTGRES_COMPAT_SCRIPT}"
    if ! diff -q "$extract_dir/${POSTGRES_COMPAT_SCRIPT}" "$dst" >/dev/null 2>&1; then
      if cp "$extract_dir/${POSTGRES_COMPAT_SCRIPT}" "$dst" && chmod +x "$dst"; then
        log_verbose_ok "${POSTGRES_COMPAT_SCRIPT} (updated)"
      else
        log_warn "${POSTGRES_COMPAT_SCRIPT} (failed to install to ${dst} — check permissions and disk space)"
      fi
    else
      log_verbose_ok "${POSTGRES_COMPAT_SCRIPT} (no changes)"
    fi
  fi

  # image-digests.tsv -> expected registry digests for this release bundle.
  # cli.sh update pulls immutable image@sha256 references and then tags them
  # back to the compose image names, avoiding mutable-tag drift.
  local digest_dst digest_tmp
  digest_dst=$(_image_digest_manifest_path)
  digest_tmp=$(_image_digest_manifest_tmp_path)
  if [ -f "$extract_dir/image-digests.tsv" ]; then
    if cp "$extract_dir/image-digests.tsv" "$digest_tmp"; then
      log_verbose_ok "image-digests.tsv"
    else
      rm -f "$digest_tmp"
      log_warn "image-digests.tsv (failed to stage to ${digest_tmp}; image pulls will use tags)"
    fi
  else
    rm -f "$digest_tmp"
  fi

  # prometheus configs — rm -rf guards against Docker-created-directory gotcha
  if [ -f "$extract_dir/prometheus/prometheus.yml" ]; then
    mkdir -p prometheus
    rm -f prometheus/prometheus.yml 2>/dev/null
    if mv -f "$extract_dir/prometheus/prometheus.yml" prometheus/; then
      log_verbose_ok "prometheus/prometheus.yml"
    else
      log_warn "prometheus/prometheus.yml (failed to move — check permissions)"
    fi
  fi

  if [ -f "$extract_dir/alert_rules.yml" ]; then
    mkdir -p prometheus
    [ -d "prometheus/alert_rules.yml" ] && rm -rf "prometheus/alert_rules.yml" && log_warn "prometheus/alert_rules.yml (replaced Docker-created directory with file)"
    if cp "$extract_dir/alert_rules.yml" prometheus/alert_rules.yml; then
      log_verbose_ok "prometheus/alert_rules.yml"
    else
      log_warn "prometheus/alert_rules.yml (failed to copy — check permissions)"
    fi
  fi

  if [ -f "$extract_dir/custom_rules.yml" ]; then
    mkdir -p prometheus
    [ -d "prometheus/custom_rules.yml" ] && rm -rf "prometheus/custom_rules.yml" && log_warn "prometheus/custom_rules.yml (replaced Docker-created directory with file)"
    if cp "$extract_dir/custom_rules.yml" prometheus/custom_rules.yml; then
      log_verbose_ok "prometheus/custom_rules.yml"
    else
      log_warn "prometheus/custom_rules.yml (failed to copy — check permissions)"
    fi
  fi

  # alertmanager/alertmanager.yml
  if [ -f "$extract_dir/alertmanager/alertmanager.yml" ]; then
    mkdir -p alertmanager
    # Remove if Docker auto-created it as a directory (common bind-mount gotcha)
    [ -d "alertmanager/alertmanager.yml" ] && rm -rf "alertmanager/alertmanager.yml"
    rm -f alertmanager/alertmanager.yml 2>/dev/null
    if mv -f "$extract_dir/alertmanager/alertmanager.yml" alertmanager/; then
      log_verbose_ok "alertmanager/alertmanager.yml"
    else
      log_warn "alertmanager/alertmanager.yml (failed to move — check permissions)"
    fi
  fi

  # grafana dashboards and provisioning
  if [ -d "$extract_dir/grafana" ]; then
    mkdir -p grafana/dashboards grafana/provisioning/datasources grafana/provisioning/dashboards

    # Copy dashboards
    if [ -d "$extract_dir/grafana/dashboards" ]; then
      cp -r "$extract_dir/grafana/dashboards/"* grafana/dashboards/ 2>/dev/null && log_verbose_ok "grafana/dashboards"
    fi

    # Copy provisioning
    if [ -d "$extract_dir/grafana/provisioning" ]; then
      cp -r "$extract_dir/grafana/provisioning/"* grafana/provisioning/ 2>/dev/null && log_verbose_ok "grafana/provisioning"
    fi

    sanitize_grafana_assets grafana/dashboards grafana/provisioning
  fi

  # nats.conf
  if [ -f "$extract_dir/nats.conf" ]; then
    rm -f ./nats.conf 2>/dev/null
    if cp "$extract_dir/nats.conf" ./nats.conf; then
      log_verbose_ok "nats.conf"
    else
      log_warn "nats.conf (failed to copy — check permissions)"
    fi
  fi

  # Caddyfile
  if [ -f "$extract_dir/Caddyfile" ]; then
    if [ -f "./Caddyfile" ]; then
      if ! diff -q "$extract_dir/Caddyfile" "./Caddyfile" >/dev/null 2>&1; then
        rm -f ./Caddyfile 2>/dev/null
        cp "$extract_dir/Caddyfile" ./Caddyfile
        log_verbose_ok "Caddyfile (updated)"
      else
        log_verbose_ok "Caddyfile (no changes)"
      fi
    else
      cp "$extract_dir/Caddyfile" ./Caddyfile
      log_verbose_ok "Caddyfile (installed)"
    fi
  fi

  # seaweedfs-s3.json (required for JTAPI S3 storage)
  if [ -f "$extract_dir/seaweedfs-s3.json" ]; then
    rm -rf ./seaweedfs-s3.json 2>/dev/null
    if cp "$extract_dir/seaweedfs-s3.json" ./seaweedfs-s3.json; then
      log_verbose_ok "seaweedfs-s3.json"
    else
      log_warn "seaweedfs-s3.json (failed to copy — check permissions)"
    fi
  fi

  # otel-collector config
  if [ -f "$extract_dir/otel-collector/otel-collector-config.yaml" ]; then
    mkdir -p ./otel-collector
    # Docker may have created config.yaml as a directory — remove it first
    if [ -d "./otel-collector/otel-collector-config.yaml" ]; then
      rm -rf "./otel-collector/otel-collector-config.yaml"
      log_warn "otel-collector-config.yaml (replaced Docker-created directory with file)"
    fi
    if cp "$extract_dir/otel-collector/otel-collector-config.yaml" ./otel-collector/otel-collector-config.yaml; then
      log_verbose_ok "otel-collector-config.yaml"
    else
      log_warn "otel-collector-config.yaml (failed to copy — check permissions)"
    fi
  fi

  # Tempo config
  if [ -f "$extract_dir/tempo/tempo.yaml" ]; then
    mkdir -p ./tempo
    [ -d "./tempo/tempo.yaml" ] && rm -rf "./tempo/tempo.yaml" && log_warn "tempo/tempo.yaml (replaced Docker-created directory with file)"
    if cp "$extract_dir/tempo/tempo.yaml" ./tempo/tempo.yaml; then
      log_verbose_ok "tempo/tempo.yaml"
    else
      log_warn "tempo/tempo.yaml (failed to copy — check permissions)"
    fi
  fi

  # Loki config
  if [ -f "$extract_dir/loki/loki.yaml" ]; then
    mkdir -p ./loki
    [ -d "./loki/loki.yaml" ] && rm -rf "./loki/loki.yaml" && log_warn "loki/loki.yaml (replaced Docker-created directory with file)"
    if cp "$extract_dir/loki/loki.yaml" ./loki/loki.yaml; then
      log_verbose_ok "loki/loki.yaml"
    else
      log_warn "loki/loki.yaml (failed to copy — check permissions)"
    fi
  fi

  # Alloy config
  if [ -f "$extract_dir/alloy/config.alloy" ]; then
    mkdir -p ./alloy
    [ -d "./alloy/config.alloy" ] && rm -rf "./alloy/config.alloy" && log_warn "alloy/config.alloy (replaced Docker-created directory with file)"
    if cp "$extract_dir/alloy/config.alloy" ./alloy/config.alloy; then
      log_verbose_ok "alloy/config.alloy"
    else
      log_warn "alloy/config.alloy (failed to copy — check permissions)"
    fi
  fi

}

download_bundle() {
  local version="$1"
  local bundle_name="calltelemetry-bundle-${version}.tar.gz"
  local extract_dir="bundle-extract-$$"

  _bundle_fetch "$version" "$bundle_name" || return 1

  if ! _bundle_verify_checksum "$bundle_name"; then
    rm -f "$bundle_name"
    return 1
  fi

  if ! _bundle_extract_tarball "$bundle_name" "$extract_dir"; then
    rm -f "$bundle_name"
    rm -rf "$extract_dir"
    return 1
  fi

  _bundle_merge_env_pins "$extract_dir"

  if ! normalize_ct_media_bundle "$version"; then
    rm -f "$bundle_name"
    rm -rf "$extract_dir"
    return 1
  fi

  _bundle_deploy_configs "$extract_dir"

  rm -f "$bundle_name"
  rm -rf "$extract_dir"

  # One quiet line for the whole section. Per-file detail is gated behind
  # cli_verbose / CLI_VERBOSE=1; warnings still surface unconditionally.
  log_ok "Bundle ready"
  return 0
}

# Download Prometheus configuration when the compose file defines the service.
download_prometheus_config() {
  local compose_file="$1"

  if ! grep -q 'prom/prometheus' "$compose_file"; then
    return 0
  fi

  local mapping_line
  mapping_line=$(grep -E '\./[^:]*prometheus\.yml:/etc/prometheus/prometheus\.yml' "$compose_file" | head -1 | sed 's/^[[:space:]-]*//')

  local host_path
  if [ -n "$mapping_line" ]; then
    host_path=${mapping_line%%:*}
  else
    host_path="./prometheus/prometheus.yml"
  fi

  host_path=$(echo "$host_path" | tr -d '"')
  local dest_path="${host_path#./}"
  if [ -z "$dest_path" ]; then
    dest_path="prometheus/prometheus.yml"
  fi

  local dest_dir
  dest_dir=$(dirname "$dest_path")
  if [ "$dest_dir" != "." ]; then
    mkdir -p "$dest_dir"
  fi

  local tmp_file
  tmp_file=$(mktemp)
  if wget -q "$PROMETHEUS_CONFIG_URL" -O "$tmp_file"; then
    mv "$tmp_file" "$dest_path"
    echo "Prometheus configuration downloaded to $dest_path."
  else
    log_warn "Failed to download Prometheus configuration from $PROMETHEUS_CONFIG_URL"
    rm -f "$tmp_file"
    return 1
  fi
}

# Download Grafana provisioning and dashboard assets when Grafana is enabled.
download_grafana_assets() {
  local compose_file="$1"

  if ! grep -q 'grafana/grafana' "$compose_file"; then
    return 0
  fi

  local provisioning_mount
  provisioning_mount=$(grep -E '\./[^:]*grafana/provisioning:/etc/grafana/provisioning' "$compose_file" | head -1 | sed 's/^[[:space:]-]*//')
  if [ -z "$provisioning_mount" ]; then
    provisioning_mount="./grafana/provisioning"
  else
    provisioning_mount=${provisioning_mount%%:*}
  fi
  provisioning_mount=${provisioning_mount%/}
  provisioning_mount=${provisioning_mount#./}
  if [ -z "$provisioning_mount" ]; then
    provisioning_mount="grafana/provisioning"
  fi

  local dashboards_mount
  dashboards_mount=$(grep -E '\./[^:]*grafana/dashboards:/var/lib/grafana/dashboards' "$compose_file" | head -1 | sed 's/^[[:space:]-]*//')
  if [ -z "$dashboards_mount" ]; then
    dashboards_mount="./grafana/dashboards"
  else
    dashboards_mount=${dashboards_mount%%:*}
  fi
  dashboards_mount=${dashboards_mount%/}
  dashboards_mount=${dashboards_mount#./}
  if [ -z "$dashboards_mount" ]; then
    dashboards_mount="grafana/dashboards"
  fi

  local asset
  for asset in "${GRAFANA_ASSET_PATHS[@]}"; do
    local dest_path
    if [[ "$asset" == grafana/provisioning/* ]]; then
      dest_path="$provisioning_mount/${asset#grafana/provisioning/}"
    elif [[ "$asset" == grafana/dashboards/* ]]; then
      dest_path="$dashboards_mount/${asset#grafana/dashboards/}"
    else
      dest_path="$asset"
    fi

    mkdir -p "$(dirname "$dest_path")"

    local tmp_file
    tmp_file=$(mktemp)
    if wget -q "${GRAFANA_ASSETS_BASE_URL}/${asset}" -O "$tmp_file"; then
      mv "$tmp_file" "$dest_path"
      echo "Grafana asset synced: $dest_path"
    else
      log_warn "Failed to download Grafana asset: ${asset}"
      rm -f "$tmp_file"
    fi
  done

  sanitize_grafana_assets "$provisioning_mount" "$dashboards_mount"
  ensure_grafana_permissions "$provisioning_mount" "$dashboards_mount"
}

# Detect host vCPU count. Returns 0 with _LAST_CPU_COUNT set on success
# (global, not `export`ed), non-zero on detection failure. Linux first via
# `nproc` (coreutils) with a /proc/cpuinfo fallback for minimal images;
# macOS via `sysctl -n hw.ncpu` (for test runs — appliance targets are
# always Linux).
#
# Testing hook: `CT_CLI_TEST_CPU_COUNT` overrides the detected value. Used by
# ova/test_cpu_preflight.sh to exercise the check_cpu / ensure_cpu_defaults
# decision logic across 1/2/3/4/8-vCPU scenarios without needing real hosts.
# Any non-positive-integer value (e.g. `CT_CLI_TEST_CPU_COUNT=x`) simulates a
# detection failure so the rc=3 path is exercised.
_detect_cpu_count() {
  if [ -n "${CT_CLI_TEST_CPU_COUNT:-}" ]; then
    case "$CT_CLI_TEST_CPU_COUNT" in
      ''|*[!0-9]*)
        _LAST_CPU_COUNT=""
        return 1
        ;;
    esac
    if [ "$CT_CLI_TEST_CPU_COUNT" -lt 1 ]; then
      _LAST_CPU_COUNT=""
      return 1
    fi
    _LAST_CPU_COUNT="$CT_CLI_TEST_CPU_COUNT"
    return 0
  fi

  local count=""
  if [ "$(uname)" = "Linux" ]; then
    count=$(nproc 2>/dev/null)
    if [ -z "$count" ] && [ -r /proc/cpuinfo ]; then
      count=$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null)
    fi
  elif [ "$(uname)" = "Darwin" ]; then
    count=$(sysctl -n hw.ncpu 2>/dev/null)
  fi

  case "$count" in
    ''|*[!0-9]*)
      _LAST_CPU_COUNT=""
      return 1
      ;;
  esac

  if [ "$count" -lt 1 ]; then
    _LAST_CPU_COUNT=""
    return 1
  fi

  _LAST_CPU_COUNT="$count"
  return 0
}

# CPU preflight. Exit codes:
#   0  host has >= 4 vCPUs (current recommended target)
#   1  host has 2-3 vCPUs — can proceed but container limits must be scaled
#      down via ensure_cpu_defaults before compose restart
#   2  host has < 2 vCPUs — cannot proceed; Docker will refuse container
#      creation regardless of env-var tuning (db container quota would
#      round down to 0 cgroup units)
#   3  detection failure — treat as "probably fine" at caller discretion
check_cpu() {
  local recommended_cpus=4
  local minimum_cpus=2

  if ! _detect_cpu_count; then
    return 3
  fi

  if [ "$_LAST_CPU_COUNT" -lt "$minimum_cpus" ]; then
    return 2
  fi

  if [ "$_LAST_CPU_COUNT" -lt "$recommended_cpus" ]; then
    return 1
  fi

  return 0
}

# Write CPU-sizing env vars into .env based on host vCPU count, so the
# compose file's cpus: directives resolve to values Docker will accept.
# Only writes defaults — preserves operator overrides already in .env.
#
# Sizing policy (50% of host CPUs for DB, floor 1.0; 12.5% for syslog, floor 0.5):
#   host >= 4 vCPUs  — db=2.0+, syslog=0.5+
#   host == 3 vCPUs  — db=1.5,  syslog=0.5
#   host == 2 vCPUs  — db=1.0,  syslog=0.5
#   host <  2 vCPUs  — never reached (check_cpu returns 2, caller aborts)
ensure_cpu_defaults() {
  if ! _detect_cpu_count; then
    log_warn "Could not detect CPU count — skipping .env CPU-limit defaults."
    return 0
  fi

  # DB gets 50% of host CPUs (floor 1.0). syslog gets 12.5% (floor 0.5).
  local db_limit syslog_limit
  db_limit=$(awk -v n="$_LAST_CPU_COUNT" 'BEGIN { v = n * 0.5; if (v < 1.0) v = 1.0; printf "%.1f", v }')
  syslog_limit=$(awk -v n="$_LAST_CPU_COUNT" 'BEGIN { v = n * 0.125; if (v < 0.5) v = 0.5; printf "%.1f", v }')

  env_set_default "DB_CPU_LIMIT" "$db_limit"
  env_set_default "CT_SYSLOG_INGEST_CPU_LIMIT" "$syslog_limit"

  log_verbose_ok "CPU defaults applied: DB_CPU_LIMIT=$(env_get "DB_CPU_LIMIT"), CT_SYSLOG_INGEST_CPU_LIMIT=$(env_get "CT_SYSLOG_INGEST_CPU_LIMIT")"
}

# Function to check RAM availability
check_ram() {
  local required_ram_mb=7168  # 7GB minimum (allowing some tolerance for 8GB systems)

  # Get total RAM in MB (works on Linux)
  if [ "$(uname)" == "Linux" ]; then
    total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_ram_mb=$((total_ram_kb / 1024))
  elif [ "$(uname)" == "Darwin" ]; then
    # For macOS (testing purposes)
    total_ram_bytes=$(sysctl -n hw.memsize)
    total_ram_mb=$((total_ram_bytes / 1024 / 1024))
  else
    echo "Error: Unable to detect RAM on this system"
    return 1
  fi

  # Calculate GB using shell arithmetic (no bc needed)
  total_ram_gb=$((total_ram_mb / 1024))
  total_ram_gb_decimal=$((total_ram_mb * 10 / 1024 % 10))
  echo "Detected RAM: ${total_ram_mb}MB (${total_ram_gb}.${total_ram_gb_decimal}GB)"

  if [ "$total_ram_mb" -lt "$required_ram_mb" ]; then
    echo "Required RAM: Minimum 7GB (8GB recommended)"
    return 1
  fi
  return 0
}

# Function to check disk space
check_disk_space() {
  local required_percent=10
  local available_percent=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
  local used_percent=$available_percent
  local free_percent=$((100 - used_percent))

  if [ "$free_percent" -lt "$required_percent" ]; then
    return 1
  fi
  return 0
}

# Quick disk-speed probe: ~2MB of 4K direct-I/O writes, wall-clock timed.
# A cheap heuristic — NOT a benchmark. Cloud disks with noisy neighbors
# can briefly look slow and recover. A below-threshold reading is a
# soft gate, not a veto: interactive callers prompt the operator, while
# non-TTY callers abort unless --force-upgrade is passed (see the
# consumer in _update_preflight_checks for the enforcement policy).
#
# Exit codes:
#   0 — measured IOPS >= CHECK_DISK_IOPS_THRESHOLD (default 1000)
#   1 — measured IOPS below threshold (includes the timeout(1) case
#       where the probe exceeded CHECK_DISK_IOPS_TIMEOUT — in that
#       case _LAST_IOPS is set to 0)
#   2 — test skipped (direct-I/O rejected by filesystem, dd missing,
#       date +%s%N unavailable on a BSD box, etc.)
#
# Side effect: sets the module-level _LAST_IOPS so the caller can include
# the number in the OK / WARN message.
check_disk_iops() {
  local threshold="${CHECK_DISK_IOPS_THRESHOLD:-1000}"
  local probe_timeout="${CHECK_DISK_IOPS_TIMEOUT:-15}"
  local block_count=500
  local tmpfile start end elapsed_ns iops dd_rc

  _LAST_IOPS=""

  # Sanitize env overrides — a malformed value (e.g. 'high' / '15s' /
  # '-1') would either break arithmetic or, worse, silently bypass the
  # gate. Fall back to the documented defaults on anything non-positive-
  # integer.
  if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -le 0 ]; then
    threshold=1000
  fi
  if ! [[ "$probe_timeout" =~ ^[0-9]+$ ]] || [ "$probe_timeout" -le 0 ]; then
    probe_timeout=15
  fi

  if ! command -v dd >/dev/null 2>&1; then
    return 2
  fi

  # Probe the same filesystem the upgrade will actually write to
  # (bundle extract, backup dump, config rewrite all live under
  # INSTALL_DIR). Fall back to /tmp only if INSTALL_DIR isn't writable.
  local probe_dir="$INSTALL_DIR"
  if ! [ -w "$probe_dir" ]; then
    probe_dir="/tmp"
  fi

  tmpfile=$(mktemp "${probe_dir}/.cli-iops-XXXXXX" 2>/dev/null) || return 2

  start=$(date +%s%N 2>/dev/null)
  # `date +%s%N` returns the literal string `N` on macOS and some BSDs
  # that don't support nanosecond precision — the empty-string test
  # alone would miss that and fail the later arithmetic. Require all-digits.
  case "$start" in
    ''|*[!0-9]*) rm -f "$tmpfile"; return 2 ;;
  esac

  # oflag=direct bypasses the page cache so we measure the disk, not RAM.
  # conv=fdatasync ensures the final buffer is flushed before we stop the
  # clock. Some filesystems (tmpfs, overlayfs, some CIFS/NFS variants)
  # reject O_DIRECT — dd exits non-zero and we skip cleanly.
  #
  # timeout(1) bounds the probe: wedged storage (iSCSI path drop, SAN
  # failover, failing drive) can make dd block indefinitely and stall
  # the whole upgrade. Exit 124 from timeout means 500 4K ops didn't
  # finish in 15s — that's at most ~33 IOPS, well below any reasonable
  # threshold, so we report it as a below-threshold failure (not a
  # "probe skipped") so the caller's prompt fires.
  if command -v timeout >/dev/null 2>&1; then
    timeout "${probe_timeout}s" dd if=/dev/zero of="$tmpfile" bs=4k count="$block_count" \
      oflag=direct conv=fdatasync 2>/dev/null
    dd_rc=$?
  else
    dd if=/dev/zero of="$tmpfile" bs=4k count="$block_count" \
      oflag=direct conv=fdatasync 2>/dev/null
    dd_rc=$?
  fi
  end=$(date +%s%N 2>/dev/null)
  rm -f "$tmpfile"

  if [ "$dd_rc" -eq 124 ]; then
    # timeout killed dd — storage so slow it blew the budget.
    _LAST_IOPS=0
    return 1
  elif [ "$dd_rc" -ne 0 ]; then
    return 2
  fi

  case "$end" in
    ''|*[!0-9]*) return 2 ;;
  esac

  elapsed_ns=$((end - start))
  if [ "$elapsed_ns" -le 0 ]; then
    return 2
  fi

  # iops = (block_count ops * 1e9 ns/s) / elapsed_ns
  iops=$(( block_count * 1000000000 / elapsed_ns ))
  _LAST_IOPS="$iops"

  [ "$iops" -ge "$threshold" ]
}

# Function to get current version from .env (preferred) or docker-compose.yml (legacy)
get_current_version() {
  # Prefer .env — new upgrades write VUE_VERSION here
  local env_ver
  env_ver=$(env_get "VUE_VERSION")
  if [ -n "$env_ver" ]; then
    echo "$env_ver"
    return
  fi

  # Fallback: parse compose file for legacy hardcoded tags
  if [ -f "$ORIGINAL_FILE" ]; then
    local raw_tag
    raw_tag=$(grep -E "calltelemetry/vue:" "$ORIGINAL_FILE" | head -1 | sed 's/.*calltelemetry\/vue://' | sed 's/".*//')
    if [ -n "$raw_tag" ]; then
      # Resolve ${VAR:-default} patterns — extract the default value
      if echo "$raw_tag" | grep -qE '^\$\{.*:-.*\}$'; then
        echo "$raw_tag" | sed 's/.*:-//' | sed 's/}$//'
      elif echo "$raw_tag" | grep -q '^\$'; then
        # Other env var pattern we can't resolve
        echo "unknown"
      else
        echo "$raw_tag"
      fi
    else
      echo "unknown"
    fi
  else
    echo "not installed"
  fi
}

# Function to configure IPv6 settings in docker-compose.yml
configure_ipv6() {
  local compose_file="$1"
  local enable_ipv6="$2"

  if [ ! -f "$compose_file" ]; then
    echo "Error: Compose file not found: $compose_file"
    return 1
  fi

  if [ "$enable_ipv6" = true ]; then
    echo "Enabling IPv6 support..."
    # Enable IPv6 in networks section
    sed -i 's/# enable_ipv6: true/enable_ipv6: true/' "$compose_file"
    # Also handle case where it might not have the comment
    if ! grep -q "enable_ipv6: true" "$compose_file"; then
      # Add enable_ipv6 under the ct network
      sed -i '/^  ct:$/a\    enable_ipv6: true' "$compose_file"
    fi
    # Change EXTERNAL_IP to use DEFAULT_IPV6
    sed -i 's/EXTERNAL_IP=\$DEFAULT_IPV4/EXTERNAL_IP=\$DEFAULT_IPV6/' "$compose_file"
    echo "IPv6 support enabled. Using DEFAULT_IPV6 for EXTERNAL_IP."
  else
    echo "Using IPv4 (default)..."
    # Ensure IPv6 is disabled (comment it out if present)
    sed -i 's/^[[:space:]]*enable_ipv6: true/    # enable_ipv6: true/' "$compose_file"
    # Ensure EXTERNAL_IP uses DEFAULT_IPV4
    sed -i 's/EXTERNAL_IP=\$DEFAULT_IPV6/EXTERNAL_IP=\$DEFAULT_IPV4/' "$compose_file"
  fi
}

# Function to get current IPv6 status
get_ipv6_status() {
  if [ ! -f "$ORIGINAL_FILE" ]; then
    echo "unknown"
    return
  fi

  if grep -q 'EXTERNAL_IP=\$DEFAULT_IPV6' "$ORIGINAL_FILE"; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

# Function to toggle IPv6 on/off
ipv6_toggle() {
  local action="$1"

  if [ -z "$action" ]; then
    # Show current status
    local current_status=$(get_ipv6_status)
    echo "IPv6 Status: $current_status"
    echo ""
    echo "Usage: cli.sh ipv6 <enable|disable>"
    return 0
  fi

  case "$action" in
    enable)
      require_root "ipv6 enable" || return 1
      echo "Enabling IPv6..."
      configure_ipv6 "$ORIGINAL_FILE" true
      echo ""
      fix_systemd_service_if_needed
      if ! restart_service "ipv6 enable"; then
        log_fail "Service restart failed after IPv6 enable."
        return 1
      fi
      echo ""
      wait_for_services
      ;;
    disable)
      require_root "ipv6 disable" || return 1
      echo "Disabling IPv6..."
      configure_ipv6 "$ORIGINAL_FILE" false
      echo ""
      fix_systemd_service_if_needed
      if ! restart_service "ipv6 disable"; then
        log_fail "Service restart failed after IPv6 disable."
        return 1
      fi
      echo ""
      wait_for_services
      ;;
    status)
      local current_status=$(get_ipv6_status)
      echo "IPv6 Status: $current_status"
      if [ "$current_status" = "enabled" ]; then
        echo "  EXTERNAL_IP is set to \$DEFAULT_IPV6"
      else
        echo "  EXTERNAL_IP is set to \$DEFAULT_IPV4"
      fi
      ;;
    *)
      echo "Error: Invalid action '$action'"
      echo "Usage: cli.sh ipv6 <enable|disable|status>"
      return 1
      ;;
  esac
}

# Function to check if version is 0.8.4 or higher
is_version_084_or_higher() {
  local version="$1"

  # Handle "latest" as 0.8.4+
  if [ "$version" == "latest" ]; then
    return 0
  fi

  # Extract major, minor, patch from version string (e.g., "0.8.4-rc128" -> 0, 8, 4)
  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"

    # Check if version >= 0.8.4
    if [ "$major" -gt 0 ]; then
      return 0
    elif [ "$major" -eq 0 ] && [ "$minor" -gt 8 ]; then
      return 0
    elif [ "$major" -eq 0 ] && [ "$minor" -eq 8 ] && [ "$patch" -ge 4 ]; then
      return 0
    fi
  fi

  return 1
}

# Resolve a target version string to an explicit version, hitting GCS
# markers for the `stable` / `latest` shortcuts. Prints the resolved
# version to stdout on success. Returns 1 if the GCS fetch fails.
# Fetch a URL to stdout with curl if available, else wget. Prefer curl
# (most appliances have it) but fall back to wget so hosts with only one
# installed aren't broken on the default `update` path.
_fetch_url() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -sfL "$url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url" 2>/dev/null
  else
    return 127
  fi
}

_update_resolve_version() {
  local input="$1"
  local resolved="$input"
  if [ -z "$resolved" ] || [ "$resolved" = "stable" ]; then
    echo "Fetching latest stable version..." >&2
    resolved=$(_fetch_url "${GCS_BASE_URL}/latest-stable.txt")
    if [ -z "$resolved" ]; then
      log_fail "Failed to fetch latest stable version"
      echo "" >&2
      echo "No stable release available yet (or neither curl nor wget is installed)." >&2
      echo "Use 'cli.sh update --latest' for pre-release, or specify a version manually." >&2
      return 1
    fi
    echo "Latest stable version: $resolved" >&2
  elif [ "$resolved" = "latest" ]; then
    echo "Fetching latest version (including pre-releases)..." >&2
    resolved=$(_fetch_url "${GCS_BASE_URL}/latest.txt")
    if [ -z "$resolved" ]; then
      log_fail "Failed to fetch latest version"
      echo "" >&2
      echo "Specify a version manually: cli.sh update <version>" >&2
      return 1
    fi
    echo "Latest version: $resolved" >&2
  elif [ "$resolved" = "dev" ]; then
    # Dev channel — latest validated release candidate. Reads latest-dev.txt
    # (the same marker the docs site uses to surface "next release coming").
    # Replaces the legacy --rc / latest-rc.txt path; --rc is now a deprecated
    # alias that resolves here too.
    echo "Fetching latest dev (release candidate) version..." >&2
    local _fetch_marker_rc
    resolved=$(_fetch_url "${GCS_BASE_URL}/latest-dev.txt")
    _fetch_marker_rc=$?
    if [ -z "$resolved" ]; then
      log_fail "Failed to fetch latest dev version"
      echo "" >&2
      # Distinguish three failure modes so operators don't chase the wrong
      # cause:
      #   127 → no curl AND no wget on this host (install one and retry)
      #     0 → fetcher returned success with empty body, i.e. the marker
      #         file exists but is empty (release team hasn't promoted yet)
      #   *  → fetcher reported a transport-level failure (HTTP error, DNS,
      #         connection refused). Surface the exit code so the operator
      #         can debug network/proxy/firewall instead of waiting for a
      #         release that's actually already promoted.
      if [ "$_fetch_marker_rc" -eq 127 ]; then
        echo "Failed to fetch latest dev version because neither curl nor wget is installed." >&2
      elif [ "$_fetch_marker_rc" -eq 0 ]; then
        echo "No version promoted to the dev channel yet." >&2
      else
        echo "Network or HTTP error fetching latest-dev.txt (fetcher exit ${_fetch_marker_rc})." >&2
        echo "Check connectivity to ${GCS_BASE_URL%/}/ and retry." >&2
      fi
      echo "Specify a version manually: cli.sh update <version>" >&2
      return 1
    fi
    # Strict format check — latest-dev.txt is a public GCS marker. Reject anything
    # that isn't a recognized release-candidate tag before using it to build a
    # download URL. Supports both 3-segment (0.8.6-rc271) and 4-segment
    # (0.8.6.5-rc1) version schemes.
    if [[ ! "$resolved" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?-rc[0-9]+$ ]]; then
      log_fail "Dev channel contains an invalid version: $resolved"
      echo "" >&2
      echo "Expected format: X.Y.Z-rcN or X.Y.Z.W-rcN (e.g. 0.8.6-rc271 or 0.8.6.5-rc1)." >&2
      echo "Contact the release team or specify a version manually: cli.sh update <version>" >&2
      return 1
    fi
    echo "Latest dev version: $resolved" >&2
  fi
  printf '%s\n' "$resolved"
}

# Prerequisite checks before the upgrade begins: RAM, disk, OS, Docker
# version. Returns 1 if anything is blocking (and --force-upgrade wasn't
# supplied), 0 otherwise. Keeps update() free of the noise.
_update_preflight_checks() {
  local version="$1" force_upgrade="$2"
  local preflight_had_warnings=0
  # Metrics captured from the passing checks so the default-mode PASS
  # summary can echo what was actually validated. Left empty when the
  # corresponding check was skipped (e.g. --force-upgrade on RAM/disk).
  local disk_free=""

  # RAM — 0.8.4+ needs 8GB
  if is_version_084_or_higher "$version"; then
    if [ "$force_upgrade" = false ]; then
      log_verbose "Checking RAM requirements for version $version..."
      # check_ram echoes "Detected RAM: NNNMB (N.NGB)" unconditionally.
      # Hide that in default mode; it still prints on failure below.
      local _ram_detect_out
      _ram_detect_out=$(check_ram)
      local _ram_rc=$?
      # check_ram sets total_ram_gb via $() subshell → doesn't propagate.
      # Parse it back from the "Detected RAM: NNNNMB (..)" line check_ram
      # already prints, so the PASS summary uses the exact value check_ram
      # validated — and the Darwin test path (sysctl-based) keeps working
      # without a second Linux-only /proc/meminfo probe (CodeRabbit nit).
      local total_ram_mb total_ram_gb
      if [[ "$_ram_detect_out" =~ ([0-9]+)MB ]]; then
        total_ram_mb="${BASH_REMATCH[1]}"
      else
        total_ram_mb=0
      fi
      total_ram_gb=$(( total_ram_mb / 1024 ))
      if [ "$_ram_rc" -ne 0 ]; then
        [ -n "$_ram_detect_out" ] && echo "$_ram_detect_out"
        echo ""
        log_fail "ERROR: Insufficient RAM for version 0.8.4 and higher"
        echo "   Version 0.8.4+ requires 8GB RAM (minimum 7GB detected)"
        echo ""
        echo "To proceed anyway, use: $0 update $version --force-upgrade"
        echo "WARNING: Proceeding with insufficient RAM may cause performance issues or failures"
        return 1
      fi
      cli_verbose && [ -n "$_ram_detect_out" ] && echo "$_ram_detect_out"
      log_verbose_ok "RAM requirement met (8GB recommended for optimal performance)"
      cli_verbose && echo ""
    else
      log_warn "WARNING: Skipping RAM check (--force-upgrade flag used)"
      echo "   Version 0.8.4+ requires 8GB RAM - proceeding with insufficient RAM may cause issues"
      echo ""
      preflight_had_warnings=1
    fi
  fi

  # Disk space — 10% free minimum
  if [ "$force_upgrade" = false ]; then
    log_verbose "Checking disk space..."
    cli_verbose && df -h / | head -2
    if ! check_disk_space; then
      local available_percent free_percent
      available_percent=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
      free_percent=$((100 - ${available_percent%\%}))
      echo ""
      log_fail "ERROR: Insufficient disk space for upgrade"
      echo "   Available: ${free_percent}% free"
      echo "   Required: 10% free minimum"
      echo ""
      echo "To proceed anyway, use: $0 update $version --force-upgrade"
      echo "WARNING: Proceeding with low disk space may cause upgrade failures"
      return 1
    fi
    disk_free=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')
    log_verbose_ok "Sufficient disk space available"
    cli_verbose && echo ""
  else
    log_warn "WARNING: Skipping disk space check (--force-upgrade flag used)"
    echo ""
    preflight_had_warnings=1
  fi

  # Disk speed — quick direct-I/O probe. Slow storage makes the
  # application effectively unusable (migrations drag, pg_ivm refresh
  # chokes the UI), so a below-threshold reading is a soft gate: the
  # operator must acknowledge before we continue.
  #   - interactive run  → read -p 'Continue? [y/N]', default N
  #   - --force-upgrade  → proceed (operator opted in)
  #   - non-TTY run      → abort (automation must pass --force-upgrade
  #                        explicitly after validating storage)
  # rc=2 (probe skipped for any reason) is a log-only warning.
  local disk_iops_threshold="${CHECK_DISK_IOPS_THRESHOLD:-1000}"
  log_verbose "Checking disk speed..."
  check_disk_iops
  case $? in
    0)
      log_verbose_ok "Disk speed acceptable (${_LAST_IOPS} IOPS, target ≥${disk_iops_threshold})"
      ;;
    1)
      log_warn "Disk speed below target — measured ${_LAST_IOPS} IOPS"
      echo "   Consider looking closely at disks and storage, and ensure all"
      echo "   historical snapshots are deleted. This application requires at"
      echo "   least ${disk_iops_threshold} IOPS to function, and the last test"
      echo "   failed to reach that target."
      echo ""
      preflight_had_warnings=1
      if [ "$force_upgrade" = true ]; then
        log_warn "Continuing anyway (--force-upgrade bypasses the disk-speed prompt)"
      elif [ ! -t 0 ]; then
        log_fail "Aborting: disk below ${disk_iops_threshold} IOPS and no TTY to prompt."
        echo "   Re-run with --force-upgrade to bypass this check."
        return 1
      else
        local answer=""
        read -r -p "   Continue the upgrade anyway? [y/N]: " answer
        case "${answer,,}" in
          y|yes)
            echo ""
            ;;
          *)
            echo ""
            log_fail "Aborting upgrade — resolve storage issue before retrying."
            echo "   Re-run with --force-upgrade to bypass this check."
            return 1
            ;;
        esac
      fi
      ;;
    2)
      # rc=2 covers several reasons: no dd, no ns-precision date,
      # unwritable probe directory, O_DIRECT rejected, or non-positive
      # elapsed time. Keep the message generic so we don't misattribute.
      log_warn "Disk speed check skipped (probe unavailable on this host)"
      preflight_had_warnings=1
      ;;
  esac
  cli_verbose && echo ""

  # CPU — 4 vCPUs recommended, 2 minimum.
  #
  # 2-3 vCPUs is a warn-and-proceed path: cli.sh auto-scales container
  # cgroup quotas via ensure_cpu_defaults below so Docker accepts the
  # reduced compose. The warning is intentional — operators should see
  # the under-provisioned state on every upgrade — but it is NOT gated
  # by --force-upgrade. Under 2 vCPUs is a hard fail because Docker
  # refuses container creation with a cryptic error regardless of our
  # compose-side tuning.
  log_verbose "Checking CPU requirements..."
  check_cpu
  case $? in
    0)
      log_verbose_ok "CPU requirement met (${_LAST_CPU_COUNT} vCPUs detected, 4 recommended)"
      ;;
    1)
      # 2-3 vCPUs: log the recommendation as a colored warning and proceed.
      # ensure_cpu_defaults (called later in the flow alongside
      # ensure_postgres_defaults) writes scaled-down DB_CPU_LIMIT / etc.
      # into .env so compose-up succeeds on this host — but env_set_default
      # is no-clobber, so a prior operator override survives. Don't claim
      # here that limits "will be" auto-scaled in every case; the
      # ensure_cpu_defaults log emitted later reports the actual effective
      # values (tuned vs preserved).
      log_warn "Only ${_LAST_CPU_COUNT} vCPUs detected. CallTelemetry 0.8.6 and higher recommends 4 vCPUs for stable operation under load."
      echo "        Proceeding — container CPU limits will be set conservatively unless already"
      echo "        overridden in ${ENV_FILE}. App will run but may be slow under heavy call volume."
      echo "        To eliminate this warning, resize the VM to 4+ vCPUs."
      preflight_had_warnings=1
      ;;
    2)
      # < 2 vCPUs — Docker will fail container creation regardless of any
      # env-var compose tuning. No useful way to proceed.
      log_fail "Host has only ${_LAST_CPU_COUNT} vCPU(s) — 2 minimum required."
      echo "       Docker cannot satisfy the database container's cgroup quota on a"
      echo "       1-vCPU host; it fails container creation with:"
      echo "         'range of CPUs is from 0.01 to 1.00, as there are only 1 CPUs available'"
      echo "       Resize the VM to at least 2 vCPUs (4 recommended) and re-run."
      echo "       --force-upgrade cannot override this — Docker enforces it below our layer."
      return 1
      ;;
    *)
      log_warn "Could not detect CPU count — proceeding without tuning .env CPU limits."
      preflight_had_warnings=1
      ;;
  esac
  cli_verbose && echo ""

  # CentOS Stream 8 — show EOL warning
  if [ -f /etc/os-release ] && grep -qi "centos.*stream.*8\|CentOS.*Stream.*8\|CENTOS.*STREAM.*8" /etc/os-release; then
    log_warn "WARNING: This appliance is running CentOS 8 Stream, and the OS has reached end of life in the Red Hat ecosystem. Please download a new appliance from calltelemetry.com, and copy the postgres and certificate folder over to the new appliance. If you continue, older Docker versions may not work with new builds in 0.8.4 releases. Sleeping for 5 seconds. Press CTRL-C to cancel."
    sleep 5
    preflight_had_warnings=1
  fi

  # Docker version — need 26+, auto-update otherwise
  log_verbose "Checking Docker version..."
  local docker_version
  docker_version=$(docker --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -1 | cut -d. -f1)

  if [ -z "$docker_version" ]; then
    log_warn "WARNING: Docker not found or not responding"
    preflight_had_warnings=1
  elif [ "$docker_version" -lt 26 ]; then
    log_warn "WARNING: Docker version $docker_version detected - Docker 26+ is required"
    echo "Docker is outdated, updating Docker packages..."
    # Track the warning — the auto-update may succeed, but the ⚠ line
    # above was visible and the PASS summary must not bury it.
    preflight_had_warnings=1
    sudo dnf update -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo "Docker package update completed."
    echo ""
    local updated_docker_version
    updated_docker_version=$(docker --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -1 | cut -d. -f1)
    if [ -z "$updated_docker_version" ]; then
      log_fail "ERROR: Docker update failed - Docker is not responding"
      echo "   Docker 26+ is required to continue"
      echo "   Please manually update Docker and try again"
      return 1
    elif [ "$updated_docker_version" -lt 26 ]; then
      log_fail "ERROR: Docker update failed - Docker is still on version $updated_docker_version"
      echo "   Docker 26+ is required to continue"
      echo "   Current version: $updated_docker_version"
      echo "   Required version: 26 or higher"
      echo ""
      echo "   Please manually update Docker to version 26+ and try again"
      echo "   You may need to check your repository configuration or available packages"
      return 1
    fi
    # Reflect the post-update version in the metric so the transcript
    # doesn't report the stale pre-update major if a summary fires later.
    docker_version="$updated_docker_version"
    log_ok "Docker successfully updated to version $updated_docker_version"
    echo ""
  else
    log_verbose_ok "Docker version $docker_version is supported"
  fi

  # Build the metric tokens for the PASS summary. Each is omitted when
  # the underlying check was skipped so the line only reflects what was
  # actually validated (e.g. --force-upgrade leaves RAM blank).
  local ram_metric="" disk_metric="" iops_metric="" cpu_metric="" docker_metric=""
  [ -n "${total_ram_gb:-}" ]     && [ "${total_ram_gb:-0}" -gt 0 ]     && ram_metric="RAM ${total_ram_gb}GB"
  [ -n "$disk_free" ]                                                  && disk_metric="${disk_free} free"
  [ -n "${_LAST_IOPS:-}" ]       && [ "${_LAST_IOPS:-0}" -gt 0 ]       && iops_metric="${_LAST_IOPS} IOPS"
  [ -n "${_LAST_CPU_COUNT:-}" ]  && [ "${_LAST_CPU_COUNT:-0}" -gt 0 ]  && cpu_metric="${_LAST_CPU_COUNT} vCPU"
  [ -n "$docker_version" ]                                             && docker_metric="Docker ${docker_version}"

  _update_preflight_summary "$force_upgrade" "$preflight_had_warnings" \
    "$ram_metric" "$disk_metric" "$iops_metric" "$cpu_metric" "$docker_metric"
}

# Emit the customer-facing summary for the ▸ Pre-flight checks section.
# Individual per-check ✓s are hidden in default mode (log_verbose_*), so
# without this line the section header would appear with no visible body.
# In verbose mode each check already printed its own ✓, so the summary
# would be redundant. Any path that emitted a warn or skip upstream sets
# preflight_had_warnings=1; claiming "all checks passed" after a visible
# ⚠ would contradict the transcript this PR is trying to preserve.
# --force-upgrade implies a skipped path, so it also falls into the softer
# summary. When no warnings fired, the remaining args are metric tokens
# ("RAM 30GB", "30G free", "7339 IOPS", "6 vCPU", "Docker 29") assembled
# into a single "PASS · a · b · c" line so operators can verify at a
# glance what was actually validated. Extracted for direct testability
# (__test_preflight_summary).
_update_preflight_summary() {
  local force_upgrade="${1:-false}"
  local had_warnings="${2:-0}"
  shift 2 2>/dev/null || true
  cli_verbose && return 0
  if [ "$force_upgrade" = true ] || [ "$had_warnings" = "1" ]; then
    log_ok "Pre-flight checks completed (see warnings above)"
    return 0
  fi
  local parts=() p joined=""
  for p in "$@"; do
    [ -n "$p" ] && parts+=("$p")
  done
  if [ "${#parts[@]}" -gt 0 ]; then
    joined="${parts[0]}"
    local i
    for ((i=1; i<${#parts[@]}; i++)); do
      joined="$joined · ${parts[$i]}"
    done
    log_ok "PASS · $joined"
  else
    log_ok "All pre-flight checks passed"
  fi
}

# ── update() decomposition ──────────────────────────────────────────────
#
# update() was a 442-line linear script with six log_step sections and
# several large inline blocks (Docker pull loop, swap sizing, post-start
# fixes). This splits each block into a named helper so each phase is
# individually grep-discoverable, testable, and has a single
# responsibility. Orchestrator shrinks from 442 to ~90 lines.
#
# Helpers run in the order they appear in the orchestrator:
#
#   _update_backup_current_compose   — timestamped copy of the live
#                                      docker-compose.yml into BACKUP_DIR
#   _update_pull_images              — check_image_availability + Docker
#                                      Hub login + smart per-image pull +
#                                      JTAPI-profile pull + display
#   _update_confirm_apply            — summary + keypress-to-abort prompt;
#                                      returns 1 if the user aborts
#   _update_apply_compose_file       — move TEMP_FILE → ORIGINAL_FILE +
#                                      configure IPv6 + repair bind-mount
#                                      directories + systemd fixes +
#                                      postgres defaults + legacy override
#                                      cleanup + PG compat repair
#   _update_ensure_swap_sized        — right-size /swapfile to the target
#                                      (8GB or RAM/2), accounting for any
#                                      pre-existing swap partition
#   _update_post_install_fixes       — Node 22 + @calltelemetry/cli + console
#                                      loglevel + nmcli migrate + GRAFANA
#                                      password + Docker memory limit +
#                                      partition-drain marker

# ─── Upgrade snapshot + failback ─────────────────────────────────────────
#
# Snapshot layout (in $BACKUP_DIR):
#   docker-compose-<ts>.yml   — compose backup (matched by timestamp)
#   env-<ts>.bak              — .env backup     (matched by timestamp)
#   db-latest.sql.gz          — most recent pre-upgrade DB dump (singular)
#   db-latest.meta            — KEY=VALUE sidecar pairing the DB dump with
#                               a specific compose/env timestamp
#
# Compose + env pairs are kept up to 5 (_update_prune_old_snapshots).
# DB dumps are expensive; only the most recent one is retained and is
# overwritten atomically via .tmp → mv on every fresh snapshot.
# When an operator declines the DB-backup prompt, any existing
# db-latest.* is removed so a stale older dump can't be mistaken for
# belonging to the current upgrade.
#
# Failure handling after wait_for_services: _update_prompt_rollback
# inspects $_WAIT_FAILED_PHASES and offers a scoped rollback prompt.

SNAPSHOT_COMPOSE_KEEP=5

_chown_install_user() {
  # Restore ownership of a snapshot artifact to the install user after
  # root created it. Matches _env_restore_owner's shape. No-op when not
  # running as root, and chown failures are swallowed so they never fail
  # a snapshot/rollback over a best-effort cleanup step.
  local target="$1"
  [ -e "$target" ] || return 0
  if [ "$(id -u)" -eq 0 ] && [ -n "${INSTALL_USER:-}" ]; then
    local install_group
    install_group=$(id -gn "$INSTALL_USER" 2>/dev/null || true)
    chown "${INSTALL_USER}${install_group:+:$install_group}" "$target" 2>/dev/null || true
  fi
}

_update_format_bytes() {
  # Humanize byte count for operator-facing prompts. Fast POSIX arithmetic
  # only — no `bc`, no `numfmt` dependency.
  local bytes="${1:-0}"
  if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '?'
    return
  fi
  if [ "$bytes" -lt 1024 ]; then
    printf '%dB' "$bytes"
  elif [ "$bytes" -lt $((1024 * 1024)) ]; then
    printf '%dKB' $((bytes / 1024))
  elif [ "$bytes" -lt $((1024 * 1024 * 1024)) ]; then
    printf '%dMB' $((bytes / 1024 / 1024))
  elif [ "$bytes" -lt $((1024 * 1024 * 1024 * 1024)) ]; then
    # Display with one decimal place for GB (rounded via integer math)
    local gb_tenths=$(( bytes * 10 / (1024 * 1024 * 1024) ))
    printf '%d.%dGB' $((gb_tenths / 10)) $((gb_tenths % 10))
  else
    local tb_tenths=$(( bytes * 10 / (1024 * 1024 * 1024 * 1024) ))
    printf '%d.%dTB' $((tb_tenths / 10)) $((tb_tenths % 10))
  fi
}

_update_measure_db_size() {
  # Prints the size of calltelemetry_prod in bytes. Empty on failure.
  # Requires the db container to be running and accepting psql.
  local sz
  sz=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db \
         psql -U calltelemetry -d calltelemetry_prod -tAc \
         "SELECT pg_database_size('calltelemetry_prod');" 2>/dev/null | tr -d '[:space:]')
  if [[ "$sz" =~ ^[0-9]+$ ]]; then
    printf '%s' "$sz"
  fi
}

_update_measure_backup_dir_free() {
  # Prints bytes available on the filesystem hosting $BACKUP_DIR.
  # df --output=avail is GNU-only but the appliance is AlmaLinux 9.
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  df --output=avail -B1 "$BACKUP_DIR" 2>/dev/null | tail -n +2 | tr -d '[:space:]'
}

_update_db_has_application_data() {
  # Return 0 when any application-owned table has rows, 1 when the DB is
  # effectively empty, 2 on inspection errors. Callers must treat errors as a
  # hard abort so a broken/inaccessible database cannot bypass the safety gate.
  local table_query table_list table_name has_row

  table_query="
SELECT format('%I.%I', n.nspname, c.relname)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND c.relispartition = false
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND n.nspname NOT LIKE '_timescaledb_%'
  AND NOT (n.nspname = 'public' AND c.relname IN (
    'schema_migrations',
    'spatial_ref_sys'
  ))
ORDER BY n.nspname, c.relname;"

  table_list=$($DOCKER_COMPOSE_CMD exec \
    -e "PGPASSWORD=$(_db_password)" \
    -e "PGOPTIONS=-c statement_timeout=5000 -c lock_timeout=1000" \
    -T db \
    psql -v ON_ERROR_STOP=1 -U calltelemetry -d calltelemetry_prod -tAc "$table_query" \
    </dev/null 2>/dev/null) || return 2

  [ -n "$table_list" ] || return 1

  while IFS= read -r table_name; do
    [ -n "$table_name" ] || continue
    has_row=$($DOCKER_COMPOSE_CMD exec \
      -e "PGPASSWORD=$(_db_password)" \
      -e "PGOPTIONS=-c statement_timeout=5000 -c lock_timeout=1000" \
      -T db \
      psql -v ON_ERROR_STOP=1 -U calltelemetry -d calltelemetry_prod -tAc \
      "SELECT 1 FROM $table_name LIMIT 1;" </dev/null 2>/dev/null | tr -d '[:space:]') || return 2
    if [ "$has_row" = "1" ]; then
      return 0
    fi
  done <<< "$table_list"

  return 1
}

_update_stop_snapshot_writers() {
  # The final empty-DB decision must happen after application writers are
  # stopped; otherwise a fresh install can gain data between the scan and the
  # upgrade continuing without a DB snapshot.
  if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
    return "${CT_CLI_TEST_STOP_WRITERS_RC:-0}"
  fi
  log_warn "Stopping application writers before re-checking whether the database is empty..."
  if $DOCKER_COMPOSE_CMD stop web >/dev/null 2>&1; then
    UPDATE_SNAPSHOT_WRITERS_STOPPED=1
    return 0
  fi
  return 1
}

_update_start_snapshot_writers() {
  if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
    return "${CT_CLI_TEST_START_WRITERS_RC:-0}"
  fi
  log_warn "Restarting application writers after DB snapshot safety check aborted..."
  if $DOCKER_COMPOSE_CMD up -d web >/dev/null 2>&1; then
    UPDATE_SNAPSHOT_WRITERS_STOPPED=0
    return 0
  fi
  return 1
}

_update_restore_snapshot_writers_if_needed() {
  [ "${UPDATE_SNAPSHOT_WRITERS_STOPPED:-0}" = "1" ] || return 0
  _update_start_snapshot_writers || {
    log_warn "Upgrade aborted after snapshot writer stop and web could not be restarted automatically; run '$DOCKER_COMPOSE_CMD up -d web'."
    return 1
  }
}

_update_snapshot_db() {
  # Dump calltelemetry_prod | gzip → $BACKUP_DIR/db-latest.sql.gz
  # Ticker in the background reports wall-time + output size every 5s
  # so an operator can tell dead-pg_dump from slow-pg_dump. Writes
  # atomically via .tmp → mv, then writes a .meta sidecar pairing the
  # dump with the given compose/env timestamp.
  #
  # Args: <snapshot_ts>
  local snapshot_ts="$1"
  local dump_path="$BACKUP_DIR/db-latest.sql.gz"
  local tmp_path="${dump_path}.tmp"
  local meta_path="$BACKUP_DIR/db-latest.meta"

  mkdir -p "$BACKUP_DIR"
  # Backup directory holds secrets (.env with DB password, full DB dump).
  # Lock it down so only the install user can read it — default umask on
  # the host is typically 022 which would leave the contents world-readable.
  # Also chown to the install user so non-root `ls`/`cp` on BACKUP_DIR works
  # without sudo (root-created dirs are surprising for operators).
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  _chown_install_user "$BACKUP_DIR"
  rm -f "$tmp_path"

  local start_epoch end_epoch elapsed size_bytes
  start_epoch=$(date +%s)

  # Kick off pg_dump in the background so we can tick progress while it
  # runs. `docker compose exec -T` means no TTY; pg_dump's own progress
  # isn't useful, so we sample output-file size instead.
  #
  # pipefail inside the subshell so a failing pg_dump doesn't silently
  # produce a truncated-but-valid gzip. pg_dump stderr is captured to a
  # file we print on failure — discarding it previously made diagnosis
  # impossible.
  #
  # umask 077 so gzip creates $tmp_path with 0600 from the start. The
  # $BACKUP_DIR chmod 700 protects it via the parent directory, but if
  # that chmod silently fails (NFS/CIFS without perm support, race with
  # an existing dir) the tmp file was left readable. Belt + suspenders.
  local dump_err
  dump_err=$(mktemp 2>/dev/null) || dump_err=""
  ( umask 077
    set -o pipefail
    if [ -n "$dump_err" ]; then
      $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db \
        pg_dump -U calltelemetry calltelemetry_prod 2>"$dump_err" \
        | gzip -c > "$tmp_path"
    else
      $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db \
        pg_dump -U calltelemetry calltelemetry_prod 2>/dev/null \
        | gzip -c > "$tmp_path"
    fi
  ) &
  local dump_pid=$!

  # Heartbeat via log_heartbeat so CLI_QUIET=1 suppresses the \r ticker
  # the same way it does for other long-running phases (restart, wait).
  while kill -0 "$dump_pid" 2>/dev/null; do
    sleep 5
    if kill -0 "$dump_pid" 2>/dev/null; then
      local now cur_size_bytes cur_size_hr elapsed_now
      now=$(date +%s)
      elapsed_now=$((now - start_epoch))
      cur_size_bytes=$(stat -c%s "$tmp_path" 2>/dev/null || echo 0)
      cur_size_hr=$(_update_format_bytes "$cur_size_bytes")
      log_heartbeat "\r  Dumping DB… %ds elapsed, %s written   " "$elapsed_now" "$cur_size_hr"
    fi
  done
  wait "$dump_pid"
  local dump_rc=$?
  end_epoch=$(date +%s)
  elapsed=$((end_epoch - start_epoch))
  cli_quiet || echo ""

  if [ "$dump_rc" -ne 0 ]; then
    rm -f "$tmp_path"
    log_fail "pg_dump failed after ${elapsed}s (exit $dump_rc). No DB snapshot written."
    if [ -n "$dump_err" ] && [ -s "$dump_err" ]; then
      echo "  pg_dump stderr:"
      sed 's/^/    /' "$dump_err" 2>/dev/null | head -20
    fi
    [ -n "$dump_err" ] && rm -f "$dump_err"
    return 1
  fi
  [ -n "$dump_err" ] && rm -f "$dump_err"

  # Guard against an empty / tiny dump — pg_dump can exit 0 on a
  # permission error if stderr is redirected. A real dump has at least
  # a few hundred bytes of gzipped SQL header.
  size_bytes=$(stat -c%s "$tmp_path" 2>/dev/null || echo 0)
  if [ "$size_bytes" -lt 200 ]; then
    rm -f "$tmp_path"
    log_fail "pg_dump produced an unexpectedly small file (${size_bytes}B). Treating as failure."
    return 1
  fi

  # Check mv and meta write — disk-full here silently voided the safety
  # net before (we'd log success without producing a usable dump).
  if ! mv -f "$tmp_path" "$dump_path"; then
    log_fail "Failed to move $tmp_path to $dump_path (disk full? permissions?)."
    rm -f "$tmp_path"
    return 1
  fi
  # Restrict dump to the install user only — it contains the full DB.
  chmod 600 "$dump_path" 2>/dev/null || true
  _chown_install_user "$dump_path"

  # Write meta atomically via tmp + mv — a write interrupted here would
  # otherwise strand a valid dump next to a partial .meta, and the
  # restore path refuses to use unpaired artifacts.
  local meta_tmp="${meta_path}.tmp"
  rm -f "$meta_tmp"
  if ! {
    echo "snapshot_ts=${snapshot_ts}"
    echo "dump_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "dump_bytes=${size_bytes}"
    echo "dump_seconds=${elapsed}"
  } > "$meta_tmp" || ! mv -f "$meta_tmp" "$meta_path"; then
    log_fail "Failed to write $meta_path. Removing dump to avoid an un-paired rollback artifact."
    rm -f "$dump_path" "$meta_tmp"
    return 1
  fi
  chmod 600 "$meta_path" 2>/dev/null || true
  _chown_install_user "$meta_path"

  log_ok "DB snapshot written: $(_update_format_bytes "$size_bytes") in ${elapsed}s"
  return 0
}

_update_prompt_db_backup() {
  # Returns 0 if caller should take a DB snapshot, 1 if skip.
  # Honors --backup-db / --no-backup-db flags passed in as args (bool strings).
  # Default (no flag) is NO backup — upgrades are fast and non-destructive;
  # use --backup-db to take an explicit pre-upgrade snapshot when desired.
  # Explicit --backup-db / --no-backup-db always wins over the default.
  local backup_db_flag="${1:-prompt}"   # "yes" | "no" | "prompt"

  if [ "$backup_db_flag" = "yes" ]; then
    return 0
  fi
  if [ "$backup_db_flag" = "no" ]; then
    log_warn "DB backup skipped (--no-backup-db)"
    return 1
  fi

  # Always check disk headroom first — applies to both TTY and non-TTY paths.
  local db_bytes free_bytes est_bytes db_hr est_hr free_hr
  db_bytes=$(_update_measure_db_size)
  free_bytes=$(_update_measure_backup_dir_free)
  if [ -z "$db_bytes" ]; then
    log_warn "couldn't measure DB size (is the db container running?). Skipping DB backup."
    return 1
  fi
  # gzipped SQL dump is typically 3-5x smaller than raw data; conservative
  # estimate divides by 3.
  est_bytes=$((db_bytes / 3))
  db_hr=$(_update_format_bytes "$db_bytes")
  est_hr=$(_update_format_bytes "$est_bytes")
  free_hr=$(_update_format_bytes "${free_bytes:-0}")

  local insufficient_disk=0
  local low_disk=0
  if [ -z "$free_bytes" ] || [ "$free_bytes" -lt "$est_bytes" ]; then
    insufficient_disk=1
  elif [ "$free_bytes" -lt $((est_bytes * 2)) ]; then
    low_disk=1
  fi

  # _FORCE_TTY is a test-only escape hatch: set it to force the interactive
  # prompt path when stdin is not a real TTY (e.g. in CI test harnesses).
  local is_tty=0
  [ "${_FORCE_TTY:-}" = "1" ] && is_tty=1
  [ -t 0 ] && is_tty=1

  if [ "$is_tty" = "0" ]; then
    # Non-interactive path: auto-decide based on disk headroom.
    if [ "$insufficient_disk" = "1" ]; then
      log_warn "insufficient disk headroom — skipping DB backup. Pass --backup-db to override."
      return 1
    fi
    log_warn "DB backup proceeding (non-interactive default). Pass --no-backup-db to skip."
    return 0
  fi

  # Interactive (TTY) path: show disk info and prompt.
  echo ""
  echo "  Database size:          $db_hr"
  echo "  Estimated gzip backup:  ~$est_hr"
  echo "  Available in $BACKUP_DIR: $free_hr"

  local default_ans prompt_prefix
  if [ "$insufficient_disk" = "1" ]; then
    log_warn "Insufficient disk headroom — backup will likely fail mid-write."
    default_ans="N"
    prompt_prefix="  Back up anyway? [y/N]: "
  elif [ "$low_disk" = "1" ]; then
    log_warn "Low disk headroom — backup will fit but leaves little room."
    default_ans="N"
    prompt_prefix="  Back up database before upgrade? [y/N]: "
  else
    default_ans="Y"
    prompt_prefix="  Back up database before upgrade? [Y/n]: "
  fi

  local answer=""
  read -r -p "$prompt_prefix" answer
  answer="${answer:-$default_ans}"
  case "${answer,,}" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

_update_prune_old_snapshots() {
  # Keeps the most recent $SNAPSHOT_COMPOSE_KEEP compose backups plus their
  # paired env-*.bak files. DB dump (db-latest.sql.gz + .meta) is
  # intentionally NOT pruned here — it's a single latest-only artifact.
  local keep="${1:-$SNAPSHOT_COMPOSE_KEEP}"
  [ -d "$BACKUP_DIR" ] || return 0

  # Find all compose backups, newest first, drop the top $keep, delete the rest
  # plus any paired env file with the same timestamp.
  local compose_file ts env_file
  while IFS= read -r compose_file; do
    [ -n "$compose_file" ] || continue
    ts=$(basename "$compose_file")
    ts="${ts#docker-compose-}"
    ts="${ts%.yml}"
    env_file="$BACKUP_DIR/env-${ts}.bak"
    rm -f "$compose_file" "$env_file"
  done < <(ls -t "$BACKUP_DIR"/docker-compose-*.yml 2>/dev/null | tail -n +$((keep + 1)))
}

_update_create_snapshot() {
  # Orchestrator for the pre-upgrade safety net.
  # Called after _update_confirm_apply (operator committed to the upgrade)
  # but before _update_apply_compose_file (any on-disk mutation).
  #
  # Compose + env are already snapshot earlier in the preflight slot by
  # _update_backup_current_compose (so we have a pre-download_bundle copy
  # of .env). This step takes care of the DB dump when the operator
  # opts in.
  #
  # Args: <snapshot_ts> <backup_db_flag: yes|no|prompt>
  local snapshot_ts="$1" backup_db_flag="$2"

  if _update_prompt_db_backup "$backup_db_flag"; then
    if ! _update_snapshot_db "$snapshot_ts"; then
      local app_data_rc writers_stopped=0
      if [ "$backup_db_flag" != "yes" ]; then
        _update_db_has_application_data
        app_data_rc=$?
        if [ "$app_data_rc" -eq 1 ] && _update_stop_snapshot_writers; then
          writers_stopped=1
          _update_db_has_application_data
          app_data_rc=$?
          if [ "$app_data_rc" -eq 1 ]; then
            log_warn "Pre-upgrade DB snapshot failed, but no application data was found after stopping application writers; continuing with compose/.env rollback only."
            return 0
          fi
        fi
        if [ "$app_data_rc" -eq 0 ]; then
          log_fail "Pre-upgrade DB snapshot failed and application data was detected; refusing to continue without a DB snapshot."
        else
          log_fail "Pre-upgrade DB snapshot failed and database emptiness could not be verified; refusing to continue without a DB snapshot."
        fi
      fi
      if [ "$writers_stopped" -eq 1 ] && ! _update_start_snapshot_writers; then
        log_warn "DB snapshot safety check aborted and web could not be restarted automatically; run '$DOCKER_COMPOSE_CMD up -d web' after investigating the failed DB snapshot."
      fi
      return 1
    fi
  else
    # Operator declined (or non-TTY without flag) — remove any stale
    # dump so the failback flow doesn't offer to restore the wrong one.
    rm -f "$BACKUP_DIR/db-latest.sql.gz" "$BACKUP_DIR/db-latest.meta"
  fi
  return 0
}

_update_backup_current_compose() {
  # Pre-upgrade compose + .env snapshot (runs in the preflight slot,
  # before download_bundle merges version pins into .env). Shared
  # timestamp lets the failback path pair the two files.
  local timestamp compose_backup env_backup
  timestamp=$(date "+%Y-%m-%d-%H-%M-%S")
  compose_backup="$BACKUP_DIR/docker-compose-$timestamp.yml"
  env_backup="$BACKUP_DIR/env-$timestamp.bak"

  mkdir -p "$BACKUP_DIR"

  # cp-failure check: a silently-dropped snapshot (disk full, read-only
  # mount, permission drift) voids the entire rollback safety net.
  # Fail loud and skip pruning so that whatever older snapshots exist
  # remain available as recovery anchors.
  # Lock down the backup dir itself (holds .env with secrets + DB dump).
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  _chown_install_user "$BACKUP_DIR"

  # Detect first-install (no existing docker-compose.yml) separately
  # from a snapshot failure. First install → no rollback target exists,
  # but the upgrade should still proceed (the whole point is to install).
  # snapshot_ts is set to "" so downstream rollback prompts know to skip.
  local fresh_install=0
  if [ ! -f "$ORIGINAL_FILE" ]; then
    fresh_install=1
    log_info "Fresh install detected: no previous Call Telemetry deployment was found."
    echo "   No rollback snapshot was created because there is nothing installed to roll back to."
  fi

  local compose_ok=1 env_ok=1
  if [ -f "$ORIGINAL_FILE" ]; then
    if cp "$ORIGINAL_FILE" "$compose_backup"; then
      _chown_install_user "$compose_backup"
      cli_verbose && log_dim "Snapshot: compose → $compose_backup"
    else
      log_fail "Failed to snapshot compose to $compose_backup"
      compose_ok=0
    fi
  fi
  if [ -f "$ENV_FILE" ]; then
    if cp "$ENV_FILE" "$env_backup"; then
      # .env contains POSTGRES_PASSWORD, GRAFANA_PASSWORD, etc. —
      # tighten to owner-only before anyone else sees it.
      chmod 600 "$env_backup" 2>/dev/null || true
      _chown_install_user "$env_backup"
      cli_verbose && log_dim "Snapshot: .env    → $env_backup"
    else
      log_fail "Failed to snapshot .env to $env_backup"
      env_ok=0
    fi
  fi

  if [ "$fresh_install" = "1" ]; then
    # No new snapshot pair was created — don't let the prune-to-5 step
    # delete older recovery anchors that might still be useful. Retention
    # only runs when we actually produced a new pair.
    :
  elif [ "$compose_ok" = "1" ] && [ "$env_ok" = "1" ]; then
    _update_prune_old_snapshots
  else
    log_warn "Keeping existing older snapshots (prune skipped after snapshot failure)."
    # Caller decides whether to abort; the orchestrator checks
    # _UPDATE_SNAPSHOT_OK and refuses to continue on failure.
    _UPDATE_SNAPSHOT_OK=0
    _UPDATE_SNAPSHOT_TS="$timestamp"
    return 1
  fi
  _UPDATE_SNAPSHOT_OK=1

  # Hand the timestamp back to the caller via a global so _update_create_snapshot
  # can tag the DB meta with the same value (bash can't easily return strings).
  # Empty string signals "no snapshot exists for this upgrade" (fresh install);
  # rollback prompts skip when this is empty.
  if [ "$fresh_install" = "1" ]; then
    _UPDATE_SNAPSHOT_TS=""
  else
    _UPDATE_SNAPSHOT_TS="$timestamp"
  fi
}

_update_list_snapshots() {
  # Print a human-readable table of available snapshot sets.
  # Columns: timestamp | compose size | env size | db-latest match? | notes
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "No snapshots found (backup directory $BACKUP_DIR does not exist)."
    return 0
  fi

  local db_meta_ts=""
  if [ -f "$BACKUP_DIR/db-latest.meta" ]; then
    db_meta_ts=$(grep '^snapshot_ts=' "$BACKUP_DIR/db-latest.meta" 2>/dev/null | cut -d= -f2)
  fi

  printf '%-22s %-10s %-10s %-16s\n' "timestamp" "compose" "env" "db dump"
  printf '%-22s %-10s %-10s %-16s\n' "---------" "-------" "---" "-------"

  local any=0
  local compose_file ts compose_size env_file env_size db_tag
  while IFS= read -r compose_file; do
    [ -n "$compose_file" ] || continue
    any=1
    ts=$(basename "$compose_file")
    ts="${ts#docker-compose-}"
    ts="${ts%.yml}"
    compose_size=$(_update_format_bytes "$(stat -c%s "$compose_file" 2>/dev/null || echo 0)")
    env_file="$BACKUP_DIR/env-${ts}.bak"
    if [ -f "$env_file" ]; then
      env_size=$(_update_format_bytes "$(stat -c%s "$env_file" 2>/dev/null || echo 0)")
    else
      env_size="—"
    fi
    if [ -n "$db_meta_ts" ] && [ "$db_meta_ts" = "$ts" ]; then
      local db_bytes
      db_bytes=$(stat -c%s "$BACKUP_DIR/db-latest.sql.gz" 2>/dev/null || echo 0)
      db_tag="$(_update_format_bytes "$db_bytes")"
    else
      db_tag="—"
    fi
    printf '%-22s %-10s %-10s %-16s\n' "$ts" "$compose_size" "$env_size" "$db_tag"
  done < <(ls -t "$BACKUP_DIR"/docker-compose-*.yml 2>/dev/null)

  if [ "$any" -eq 0 ]; then
    echo "(no compose snapshots in $BACKUP_DIR)"
  fi
}

_update_restore_snapshot() {
  # Restore an upgrade snapshot set. Args:
  #   <timestamp>       — compose+env set to restore
  #   <with_env: 0|1>   — also restore env-<ts>.bak
  #   <with_db:  0|1>   — also restore db-latest.sql.gz (must pair with <ts>)
  local ts="$1" with_env="$2" with_db="$3"
  local compose_backup="$BACKUP_DIR/docker-compose-${ts}.yml"
  local env_backup="$BACKUP_DIR/env-${ts}.bak"
  local db_dump="$BACKUP_DIR/db-latest.sql.gz"
  local db_meta="$BACKUP_DIR/db-latest.meta"

  if [ ! -f "$compose_backup" ]; then
    log_fail "Compose snapshot not found: $compose_backup"
    return 1
  fi

  # Preconditions on --with-db: dump must exist AND meta must match the
  # requested timestamp. We refuse to restore a DB dump that belongs to a
  # different compose snapshot — that combination is almost always wrong.
  if [ "$with_db" = "1" ]; then
    if [ ! -f "$db_dump" ]; then
      log_fail "No DB dump available: $db_dump"
      echo "       Pre-upgrade DB snapshots are stored only for the most recent upgrade."
      return 1
    fi
    if [ ! -f "$db_meta" ]; then
      log_fail "DB dump present but meta sidecar missing: $db_meta"
      return 1
    fi
    local meta_ts
    meta_ts=$(grep '^snapshot_ts=' "$db_meta" 2>/dev/null | cut -d= -f2)
    if [ "$meta_ts" != "$ts" ]; then
      log_fail "DB dump belongs to snapshot $meta_ts, not $ts. Refusing to restore."
      echo "       Use --snapshot $meta_ts to target the matching set."
      return 1
    fi
  fi

  log_step "Restoring compose from $compose_backup"
  if ! cp "$compose_backup" "$ORIGINAL_FILE"; then
    log_fail "Failed to restore compose from $compose_backup. Aborting — system is in whatever pre-restore state it was."
    return 1
  fi
  log_ok "compose restored"

  if [ "$with_env" = "1" ]; then
    if [ -f "$env_backup" ]; then
      log_step "Restoring .env from $env_backup"
      if ! cp "$env_backup" "$ENV_FILE"; then
        log_fail "Failed to restore .env. Rollback aborted — resolve manually."
        return 1
      fi
      # Tighten perms on the restored file — the snapshot chmod is
      # best-effort (|| true) for NFS/CIFS where mode bits can fail,
      # so we re-apply at restore time belt-and-suspenders.
      chmod 600 "$ENV_FILE" 2>/dev/null || true
      # Restore .env ownership to the install user. cp-while-root leaves
      # root:root, which then breaks subsequent non-root edits — exactly
      # what _env_restore_owner exists to prevent.
      _env_restore_owner
      log_ok ".env restored"
    else
      log_warn "No paired .env snapshot at $env_backup — skipping env restore."
    fi
  fi

  if [ "$with_db" = "1" ]; then
    log_step "Restoring database from $db_dump"
    echo "  Stopping services before DB restore…"
    systemctl stop docker-compose-app.service 2>/dev/null || true

    # Shared exit helper for the --with-db restore failure branches:
    # the appliance is already stopped at this point, so operators need
    # explicit recovery instructions. Attempting an automatic
    # restart_service here is deliberately avoided — the usual cause of
    # a failed dump replay is data/schema corruption that would just
    # make the restarted app crash-loop; the operator is better
    # positioned to pick the next step.
    _rollback_db_aborted_hint() {
      echo ""
      log_warn "Services remain stopped after the failed DB restore attempt."
      echo "        To bring the appliance back up (with the PREVIOUS DB state):"
      echo "          sudo systemctl start docker-compose-app.service"
      echo "        To retry the full restore once the root cause is fixed:"
      echo "          sudo cli.sh rollback --snapshot $ts --with-env --with-db"
    }

    # Start only the db container so we can psql into it without the app
    # attempting to connect mid-restore. Use the same compose-file flags
    # (get_compose_files) systemd uses for the upgraded stack — otherwise
    # the implicit docker-compose.override.yml selection could bring up
    # the db against a different image/config than what restart_service
    # will run afterward.
    echo "  Bringing up db-only stack for restore…"
    if ! $DOCKER_COMPOSE_CMD $(get_compose_files) up -d db >/dev/null 2>&1; then
      log_fail "Failed to start db container for restore."
      _rollback_db_aborted_hint
      return 1
    fi
    # Wait briefly for pg_isready
    local i=0
    while [ $i -lt 30 ]; do
      if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
        break
      fi
      sleep 2
      i=$((i + 1))
    done
    if [ $i -ge 30 ]; then
      log_fail "db container didn't accept connections within 60s — aborting restore."
      _rollback_db_aborted_hint
      return 1
    fi

    echo "  Dropping + recreating calltelemetry_prod and replaying dump…"
    local restore_start
    restore_start=$(date +%s)
    # Drop + recreate uses WITH (FORCE) to terminate any lingering
    # sessions (stray operator shells, leftover connections) — without
    # it, DROP DATABASE fails if anything is still connected. Postgres
    # 13+ supports WITH (FORCE); the bundled postgres image is 14+.
    # Drop/create also captures stderr so the operator sees the actual
    # psql error instead of just "exit 1".
    local drop_err
    drop_err=$(mktemp 2>/dev/null) || drop_err=""
    if ! $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db \
           psql -U calltelemetry -d postgres -v ON_ERROR_STOP=1 \
             -c "DROP DATABASE IF EXISTS calltelemetry_prod WITH (FORCE);" \
             -c "CREATE DATABASE calltelemetry_prod OWNER calltelemetry;" \
         >/dev/null 2>"${drop_err:-/dev/null}"; then
      log_fail "Failed to drop/recreate calltelemetry_prod. Database may be in a partial state."
      if [ -n "$drop_err" ] && [ -s "$drop_err" ]; then
        echo "  psql stderr:"
        sed 's/^/    /' "$drop_err" 2>/dev/null | head -10
      fi
      [ -n "$drop_err" ] && rm -f "$drop_err"
      _rollback_db_aborted_hint
      return 1
    fi
    [ -n "$drop_err" ] && rm -f "$drop_err"

    # Replay the dump. pipefail ensures a gunzip error surfaces here
    # (without it, psql's exit status wins and a truncated dump looks OK).
    # Capture replay stderr so operators get actionable diagnostics on
    # failure instead of a bare exit code.
    local replay_err prev_pipefail
    replay_err=$(mktemp 2>/dev/null) || replay_err=""
    prev_pipefail=$(set -o | awk '/^pipefail/ {print $2}')
    set -o pipefail
    if ! gunzip -c "$db_dump" \
         | $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db \
             psql -U calltelemetry -d calltelemetry_prod -v ON_ERROR_STOP=1 \
         >/dev/null 2>"${replay_err:-/dev/null}"; then
      [ "$prev_pipefail" = "off" ] && set +o pipefail
      log_fail "Dump replay failed (gunzip or psql exited non-zero). Database may be partially restored."
      if [ -n "$replay_err" ] && [ -s "$replay_err" ]; then
        echo "  replay stderr (last 20 lines):"
        sed 's/^/    /' "$replay_err" 2>/dev/null | tail -20
      fi
      [ -n "$replay_err" ] && rm -f "$replay_err"
      _rollback_db_aborted_hint
      return 1
    fi
    [ "$prev_pipefail" = "off" ] && set +o pipefail
    [ -n "$replay_err" ] && rm -f "$replay_err"
    local restore_elapsed=$(( $(date +%s) - restore_start ))
    log_ok "DB restored in ${restore_elapsed}s"
  fi

  log_step "Restarting services on restored configuration"
  fix_systemd_service_if_needed
  if ! restart_service "rollback"; then
    log_fail "Service restart failed after rollback."
    echo "   The rollback configuration is in place but services may not be running."
    echo "   Retry with: systemctl restart docker-compose-app.service"
    return 1
  fi

  log_ok "Rollback complete."
  return 0
}

_update_prompt_rollback() {
  # Called from update() after wait_for_services. Decides which (if any)
  # failback prompt to offer based on which phases failed. Operator
  # always has to type y to proceed — no auto-rollback. No timeout.
  #
  # Args: <services_ok> <snapshot_ts>
  local services_ok="$1" snapshot_ts="$2"

  if [ "$services_ok" = "0" ]; then
    return 0
  fi

  # No pre-upgrade snapshot exists (fresh-install path, or snapshot
  # step intentionally skipped). There's nothing to offer a rollback
  # to — surface that clearly instead of prompting for a restore that
  # would fail.
  if [ -z "$snapshot_ts" ]; then
    echo ""
    log_warn "No pre-upgrade snapshot available for this run (fresh install)."
    echo "        Recovery from a failed upgrade here requires manual intervention —"
    echo "        there's no previous compose/.env/DB state to restore."
    return 1
  fi

  # Classify failures: anything past Phase 2 means the DB may have been
  # mutated by Ecto migrations.
  local mutated=false
  case " $_WAIT_FAILED_PHASES " in
    *" migrations "*|*" health-check "*|*" traceroute-health "*|*" rpc "*)
      mutated=true
      ;;
  esac

  echo ""
  echo "Upgrade did not complete cleanly. Failed phases:$_WAIT_FAILED_PHASES"
  echo "Pre-upgrade snapshot: $snapshot_ts"

  # Non-TTY (ansible, CI, systemd-run without a pty): don't `read -p` —
  # it can block indefinitely if stdin is open but not a terminal. Print
  # the recovery commands instead and let automation drive recovery.
  # _FORCE_TTY is a test-only escape hatch; it must be paired with
  # CT_CLI_TEST_MODE=1 to take effect, so leaking _FORCE_TTY into a
  # production environment cannot force the prompt path.
  if ! { [ "${_FORCE_TTY:-}" = "1" ] && [ "${CT_CLI_TEST_MODE:-}" = "1" ]; } && [ ! -t 0 ]; then
    echo ""
    echo "Non-interactive session — skipping rollback prompt. To roll back:"
    if [ "$mutated" = false ]; then
      echo "  sudo cli.sh rollback --snapshot $snapshot_ts --with-env"
    else
      echo "  sudo cli.sh rollback --snapshot $snapshot_ts --with-env --with-db  # full (if snapshot has DB)"
      echo "  sudo cli.sh rollback --snapshot $snapshot_ts --with-env            # compose + env only"
    fi
    return 1
  fi

  local answer="" prompt_text have_db=0
  if [ -f "$BACKUP_DIR/db-latest.sql.gz" ] && [ -f "$BACKUP_DIR/db-latest.meta" ]; then
    local meta_ts
    meta_ts=$(grep '^snapshot_ts=' "$BACKUP_DIR/db-latest.meta" 2>/dev/null | cut -d= -f2)
    if [ "$meta_ts" = "$snapshot_ts" ]; then
      have_db=1
    fi
  fi

  if [ "$mutated" = false ]; then
    # Phase 1/2 failure only — DB untouched, compose+env restore is sufficient.
    prompt_text="Roll back to the previous version? Compose + .env will be restored from $snapshot_ts; DB is unchanged. [y/N]: "
    read -r -p "$prompt_text" answer
    case "${answer,,}" in
      y|yes)
        _update_restore_snapshot "$snapshot_ts" "1" "0"
        return $?
        ;;
      *)
        echo "Leaving the system in its current state. Run:"
        echo "  sudo cli.sh rollback --snapshot $snapshot_ts --with-env"
        echo "to restore later, or check cli.sh status for current state."
        return 1
        ;;
    esac
  fi

  # Mutated path — migrations / health / rpc failed.
  if [ "$have_db" = "1" ]; then
    prompt_text="Full rollback? Stops services, restores compose + .env + DB from $snapshot_ts, restarts. [y/N]: "
    read -r -p "$prompt_text" answer
    case "${answer,,}" in
      y|yes)
        # Double-confirm the destructive DB restore — same pattern as
        # `cli.sh rollback --with-db`. A single 'y' keystroke is too easy
        # to hit by reflex at 2am; full DB restore drops calltelemetry_prod.
        local confirm=""
        read -r -p "  Type 'yes' to confirm full DB restore: " confirm
        if [ "$confirm" != "yes" ]; then
          log_warn "Full DB restore cancelled."
          echo "Manual recovery options:"
          echo "  sudo cli.sh rollback --snapshot $snapshot_ts --with-env --with-db  # full restore"
          echo "  sudo cli.sh rollback --snapshot $snapshot_ts --with-env            # compose + env only"
          return 1
        fi
        _update_restore_snapshot "$snapshot_ts" "1" "1"
        return $?
        ;;
      *)
        echo "Leaving the system in its current (migrated) state. Manual recovery options:"
        echo "  sudo cli.sh rollback --snapshot $snapshot_ts --with-env --with-db  # full restore"
        echo "  sudo cli.sh rollback --snapshot $snapshot_ts --with-env            # compose + env only (risky)"
        return 1
        ;;
    esac
  fi

  # Mutated path, no DB snapshot available.
  log_warn "No DB snapshot for this upgrade — migrations CANNOT be rolled back automatically."
  prompt_text="Roll back compose + .env only? The old code may not boot cleanly against the migrated schema. [y/N]: "
  read -r -p "$prompt_text" answer
  case "${answer,,}" in
    y|yes)
      _update_restore_snapshot "$snapshot_ts" "1" "0"
      return $?
      ;;
    *)
      echo "Leaving the system in its current state."
      echo "  No DB snapshot exists; full rollback is not possible for this upgrade."
      return 1
      ;;
  esac
}

_update_pull_images() {
  local force_upgrade="$1"
  local version="$2"

  # Skip-able via --force-upgrade for the rare case where we want to
  # attempt a pull even when reachability probing failed.
  if [ "$force_upgrade" = false ]; then
    if ! check_image_availability "$TEMP_FILE"; then
      echo ""
      log_fail "Cannot proceed with upgrade - some images are not available"
      echo "Please ensure all images are built and pushed to the registry"
      echo ""
      echo "To proceed anyway, use: $0 update $version --force-upgrade"
      echo "WARNING: Proceeding without verifying image availability may cause upgrade failures"
      rm -f "$TEMP_FILE"
      return 1
    fi
  else
    log_warn "WARNING: Skipping image availability check (--force-upgrade flag used)"
    echo ""
  fi

  echo ""
  # Authenticate to Docker Hub if credentials are available. Support the
  # canonical PAT name plus the older TOKEN alias, and read from .env so sudo
  # update runs do not depend on the caller preserving environment variables.
  local dockerhub_username="${DOCKERHUB_USERNAME:-$(env_get DOCKERHUB_USERNAME)}"
  local dockerhub_token="${DOCKERHUB_PAT:-${DOCKERHUB_TOKEN:-}}"
  [ -z "$dockerhub_token" ] && dockerhub_token="$(env_get DOCKERHUB_PAT)"
  [ -z "$dockerhub_token" ] && dockerhub_token="$(env_get DOCKERHUB_TOKEN)"
  if [ -n "$dockerhub_username" ] && [ -n "$dockerhub_token" ]; then
    echo "Logging in to Docker Hub as ${dockerhub_username}..."
    if ! docker_login_for_pulls "$dockerhub_username" "$dockerhub_token"; then
      print_failure_card \
        "Docker Hub login failed" \
        "The configured Docker Hub credentials were rejected." \
        "The update cannot pull required service images." \
        "Update DOCKERHUB_PAT/DOCKERHUB_TOKEN and DOCKERHUB_USERNAME, then retry the update." \
        "${ENV_FILE}"
      rm -f "$TEMP_FILE"
      return 1
    fi
  else
    # Bad cached Docker credentials cause public pulls to fail with
    # "incorrect username or password". With no configured creds, clear the
    # stale daemon/client auth entry and let Docker pull anonymously.
    docker_logout_for_pulls >/dev/null 2>&1 || true
  fi

  local digest_manifest
  digest_manifest=$(_image_digest_manifest_tmp_path)
  if [ -f "$digest_manifest" ]; then
    echo "Pulling release images by expected digest..."
    local active_images active_rc
    active_images=$(
      COMPOSE_PROFILES="$(env_get COMPOSE_PROFILES)" \
        $DOCKER_COMPOSE_CMD -f "$TEMP_FILE" config --images 2>/dev/null | sort -u
    )
    active_rc=$?
    if [ "$active_rc" -ne 0 ]; then
      log_fail "Failed to render active image list from $TEMP_FILE"
      rm -f "$TEMP_FILE"
      return 1
    fi

    local missing_images="" active_img
    while IFS= read -r active_img; do
      [ -n "$active_img" ] || continue
      if ! awk -F '\t' -v image="$active_img" '$1 == image { found = 1; exit } END { exit(found ? 0 : 1) }' "$digest_manifest"; then
        missing_images="${missing_images}${missing_images:+, }${active_img}"
      fi
    done <<EOF
$active_images
EOF
    if [ -n "$missing_images" ]; then
      log_fail "Digest manifest is missing active image(s): $missing_images"
      rm -f "$TEMP_FILE"
      return 1
    fi

    local manifest_entries=0
    local skipped=0
    local pulled=0
    local failed_pulls=0
    local img digest
    PULL_IMAGE_LAST_LOG=""

    while IFS=$'\t' read -r img digest || [ -n "$img$digest" ]; do
      img=$(printf '%s' "$img" | tr -d '\r')
      digest=$(printf '%s' "$digest" | tr -d '\r')
      case "$img" in
        ""|\#*) continue ;;
      esac
      if ! printf '%s\n' "$active_images" | grep -Fx "$img" >/dev/null; then
        log_verbose "Skipping inactive profile image: $img"
        continue
      fi
      manifest_entries=$((manifest_entries + 1))
      if [ -z "$digest" ]; then
        log_fail "Invalid image digest manifest entry for ${img}"
        rm -f "$TEMP_FILE"
        return 1
      fi

      if docker_for_pulls image inspect "$img" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null | grep -F "@${digest}" >/dev/null; then
        log_verbose "Already verified: $img@$digest"
        skipped=$((skipped + 1))
        continue
      fi

      if _pull_image_at_digest "$img" "$digest"; then
        pulled=$((pulled + 1))
      else
        failed_pulls=$((failed_pulls + 1))
        print_image_pull_failure "${img}@${digest}" "$PULL_IMAGE_LAST_LOG"
        log_info "Image download summary: $pulled verified downloads, $skipped already verified, $failed_pulls failed."
        rm -f "$TEMP_FILE"
        return 1
      fi
    done < "$digest_manifest"

    if [ "$manifest_entries" -eq 0 ]; then
      log_fail "Digest manifest is empty; refusing to continue with ambiguous image pulls."
      rm -f "$TEMP_FILE"
      return 1
    fi

    log_ok "Images ready: $pulled verified downloads, $skipped already verified."
    return 0
  fi

  # Always refresh CallTelemetry-owned service images. Release tags can be
  # republished during promotion repair, and a local tag-only match is not
  # sufficient proof that the appliance has the intended image digest.
  # Non-CallTelemetry infrastructure images are still skipped here when present
  # and handled by the compose pull below.
  echo "Checking which images need updating..."
  local skipped=0
  local pulled=0
  local failed_pulls=0
  PULL_IMAGE_LAST_LOG=""

  # Core services
  while IFS= read -r img; do
    if should_refresh_service_image "$img"; then
      if pull_image_quiet "$img"; then
        pulled=$((pulled + 1))
      else
        failed_pulls=$((failed_pulls + 1))
        print_image_pull_failure "$img" "$PULL_IMAGE_LAST_LOG"
        log_info "Image download summary: $pulled refreshed, $skipped already present, $failed_pulls failed."
        rm -f "$TEMP_FILE"
        return 1
      fi
    elif docker image inspect "$img" >/dev/null 2>&1; then
      log_verbose "Already present: $img"
      skipped=$((skipped + 1))
    else
      if pull_image_quiet "$img"; then
        pulled=$((pulled + 1))
      else
        failed_pulls=$((failed_pulls + 1))
        print_image_pull_failure "$img" "$PULL_IMAGE_LAST_LOG"
        log_info "Image download summary: $pulled refreshed, $skipped already present, $failed_pulls failed."
        rm -f "$TEMP_FILE"
        return 1
      fi
    fi
  done < <(extract_images "$TEMP_FILE")

  # JTAPI profile images (if enabled).
  # JTAPI is opt-in, so when is_jtapi_enabled a pull failure on a
  # profile image means the sidecar stack won't come up post-upgrade.
  # Treat as fatal rather than warn-and-continue — consistent with
  # core-service pull handling above, and surfaces the failure during
  # preflight instead of 20 minutes later during wait_for_services.
  if is_jtapi_enabled; then
    local svc img compose_rendered compose_rc
    compose_rendered=$($DOCKER_COMPOSE_CMD -f "$TEMP_FILE" --profile jtapi config 2>&1)
    compose_rc=$?
    if [ "$compose_rc" -ne 0 ]; then
      log_fail "Failed to render the JTAPI profile from $TEMP_FILE"
      printf '%s\n' "$compose_rendered" | sed 's/^/  /'
      rm -f "$TEMP_FILE"
      return 1
    fi
    for svc in jtapi-sidecar ct-media seaweedfs; do
      # Scan the full service block for image: instead of assuming it's
      # on the very next line after the service header. Compose render
      # can reorder keys — mem_limit/environment/etc. commonly appear
      # before image: — and the old grep -A1 pattern missed those,
      # silently skipping required JTAPI image checks.
      img=$(printf '%s\n' "$compose_rendered" | awk -v header="  ${svc}:" '
        $0 == header { in_svc = 1; next }
        in_svc && /^  [^ ]/ { in_svc = 0 }
        in_svc && /^    image:/ {
          sub(/^    image:[[:space:]]*/, "")
          gsub(/"/, "")
          print
          exit
        }
      ')
      if [ -n "$img" ]; then
        if should_refresh_service_image "$img"; then
          if pull_image_quiet "$img"; then
            pulled=$((pulled + 1))
          else
            failed_pulls=$((failed_pulls + 1))
            print_image_pull_failure "$img" "$PULL_IMAGE_LAST_LOG"
            log_info "Image download summary: $pulled refreshed, $skipped already present, $failed_pulls failed."
            rm -f "$TEMP_FILE"
            return 1
          fi
        elif docker image inspect "$img" >/dev/null 2>&1; then
          log_verbose "Already present: $img"
          skipped=$((skipped + 1))
        else
          if pull_image_quiet "$img"; then
            pulled=$((pulled + 1))
          else
            failed_pulls=$((failed_pulls + 1))
            print_image_pull_failure "$img" "$PULL_IMAGE_LAST_LOG"
            log_info "Image download summary: $pulled refreshed, $skipped already present, $failed_pulls failed."
            rm -f "$TEMP_FILE"
            return 1
          fi
        fi
      fi
    done
  fi

  log_ok "Images ready: $pulled refreshed, $skipped already present."

  # Pull any remaining images not covered above (e.g. calltelemetry/postgres,
  # infrastructure images with non-versioned tags). Uses the new compose file
  # so it pulls the correct versions for the upgrade target.
  echo "Pulling remaining infrastructure images..."
  local compose_pull_log compose_pull_rc
  compose_pull_log=$(mktemp 2>/dev/null || echo "/tmp/compose-pull-$$-${RANDOM}.log")
  if compose_pull_for_update "$TEMP_FILE" >"$compose_pull_log" 2>&1; then
    rm -f "$compose_pull_log"
  else
    compose_pull_rc=$?
    local compose_failure_kind
    compose_failure_kind=$(image_pull_failure_kind "$compose_pull_log" || true)
    if [ "$compose_failure_kind" = "docker_permission" ]; then
      print_failure_card \
        "Could not refresh remaining service images" \
        "Docker could not access the local Docker daemon while refreshing remaining service images." \
        "The update did not complete." \
        "Verify /var/run/docker.sock access for the update process (permissions, ACLs, or SELinux), then retry the update." \
        "$compose_pull_log"
    elif [ "$compose_failure_kind" = "docker_unreachable" ]; then
      print_failure_card \
        "Could not refresh remaining service images" \
        "The local Docker daemon was unreachable while refreshing remaining service images." \
        "The update did not complete." \
        "Start or repair the Docker daemon, then retry the update." \
        "$compose_pull_log"
    else
      print_failure_card \
        "Could not refresh remaining service images" \
        "docker compose pull failed while downloading one or more images." \
        "The update did not complete." \
        "Check registry access and retry the update." \
        "$compose_pull_log"
    fi
    rm -f "$TEMP_FILE"
    return "$compose_pull_rc"
  fi

  # "Image versions to be deployed" listing is verbose-only — duplicates
  # the per-image availability/pull status lines above and isn't
  # actionable for the operator at this point.
  if cli_verbose; then
    echo ""
    echo "Image versions to be deployed:"
    extract_images "$TEMP_FILE" | while read image; do
      echo "  - $image"
    done
  fi
  return 0
}

_update_confirm_apply() {
  local current_version="$1" target_version="$2" skip_cleanup="$3"

  echo ""
  log_info "Upgrade plan: $current_version -> $target_version"
  echo "This will:"
  echo "  - Stop all services"
  echo "  - Update container images"
  echo "  - Restart services"
  if [ "$skip_cleanup" = false ]; then
    echo "  - Run automatic cleanup"
  else
    echo "  - Skip automatic cleanup (--no-cleanup)"
  fi
  echo ""

  # Interactive: blocking [Y/n] prompt, default Yes.
  # Non-interactive: just proceed (existing behavior).
  # _FORCE_TTY is a test-only escape hatch; gated by CT_CLI_TEST_MODE=1
  # so it cannot accidentally force prompts in production automation.
  if { [ "${_FORCE_TTY:-}" = "1" ] && [ "${CT_CLI_TEST_MODE:-}" = "1" ]; } || [[ -t 0 ]]; then
    local answer=""
    if ! read -r -p "Proceed with upgrade? [Y/n]: " answer; then
      # EOF (Ctrl-D / closed stdin) — treat as cancel, not as default-Yes.
      echo "Upgrade cancelled (no confirmation received)"
      rm -f "$TEMP_FILE"
      return 1
    fi
    case "${answer,,}" in
      ""|y|yes) ;;          # default Y: proceed (Enter pressed)
      *)
        echo "Upgrade cancelled by user"
        rm -f "$TEMP_FILE"
        return 1
        ;;
    esac
  else
    log_info "non-interactive mode: proceeding automatically"
    sleep 2
  fi
  return 0
}

_update_apply_compose_file() {
  local enable_ipv6="$1"

  # NOTE: PostgreSQL version guard removed — no longer auto-downloads
  # docker-compose.override.yml during upgrades. Users who need a specific
  # PG version can run: cli.sh postgres set <version>
  mv "$TEMP_FILE" "$ORIGINAL_FILE"
  echo "New docker-compose.yml moved to production."

  local digest_dst digest_tmp
  digest_dst=$(_image_digest_manifest_path)
  digest_tmp=$(_image_digest_manifest_tmp_path)
  if [ -f "$digest_tmp" ]; then
    mv "$digest_tmp" "$digest_dst"
  else
    rm -f "$digest_dst"
  fi

  # Configure IPv6 settings based on --ipv6 flag
  configure_ipv6 "$ORIGINAL_FILE" "$enable_ipv6"

  # Pre-flight: repair Docker-created directories for config bind mounts.
  # When upgrading from versions that didn't have Loki/Alloy/Tempo, Docker
  # creates the mount target as a directory instead of a file. Fix it now.
  # Actual config files are deployed via the release bundle (bundle-manifest.yml).
  local config_pair config_path
  for config_pair in "loki/loki.yaml" "alloy/config.alloy" "tempo/tempo.yaml" "otel-collector/otel-collector-config.yaml"; do
    config_path="${INSTALL_DIR}/${config_pair}"
    if [ -d "$config_path" ]; then
      echo "  Fixing Docker-created directory: $config_path"
      rm -rf "$config_path"
    fi
  done

  fix_systemd_service_if_needed
  fix_systemd_compose_files

  # Ensure PG/pool .env defaults exist (no-clobber — preserves customer overrides)
  ensure_postgres_defaults

  # Correct PG_MAX_CONNECTIONS to pool_sum+25 (floor 200). Runs every upgrade
  # so stale over/under values are silently fixed without operator intervention.
  _migrate_pg_max_connections

  # Ensure container CPU-limit .env defaults match the host's actual vCPU
  # count. The canonical docker-compose.yml has cpus: ${DB_CPU_LIMIT:-4.0}
  # (and similar) for the heavy consumers; on a 2-vCPU host the 4.0 default
  # hard-fails compose-up because Docker refuses cpus > host cpu count.
  # Writing DB_CPU_LIMIT=1.5 into .env here makes the restart succeed with
  # a scaled-down but functional container. No-clobber so explicit operator
  # overrides in .env are preserved across upgrades.
  ensure_cpu_defaults

  # Remove legacy postgres override file — ONLY the auto-generated one
  # shipped with PG 14, identified by its distinctive hardcoded tuning
  # keys (max_connections=300 AND autovacuum_max_workers=5). The main
  # docker-compose.yml now drives those from .env.
  #
  # NOTE: `cli.sh postgres set/upgrade` writes override files that also
  # reference `calltelemetry/postgres`, so the previous single-predicate
  # grep would nuke a deliberate operator pin on every upgrade. The
  # tuning-key combination below is unique to the auto-generated legacy
  # file and absent from downloaded per-version overrides.
  if [ -f "$POSTGRES_OVERRIDE_FILE" ] \
     && grep -q "calltelemetry/postgres" "$POSTGRES_OVERRIDE_FILE" 2>/dev/null \
     && grep -q "max_connections=300" "$POSTGRES_OVERRIDE_FILE" 2>/dev/null \
     && grep -q "autovacuum_max_workers=5" "$POSTGRES_OVERRIDE_FILE" 2>/dev/null; then
    echo "Removing legacy PostgreSQL override file ($POSTGRES_OVERRIDE_FILE)..."
    rm -f "$POSTGRES_OVERRIDE_FILE"
    log_ok "Removed — PG settings now driven by .env (cli.sh postgres profile)"
  fi

  repair_postgres_compat "$(get_current_postgres_image)" || return 1
  return 0
}

_update_ensure_swap_sized() {
  # Swap target sizing:
  #   - 8GB on boxes with less than 16GB RAM
  #   - 50% of RAM on boxes with 16GB or more
  # The /swapfile is right-sized (grown OR shrunk) so that total swap lands
  # exactly on the target. A pre-existing swap partition counts against the
  # target — if the partition already covers it, /swapfile is removed.
  local SWAPFILE="/swapfile"
  local total_ram_gb target_swap_gb non_file_swap_gb swapfile_target_gb current_swapfile_gb current_total_gb
  total_ram_gb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
  if [ "$total_ram_gb" -ge 16 ]; then
    target_swap_gb=$(( total_ram_gb / 2 ))
  else
    target_swap_gb=8
  fi
  if [ -f "$SWAPFILE" ]; then
    current_swapfile_gb=$(( $(stat -c%s "$SWAPFILE") / 1024 / 1024 / 1024 ))
  else
    current_swapfile_gb=0
  fi
  current_total_gb=$(( $(free | awk '/^Swap:/{print $2}') / 1024 / 1024 ))
  non_file_swap_gb=$(( current_total_gb - current_swapfile_gb ))
  if [ "$non_file_swap_gb" -lt 0 ]; then
    non_file_swap_gb=0
  fi

  # Exact-fit: swapfile should bring total swap to exactly target_swap_gb.
  # If non-file swap (partition) already meets or exceeds the target, we
  # remove the swapfile entirely.
  if [ "$non_file_swap_gb" -ge "$target_swap_gb" ]; then
    swapfile_target_gb=0
  else
    swapfile_target_gb=$(( target_swap_gb - non_file_swap_gb ))
  fi

  if [ "$current_swapfile_gb" -eq "$swapfile_target_gb" ]; then
    # Swap already at target — internal chatter for verbose runs only.
    # A swap resize still emits a loud log below.
    log_verbose_ok "Swap is ${current_total_gb}GB (RAM: ${total_ram_gb}GB, target: ${target_swap_gb}GB, swapfile: ${current_swapfile_gb}GB)"
    return 0
  fi

  if [ "$current_swapfile_gb" -lt "$swapfile_target_gb" ]; then
    echo "Swap below target — growing /swapfile from ${current_swapfile_gb}GB to ${swapfile_target_gb}GB (RAM: ${total_ram_gb}GB, target: ${target_swap_gb}GB)..."
  else
    echo "Swap above target — shrinking /swapfile from ${current_swapfile_gb}GB to ${swapfile_target_gb}GB (RAM: ${total_ram_gb}GB, target: ${target_swap_gb}GB)..."
  fi

  echo "Swap needs resize (current swapfile: ${current_swapfile_gb}GB, target: ${swapfile_target_gb}GB) — stopping services..."
  systemctl stop docker-compose-app.service 2>/dev/null || true
  if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^${SWAPFILE}$"; then
    if ! sudo swapoff "$SWAPFILE"; then
      log_warn "swapoff $SWAPFILE failed — leaving existing swap in place"
      return 0
    fi
  fi
  # Error-check each step. Swap is nice-to-have, not critical, so a
  # failure here logs a warning and continues rather than aborting the
  # upgrade — the appliance can run without the extra swap. But we
  # surface the failure so the operator knows to resize manually later.
  #
  # On any failure path we ALSO strip $SWAPFILE from /etc/fstab if it's
  # listed there — otherwise a subsequent reboot tries to swapon a file
  # that either doesn't exist (we rm'd it) or is half-written, producing
  # boot-time errors every time the box restarts.
  if [ "$swapfile_target_gb" -gt 0 ]; then
    sudo rm -f "$SWAPFILE"
    if ! sudo fallocate -l "${swapfile_target_gb}G" "$SWAPFILE" 2>/dev/null; then
      if ! sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(( swapfile_target_gb * 1024 )) status=none; then
        log_warn "Failed to allocate ${swapfile_target_gb}G swapfile — skipping swap resize"
        sudo rm -f "$SWAPFILE"
        sudo sed -i "\|^${SWAPFILE}[[:space:]]|d" /etc/fstab
        return 0
      fi
    fi
    if ! sudo chmod 600 "$SWAPFILE" || ! sudo mkswap "$SWAPFILE" > /dev/null; then
      log_warn "Failed to format ${SWAPFILE} — skipping swap resize"
      sudo rm -f "$SWAPFILE"
      sudo sed -i "\|^${SWAPFILE}[[:space:]]|d" /etc/fstab
      return 0
    fi
    if ! sudo swapon "$SWAPFILE"; then
      log_warn "swapon ${SWAPFILE} failed — swap is NOT active. Check dmesg."
      sudo rm -f "$SWAPFILE"
      sudo sed -i "\|^${SWAPFILE}[[:space:]]|d" /etc/fstab
      return 0
    fi
    if ! grep -q "^${SWAPFILE}" /etc/fstab; then
      echo "${SWAPFILE} none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
  else
    sudo rm -f "$SWAPFILE"
    sudo sed -i "\|^${SWAPFILE}[[:space:]]|d" /etc/fstab
  fi
  log_ok "Swap set to $(( $(free | awk '/^Swap:/{print $2}') / 1024 / 1024 ))GB"
}

_update_post_install_fixes() {
  local version="$1"

  _update_cli_tools_quiet

  # Apply console loglevel fix for existing VMs
  # nft_compat / ip_set are loaded by Docker/firewalld and emit KERN_WARNING (level 4).
  # loglevel=3 on the kernel cmdline is reset by systemd; sysctl.d persists it.
  if [ ! -f /etc/sysctl.d/99-console-loglevel.conf ]; then
    echo "Applying console loglevel fix (suppresses nft_compat/ip_set warnings)..."
    echo "kernel.printk = 3 4 1 3" | sudo tee /etc/sysctl.d/99-console-loglevel.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-console-loglevel.conf > /dev/null
    log_ok "Console loglevel fix applied"
  fi

  # Migrate legacy ifcfg network configs to NetworkManager keyfile format
  # RHEL 9 / AlmaLinux 9 deprecated network-scripts ifcfg files; NM logs deprecation
  # warnings for any connection still using the ifcfg backend.
  if command -v nmcli &>/dev/null; then
    local ifcfg_count
    ifcfg_count=$(nmcli -t -f FILENAME connection show 2>/dev/null | grep -c 'ifcfg' || true)
    if [ "${ifcfg_count:-0}" -gt 0 ]; then
      echo "Migrating $ifcfg_count legacy ifcfg network config(s) to keyfile format..."
      sudo nmcli connection migrate &>/dev/null && log_ok "Network configs migrated to keyfile" || log_warn "nmcli migrate failed (non-critical)"
    fi
  fi

  # Ensure the env file has GRAFANA_PASSWORD as an idempotent migration/default
  # safeguard. The pre-validation call that avoids docker compose interpolation
  # warnings happens earlier in update() and restart_service(); do not reset the
  # Grafana admin password here, as this is not a credential rotation.
  if ! ensure_grafana_password; then
    return 1
  fi
  if [ "${CT_GRAFANA_PASSWORD_WAS_GENERATED:-0}" = "1" ] && command -v docker >/dev/null 2>&1; then
    if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -Eq '(^|_)grafana-data$'; then
      log_warn "GRAFANA_PASSWORD was newly added to ${ENV_FILE}, but existing Grafana data may still use the previous admin password."
      echo "If Grafana authentication fails, resync it manually with:"
      echo "  cd ${INSTALL_DIR} && set -a && . ./.env && set +a && docker compose exec grafana grafana-cli admin reset-admin-password \"\$GRAFANA_PASSWORD\""
    fi
  fi

  # Cap Docker daemon at 90% RAM — reserve 10% for OS (kernel, systemd, sshd)
  local DOCKER_DROPIN_DIR="/etc/systemd/system/docker.service.d"
  local DOCKER_DROPIN_FILE="${DOCKER_DROPIN_DIR}/memory-limit.conf"
  if [ ! -f "$DOCKER_DROPIN_FILE" ] || grep -q 'MemoryMax=80%' "$DOCKER_DROPIN_FILE" 2>/dev/null; then
    echo "Applying Docker memory limit (90% of RAM)..."
    sudo mkdir -p "$DOCKER_DROPIN_DIR"
    printf '[Service]\nMemoryMax=90%%\n' | sudo tee "$DOCKER_DROPIN_FILE" > /dev/null
    sudo systemctl daemon-reload
    log_ok "Docker memory limit applied (90% of RAM)"
  fi

  # Mark partition drain as complete for ct-cli compatibility.
  # The actual drain runs automatically in onprem-start.sh (container entrypoint)
  # BEFORE the app starts — zero lock contention. It's a no-op if nothing to drain.
  if ! ct_migration_done "014_partition_drain" && [ "$(printf '%s\n' "0.8.6-rc166" "$version" | sort -V | head -n1)" = "0.8.6-rc166" ]; then
    ct_migration_mark "014_partition_drain" "applied"
    # Partition migration is delegated to container startup — a status
    # message about "handled by container startup" is internal plumbing.
    log_verbose_ok "Partition data migration handled by container startup (check docker logs for progress)"
  fi
}

# Function to update the docker-compose configuration
update() {
  # Note: cli.sh is updated via the config bundle download
  require_root "update" || return 1
  CT_GRAFANA_PASSWORD_WAS_GENERATED=0

  version=""
  force_upgrade=false
  skip_cleanup=false
  enable_ipv6=false
  local backup_db_flag="prompt"   # "yes" | "no" | "prompt"

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-upgrade) force_upgrade=true; shift ;;
      --no-cleanup)    skip_cleanup=true;   shift ;;
      --ipv6)          enable_ipv6=true;    shift ;;
      --stable)        version="stable";    shift ;;
      --latest)        version="latest";    shift ;;
      --dev)           version="dev";       shift ;;
      --rc)
        # Deprecated alias for --dev. Both used to read separate markers
        # (latest-rc.txt vs latest-dev.txt); the rc lane was never populated
        # in production and duplicated the dev concept. Kept working for one
        # release so existing automation doesn't break.
        printf 'Warning: --rc is deprecated; use --dev (reads the same channel).\n' >&2
        version="dev"
        shift
        ;;
      --backup-db)     backup_db_flag="yes"; shift ;;
      --no-backup-db)  backup_db_flag="no";  shift ;;
      --verbose|-v)    export CLI_VERBOSE=1; shift ;;
      *)
        if [ -z "$version" ]; then version="$1"; fi
        shift
        ;;
    esac
  done

  log_step "Resolving target version"
  version=$(_update_resolve_version "$version") || return 1

  current_version=$(get_current_version)
  echo "Current version: $current_version"
  echo "Target version:  $version"
  echo ""

  log_step "Pre-flight checks"
  _update_preflight_checks "$version" "$force_upgrade" || return 1

  # Adopt the working POSTGRES_PASSWORD into .env BEFORE snapshotting.
  # On legacy appliances (pre-rc267) the .env never carried
  # POSTGRES_PASSWORD — the db container was initdb'd with the
  # compose-default literal "postgres". Snapshotting .env at that
  # point captures a credential-less file, and the promised
  # pre-upgrade DB snapshot / `rollback --with-db` then fail to
  # authenticate exactly on the hosts this feature is meant to
  # protect. ensure_postgres_password is idempotent (no-op when
  # POSTGRES_PASSWORD is already set), safe to call here.
  if ! ensure_postgres_password; then
    log_fail "Unable to adopt a working POSTGRES_PASSWORD before snapshotting."
    echo "   Set POSTGRES_PASSWORD in ${ENV_FILE} to the current DB password and retry."
    return 1
  fi
  if ! ensure_grafana_password; then
    log_fail "Unable to generate GRAFANA_PASSWORD before compose validation."
    echo "   Install openssl or python3 and retry."
    return 1
  fi

  # Compose + .env snapshot runs BEFORE download_bundle merges version
  # pins into .env. The timestamp is stashed in _UPDATE_SNAPSHOT_TS for
  # the DB-snapshot and failback prompt steps below.
  if ! _update_backup_current_compose; then
    log_fail "Pre-upgrade compose/.env snapshot failed — refusing to continue."
    echo "   Nothing has been modified. Resolve the snapshot error (usually disk space"
    echo "   or permissions on $BACKUP_DIR) and retry."
    return 1
  fi
  local snapshot_ts="${_UPDATE_SNAPSHOT_TS:-}"

  log_step "Downloading release bundle"
  # Bundle contains docker-compose.yml, .env pins, prometheus/grafana configs, cli.sh, etc.
  if ! download_bundle "$version"; then
    log_fail "Failed to download config bundle"
    echo ""
    echo "Check available versions at: https://github.com/calltelemetry/calltelemetry/releases"
    return 1
  fi
  echo ""

  log_step "Checking image availability"
  _update_pull_images "$force_upgrade" "$version" || return 1

  # User-cancel propagates as non-zero exit so automation wrappers
  # (ansible, CI jobs) can distinguish "upgrade finished" from
  # "operator aborted the 5-second prompt".
  _update_confirm_apply "$current_version" "$version" "$skip_cleanup" || return 1

  # DB snapshot prompt runs AFTER the operator committed to the upgrade
  # but BEFORE any on-disk mutation by _update_apply_compose_file. If
  # the operator declines, any stale db-latest.* is cleared so the
  # failback path doesn't misread an old dump as current.
  #
  # Skip the DB-snapshot step entirely when snapshot_ts is empty
  # (fresh-install path — no compose/.env was backed up, so a DB dump
  # written now would have no matching pair and never be offered to
  # rollback).
  if [ -n "$snapshot_ts" ]; then
    log_step "Creating pre-upgrade database snapshot"
    if ! _update_create_snapshot "$snapshot_ts" "$backup_db_flag"; then
      log_fail "Pre-upgrade snapshot failed. Aborting upgrade."
      return 1
    fi
  fi

  log_step "Applying upgrade"

  # Config files (nats.conf, Caddyfile, prometheus, grafana) already extracted by download_bundle()
  if [ ! -f "$TEMP_FILE" ]; then
    echo "Failed to download new docker-compose.yml or other required files. No changes made."
    _update_restore_snapshot_writers_if_needed
    return 1
  fi

  if ! _update_apply_compose_file "$enable_ipv6"; then
    _update_restore_snapshot_writers_if_needed
    return 1
  fi

  _update_ensure_swap_sized

  if ! restart_service "upgrade"; then
    UPDATE_SNAPSHOT_WRITERS_STOPPED=0
    echo ""
    log_fail "Update FAILED — Docker Compose service could not be restarted."
    echo "   The new docker-compose.yml is in place but services are not running."
    echo "   To retry:  systemctl restart docker-compose-app.service"
    if [ -n "$snapshot_ts" ]; then
      echo "   To revert: cli.sh rollback --snapshot $snapshot_ts --with-env"
    else
      echo "   No pre-upgrade snapshot exists for this run (fresh install)."
    fi
    return 1
  fi
  UPDATE_SNAPSHOT_WRITERS_STOPPED=0

  if [ "$skip_cleanup" = false ]; then
    purge_docker
  else
    log_warn "Skipping Docker cleanup (--no-cleanup)."
  fi

  log_step "Monitoring service startup"
  wait_for_services 1 1 1
  services_ok=$?

  _update_post_install_fixes "$version"

  if [ $services_ok -eq 0 ]; then
    log_ok "Update complete! All services are running and ready."
    return 0
  fi

  log_warn "Update applied, but startup checks failed (see errors above)."
  echo "  Run 'cli.sh status' to check current state."
  echo ""

  # Failback prompt — inspects _WAIT_FAILED_PHASES and offers a scoped
  # rollback. Always operator-initiated, no timeout, default-No.
  _update_prompt_rollback "$services_ok" "$snapshot_ts"

  # Intentional CLI behavior change: return non-zero when
  # wait_for_services didn't complete cleanly, even if the operator
  # then rolled back successfully. Prior versions fell through to
  # effective exit 0, which misled `cli.sh update && …` automation
  # into thinking a half-started upgrade was successful. This is
  # called out in the PR description as a breaking change for any
  # wrapper that previously expected exit 0 on startup-check failures.
  return 1
}

# Function to perform rollback to the old configuration.
#
# Backward-compatible: bare `cli.sh rollback` still restores compose
# only (no .env, no DB) using the most recent snapshot — same behavior
# operators have relied on. Flags extend the scope:
#
#   --with-env             also restore paired env-<ts>.bak
#   --with-db              also restore db-latest.sql.gz (full DB restore,
#                          double-confirm prompt, pairs via meta sidecar)
#   --snapshot <ts>        pick a specific compose+env set
#   --list                 print the available snapshot inventory
rollback() {
  # require_root is deferred until after flag parsing — --list is a
  # read-only inventory, operators shouldn't need sudo just to see
  # which snapshots are available.
  local with_env=0 with_db=0 explicit_ts="" want_list=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-env) with_env=1; shift ;;
      --with-db)  with_db=1;  shift ;;
      --snapshot)
        # Validate: a timestamp must follow, and it can't be another flag.
        if [ -z "${2:-}" ] || [[ "${2}" == --* ]]; then
          log_fail "--snapshot requires a timestamp argument."
          return 1
        fi
        # Reject anything that isn't our exact timestamp shape. The value
        # is interpolated into paths passed to root-owned cp/mv, so a
        # stray `..` or `/` would be a path-traversal footgun.
        if ! [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
          log_fail "--snapshot timestamp must be YYYY-MM-DD-HH-MM-SS (got: $2)"
          return 1
        fi
        explicit_ts="$2"
        shift 2
        ;;
      --list)     want_list=1; shift ;;
      *)
        # Fail fast on typos — rollback is destructive enough that silently
        # ignoring `--snapshop` and restoring the most-recent set is worse
        # than erroring.
        log_fail "Unknown argument: $1"
        return 1
        ;;
    esac
  done

  if [ "$want_list" = "1" ]; then
    _update_list_snapshots
    return 0
  fi

  # Everything below this point mutates system state — require root now.
  require_root "rollback" || return 1

  # --with-db implies --with-env. Restoring only the DB while leaving
  # the new .env in place creates a schema/config mismatch that's very
  # easy to miss. Make the pairing explicit so the restored state is
  # coherent end-to-end.
  if [ "$with_db" = "1" ] && [ "$with_env" != "1" ]; then
    log_warn "--with-db implies --with-env; enabling env restore for a coherent rollback."
    with_env=1
  fi

  # Default to the most recent snapshot if the operator didn't pick one.
  local ts="$explicit_ts"
  if [ -z "$ts" ]; then
    local latest
    latest=$(ls -t "$BACKUP_DIR"/docker-compose-*.yml 2>/dev/null | head -n 1)
    if [ -z "$latest" ]; then
      log_fail "No compose backup found in $BACKUP_DIR."
      return 1
    fi
    ts=$(basename "$latest")
    ts="${ts#docker-compose-}"
    ts="${ts%.yml}"
  fi

  # --with-db is destructive — always double-confirm before dropping DB.
  # And refuse it outright in non-interactive contexts: a blocking `read`
  # with stdin open-but-not-a-terminal would hang indefinitely in
  # Ansible/systemd-run/CI. _update_prompt_rollback() already solves
  # this; mirror the same pattern here.
  if [ "$with_db" = "1" ]; then
    if [ ! -t 0 ]; then
      log_fail "--with-db requires an interactive TTY for confirmation."
      echo "   Run this interactively to perform a full DB restore."
      return 1
    fi
    echo ""
    log_warn "About to DROP and RECREATE calltelemetry_prod from $BACKUP_DIR/db-latest.sql.gz."
    echo "        Current database contents will be lost."
    local confirm=""
    read -r -p "  Type 'yes' to confirm full DB restore: " confirm
    if [ "$confirm" != "yes" ]; then
      log_warn "Full DB restore cancelled."
      return 1
    fi
  fi

  _update_restore_snapshot "$ts" "$with_env" "$with_db"
}

# Function to reset the application by stopping services and removing data
reset_app() {
  echo "Stopping docker-compose application..."
  sudo systemctl stop docker-compose-app.service

  echo "Removing SFTP data..."
  sudo rm -rf $SFTP_DIR

  echo "Removing PostgreSQL data..."
  sudo rm -rf $POSTGRES_DATA_DIR

  echo "Removing backup files..."
  sudo rm -rf $BACKUP_DIR/*

  echo "Starting docker-compose application..."
  sudo systemctl start docker-compose-app.service

  echo "Reset complete."
}

# Function to compact the system
compact_system() {
  echo "Performing comprehensive system cleanup..."
  
  # First run our detailed purge function
  purge_docker
  
  echo "Running full Docker system prune..."
  docker system prune --all -f

  echo "Starting Docker Compose database service..."
  sudo $DOCKER_COMPOSE_CMD $(get_compose_files) up -d db

  echo "Waiting for the database service to be fully operational..."
  sleep 15

  echo "Verifying database connectivity..."
  if ! sudo $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "Error: Database is not ready. Cannot perform vacuum."
    return 1
  fi

  echo "Compacting PostgreSQL database (this may take several minutes)..."
  if sudo $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -d calltelemetry_prod -U calltelemetry -c 'VACUUM FULL;'; then
    log_ok "Database vacuum completed successfully."
  else
    log_fail "Database vacuum failed."
    return 1
  fi

  echo "System compaction complete."
}

# Function to wait for services to be ready
# Flow: 1) Wait for containers 2) Wait for DB 3) Wait for migrations 4) Health check
# Returns 0 on full success, 1 if any phase failed or timed out
# ── wait_for_services decomposition ─────────────────────────────────────
#
# wait_for_services() is split into per-phase helpers so each block has a
# single responsibility and is testable in isolation. Shared mutable state
# (failure counter + failed-phase labels + resolved service list) flows
# through a small set of module-level variables, set by the orchestrator
# and consumed by the helpers.
#
# Phase helpers:
#   _wait_resolve_expected_services — profile-aware service list + compose
#                                     render validation. Fills
#                                     _WAIT_EXPECTED_SERVICES. Returns non-zero
#                                     if compose is unrenderable or the list
#                                     drifts from what the bundle defines.
#   _wait_phase1_containers        — docker ps + status polling, 120s cap.
#   _wait_phase2_database          — pg_isready polling, 120s cap.
#   _wait_phase3_migrations        — artifact-first (RPC/eval/SQL fallback)
#                                    migration poll with active-query elapsed
#                                    time, max_wait cap.
#   _wait_phase4_health            — web healthz, traceroute healthz, RPC
#                                    liveness, scheduler warning scrape.
#
# Each phase helper records its own failures directly via _wait_record_failure.
# Heartbeat \r-updated status lines route through _wait_heartbeat so update can
# opt into concise output while shared wait callers keep live progress.

_WAIT_PHASE_FAILURES=0
_WAIT_FAILED_PHASES=""
_WAIT_EXPECTED_SERVICES=()
_WAIT_SUPPRESS_PHASE_BANNERS=0
_WAIT_SUPPRESS_HEARTBEATS=0

_wait_reset_state() {
  _WAIT_PHASE_FAILURES=0
  _WAIT_FAILED_PHASES=""
  _WAIT_EXPECTED_SERVICES=()
  _WAIT_SUPPRESS_PHASE_BANNERS=0
  _WAIT_SUPPRESS_HEARTBEATS=0
}

_wait_record_failure() {
  _WAIT_PHASE_FAILURES=$((_WAIT_PHASE_FAILURES + 1))
  _WAIT_FAILED_PHASES="$_WAIT_FAILED_PHASES $1"
}

_wait_heartbeat() {
  [ "$_WAIT_SUPPRESS_HEARTBEATS" = "1" ] && ! cli_verbose && return 0
  log_heartbeat "$@"
}

_wait_phase_banner() {
  if [ "$_WAIT_SUPPRESS_PHASE_BANNERS" = "1" ]; then
    log_verbose "$@"
  else
    log_info "$@"
  fi
}

_wait_required_containers_ok() {
  # Usage: _wait_required_containers_ok <service1> [service2 ...]
  # Returns 0 iff every named compose service has a container and it's
  # in state=running right now. Used by the orchestrator to gate each
  # downstream phase on the exact subset that phase actually talks to:
  #
  #   Phase 3 (migration polling)  → db + web
  #   Phase 4 (healthz + RPC)      → web + traceroute
  #
  # Narrow per-phase gating means a down monitoring sidecar (grafana,
  # jtapi-sidecar, loki, …) never hides migration or app-health
  # diagnostics on a healthy core stack.
  local s container status
  for s in "$@"; do
    container=$($DOCKER_COMPOSE_CMD ps -q "$s" 2>/dev/null)
    [ -z "$container" ] && return 1
    status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
    [ "$status" = "running" ] || return 1
  done
  return 0
}

_wait_resolve_expected_services() {
  # Always-on core services (no compose profile guard).
  local services=("db" "web" "caddy" "vue-web" "traceroute" "nats")

  # Opt-in profile expansions. Each profile is validated only when the
  # operator has explicitly activated it via COMPOSE_PROFILES in .env.
  # We do NOT add profile services to the required list otherwise — Phase 1
  # must not block on features the user did not turn on.
  if is_jtapi_enabled; then
    services+=("jtapi-sidecar" "ct-media" "seaweedfs")
  fi
  if is_otel_enabled; then
    services+=("prometheus" "alertmanager" "grafana" "loki" "tempo" "otel-collector")
  fi
  if is_storage_enabled; then
    services+=("seaweedfs")
  fi
  if is_syslog_enabled; then
    services+=("ct-syslog-ingest" "alloy")
  fi

  # Deduplicate — seaweedfs in particular is shared by storage/jtapi/otel.
  if [ "${#services[@]}" -gt 0 ]; then
    local _deduped=()
    local s existing found
    for s in "${services[@]}"; do
      found=0
      for existing in "${_deduped[@]}"; do
        if [ "$existing" = "$s" ]; then
          found=1
          break
        fi
      done
      if [ "$found" = "0" ]; then
        _deduped+=("$s")
      fi
    done
    services=("${_deduped[@]}")
  fi

  # Filter the expected list to services the active compose+profiles actually
  # define. Otherwise a stale bundle (e.g. one missing jtapi-sidecar/ct-media/
  # seaweedfs in the compose file) causes Phase 1 to hang for 120s waiting
  # for containers that can never exist. Fail fast with a clear diagnostic
  # instead — the operator can then pull a fresh bundle or adjust profiles.
  #
  # Distinguish "compose itself failed to render" (e.g. missing required env,
  # invalid YAML, docker daemon down) from "compose rendered but some
  # services aren't defined" — misreporting the former as the latter hides
  # the real problem.
  local defined_services compose_err compose_rc
  compose_err=$(mktemp 2>/dev/null || echo "/tmp/compose-err-$$-${RANDOM}")
  defined_services=$(COMPOSE_PROFILES="$(env_get COMPOSE_PROFILES)" \
    $DOCKER_COMPOSE_CMD $(get_compose_files) config --services 2>"$compose_err")
  compose_rc=$?
  if [ "$compose_rc" -ne 0 ]; then
    echo ""
    log_fail "docker compose config --services exited non-zero (rc=$compose_rc)."
    echo "       The compose file failed to render — cli.sh cannot determine which"
    echo "       services should be running without a valid render. Common causes:"
    echo "         - A required env var is unset (e.g. POSTGRES_PASSWORD)"
    echo "         - Invalid YAML / merge syntax in docker-compose.yml"
    echo "         - Docker daemon is unreachable"
    echo ""
    echo "       compose stderr:"
    sed 's/^/         /' "$compose_err" 2>/dev/null | head -20
    rm -f "$compose_err"
    collect_upgrade_diagnostics \
      "docker compose config failed (rc=$compose_rc)" \
      "stale-compose"
    return 1
  fi
  rm -f "$compose_err"

  local filtered=()
  local undefined=()
  local svc
  for svc in "${services[@]}"; do
    if printf '%s\n' "$defined_services" | grep -qx "$svc"; then
      filtered+=("$svc")
    else
      undefined+=("$svc")
    fi
  done
  if [ "${#undefined[@]}" -gt 0 ]; then
    echo ""
    log_fail "The following services are expected but are not defined in the"
    echo "       current docker-compose.yml with active profiles ($(env_get COMPOSE_PROFILES)):"
    echo "         ${undefined[*]}"
    echo ""
    echo "       This usually means the release bundle is stale or the compose"
    echo "       profiles in .env drifted from the bundle. Try:"
    echo "         1) Re-run 'cli.sh update' to pull the current bundle, or"
    echo "         2) Disable the feature in COMPOSE_PROFILES (.env) if you did"
    echo "            not intend to enable it (e.g. remove 'jtapi')."
    echo ""
    echo "       Refusing to wait 120s for containers that can never start."
    collect_upgrade_diagnostics \
      "expected services not defined in compose: ${undefined[*]}" \
      "stale-compose"
    return 1
  fi

  _WAIT_EXPECTED_SERVICES=("${filtered[@]}")
  return 0
}

_wait_phase1_containers() {
  local services=("$@")
  local wait_time=0
  repair_compose_bridge_once || true
  local containers_ok=false
  local status_line=""

  _wait_phase_banner "Phase 1: Waiting for containers..."

  while [ $wait_time -lt 120 ]; do
    local all_running=true
    status_line=""
    local service
    for service in "${services[@]}"; do
      local container
      container=$($DOCKER_COMPOSE_CMD ps -q "$service" 2>/dev/null)
      if [ -n "$container" ]; then
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
        if [ "$status" = "running" ]; then
          status_line="$status_line ✓$service"
        else
          status_line="$status_line [WAIT]$service"
          all_running=false
        fi
      else
        status_line="$status_line ✗$service"
        all_running=false
      fi
    done

    _wait_heartbeat "\r  Containers:%s" "$status_line"

    if [ "$all_running" = true ]; then
      cli_verbose && { cli_quiet || echo ""; }
      log_verbose_ok "All containers running"
      containers_ok=true
      break
    fi

    sleep 3
    wait_time=$((wait_time + 3))
  done

  if [ "$containers_ok" != true ]; then
    cli_verbose && { cli_quiet || echo ""; }
    log_fail "Container startup timed out after 120s"
    printf "  Not running: %s\n" \
      "$(printf '%s\n' "$status_line" | tr ' ' '\n' | grep -E '^(✗|\[WAIT\])' | tr '\n' ' ')"
    echo ""
    return 1
  fi
  cli_verbose && echo ""
  return 0
}

_wait_phase2_database() {
  local wait_time=0
  local db_ok=false

  _wait_phase_banner "Phase 2: Waiting for database..."

  while [ $wait_time -lt 120 ]; do
    repair_compose_bridge_once || true
    if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
      cli_verbose && { cli_quiet || echo ""; }
      log_verbose_ok "Database accepting connections"
      db_ok=true
      break
    fi
    _wait_heartbeat "\r  Database: connecting... (%ds)" "$wait_time"
    sleep 3
    wait_time=$((wait_time + 3))
  done

  if [ "$db_ok" != true ]; then
    cli_verbose && { cli_quiet || echo ""; }
    log_fail "Database connection timed out after 120s"
    echo ""
    return 1
  fi
  cli_verbose && echo ""
  return 0
}

_wait_active_query_elapsed_display() {
  # Prints " (NmNs)" / " (Ns)" for the longest-running non-admin query,
  # or nothing if the query is <=2s old or psql fails. Used by Phase 3
  # heartbeats to distinguish "migration running slowly" from "CLI frozen".
  local elapsed
  elapsed=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT EXTRACT(EPOCH FROM now() - query_start)::int FROM pg_stat_activity WHERE state = 'active' AND query NOT LIKE '%pg_stat_activity%' AND usename = 'calltelemetry' ORDER BY query_start LIMIT 1;" 2>/dev/null | tr -d ' \r\n')
  if ! [[ "$elapsed" =~ ^[0-9]+$ ]] || [ "$elapsed" -le 2 ]; then
    return 0
  fi
  local mins=$((elapsed / 60))
  local secs=$((elapsed % 60))
  if [ "$mins" -gt 0 ]; then
    printf ' (%dm%ds)' "$mins" "$secs"
  else
    printf ' (%ds)' "$secs"
  fi
}

_wait_phase3_migrations() {
  local max_wait="$1"
  local poll_interval=5
  local wait_time=0
  local release_bin
  release_bin=$(get_release_binary)
  local last_migration=""
  local migrations_complete=false
  local migrations_failed=false
  local stable_total_count=""
  local release_total_count=""
  local last_progress_signature=""
  local artifact_status_path=""
  local artifact_events_path=""
  local artifact_log_path=""

  _wait_phase_banner "Phase 3: Waiting for migrations..."

  while [ $wait_time -lt $max_wait ]; do
    repair_compose_bridge_once || true
    if [ -z "$release_total_count" ]; then
      release_total_count=$(get_release_migration_count "$release_bin")
      if ! [[ "$release_total_count" =~ ^[0-9]+$ ]] || [ "$release_total_count" -le 0 ]; then
        release_total_count=""
      fi
    fi

    # Prefer the release-side JSON artifact because it is written directly by the
    # migration loop. Fall back to RPC/eval only if the snapshot is not available yet.
    local migration_raw
    migration_raw=$(run_migration_status_artifact 2>/dev/null)
    if [ -z "$migration_raw" ]; then
      migration_raw=$(run_migration_status_rpc "$release_bin" 2>/dev/null)
    fi

    local progress_state=""
    local pending_count=""
    local applied_count=""
    local total_count=""
    local current_version=""
    local current_name=""
    local current_filename=""
    local current_description=""
    local current_started_at=""
    local current_runtime_ms=""
    local next_version=""
    local next_name=""
    local next_filename=""
    local next_description=""
    local latest_applied_name=""
    local latest_applied_filename=""
    local latest_applied_description=""
    local last_completed_version=""
    local last_completed_name=""
    local last_completed_filename=""
    local last_completed_description=""
    local last_completed_completed_at=""
    local last_completed_runtime_ms=""
    local updated_at=""
    local progress_error=""

    parse_migration_status_markers "$migration_raw"

    if [ -z "$pending_count" ] || [ -z "$applied_count" ]; then
      migration_raw=$(run_migration_status_eval "$release_bin" 2>/dev/null)
      parse_migration_status_markers "$migration_raw"
    fi

    if [[ "$total_count" =~ ^[0-9]+$ ]] && [ "$total_count" -gt 0 ]; then
      stable_total_count="$total_count"
    fi

    # If structured status is unavailable, fall back to SQL for completed-count
    # only. Do not guess the current migration from regex-scraped queue lines.
    if [ -z "$pending_count" ] || [ "$pending_count" = "error" ] || [ -z "$applied_count" ]; then
      applied_count=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
        "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null | tr -d ' ')
      last_migration=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
        "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;" 2>/dev/null | tr -d ' ')

      if [ -n "$stable_total_count" ]; then
        total_count="$stable_total_count"
      elif [ -n "$release_total_count" ]; then
        total_count="$release_total_count"
      fi

      if [[ "$applied_count" =~ ^[0-9]+$ ]] && [[ "$total_count" =~ ^[0-9]+$ ]] && [ "$total_count" -gt 0 ] && [ "$applied_count" -ge "$total_count" ]; then
        migrations_complete=true
        pending_count=0
        total_count="$applied_count"
      elif [[ "$applied_count" =~ ^[0-9]+$ ]] && [[ "$total_count" =~ ^[0-9]+$ ]] && [ "$total_count" -gt 0 ]; then
        pending_count=$((total_count - applied_count))
        if [ "$pending_count" -lt 0 ]; then
          pending_count=0
        fi
      else
        # Logs are diagnostic only. Status must come from structured artifacts
        # or deterministic schema_migrations counts so rolled-off log lines
        # cannot mark migrations complete or running incorrectly.
        pending_count="checking"
      fi
    fi

    # Calculate total if we have applied and pending
    if [ -z "$total_count" ] && [[ "$pending_count" =~ ^[0-9]+$ ]] && [[ "$applied_count" =~ ^[0-9]+$ ]]; then
      total_count=$((applied_count + pending_count))
    fi

    if [[ "$total_count" =~ ^[0-9]+$ ]]; then
      if [[ "$applied_count" =~ ^[0-9]+$ ]] && [ "$total_count" -lt "$applied_count" ]; then
        total_count="$applied_count"
      fi
      if [ "$total_count" -gt 0 ]; then
        stable_total_count="$total_count"
      fi
    elif [ -n "$stable_total_count" ]; then
      total_count="$stable_total_count"
    elif [ -n "$release_total_count" ]; then
      total_count="$release_total_count"
    fi

    local current_runtime_human=""
    local last_completed_runtime_human=""
    if [[ "$current_runtime_ms" =~ ^[0-9]+$ ]]; then
      current_runtime_human=$(format_runtime_ms "$current_runtime_ms")
    fi
    if [[ "$last_completed_runtime_ms" =~ ^[0-9]+$ ]]; then
      last_completed_runtime_human=$(format_runtime_ms "$last_completed_runtime_ms")
    fi

    if [ "$progress_state" = "failed" ]; then
      echo ""
      if [ -n "$progress_error" ]; then
        log_fail "Migrations failed (${applied_count:-?}/${total_count:-?} applied): $progress_error"
      else
        log_fail "Migrations failed (${applied_count:-?}/${total_count:-?} applied)"
      fi
      [ -n "$artifact_status_path" ] && echo "  Status artifact: $artifact_status_path"
      [ -n "$artifact_events_path" ] && echo "  Event artifact: $artifact_events_path"
      [ -n "$artifact_log_path" ] && echo "  Log artifact: $artifact_log_path"
      migrations_failed=true
      break
    fi

    # Display status
    if [[ "$pending_count" =~ ^[0-9]+$ ]]; then
      if [ "$pending_count" -eq 0 ]; then
        local total_unknown_or_zero=true
        if [[ "$total_count" =~ ^[0-9]+$ ]] && [ "$total_count" -gt 0 ]; then
          total_unknown_or_zero=false
        fi

        if ! [[ "$applied_count" =~ ^[0-9]+$ ]] || { [ "$applied_count" -eq 0 ] && [ "$total_unknown_or_zero" = true ]; }; then
          local display_total="${total_count:-?}"
          _wait_heartbeat "\r  Migrations: %s/%s applied, waiting for non-zero migration inventory...    " "${applied_count:-?}" "$display_total"
          sleep $poll_interval
          wait_time=$((wait_time + poll_interval))
          continue
        fi
        # When Ecto reports 0 pending, applied_count IS the total — don't
        # let the file-count (release_total_count) create a false X/Y mismatch.
        local display_total="$applied_count"
        cli_verbose && { cli_quiet || echo ""; }
        log_verbose_ok "Migrations complete ($applied_count/$display_total)"
        migrations_complete=true
        break
      else
        local elapsed_display
        elapsed_display=$(_wait_active_query_elapsed_display)
        if [ -n "$current_version$current_filename" ]; then
          _wait_heartbeat "\r  Migrations: %s/%s applied, %s pending — running: %s (%s)%s    " "$applied_count" "$total_count" "$pending_count" "${current_filename:-unknown}" "${current_runtime_human:-unknown}" "$elapsed_display"
        elif [ -n "$next_version$next_filename" ]; then
          _wait_heartbeat "\r  Migrations: %s/%s applied, %s pending — next: %s%s    " "$applied_count" "$total_count" "$pending_count" "${next_filename:-unknown}" "$elapsed_display"
        else
          _wait_heartbeat "\r  Migrations: %s/%s applied, %s pending%s...    " "$applied_count" "$total_count" "$pending_count" "$elapsed_display"
        fi
      fi
    elif [ "$pending_count" = "running" ]; then
      local display_total="${total_count:-?}"
      local display_name=""
      if [ -n "$current_version$current_filename" ]; then
        display_name=" — running: ${current_filename:-unknown} (${current_runtime_human:-unknown})"
      elif [ -n "$next_version$next_filename" ]; then
        display_name=" — next: ${next_filename:-unknown}"
      elif [ -n "$last_migration" ]; then
        if [ -n "$latest_applied_filename" ]; then
          display_name=" — latest applied: ${latest_applied_filename}"
        else
          display_name=" — latest applied: ${last_migration}"
        fi
      fi
      local elapsed_display
      elapsed_display=$(_wait_active_query_elapsed_display)
      _wait_heartbeat "\r  Migrations: %s/%s applied, running...%s%s    " "${applied_count:-?}" "$display_total" "$display_name" "$elapsed_display"
    else
      local display_total="${total_count:-?}"
      _wait_heartbeat "\r  Migrations: %s/%s applied, waiting for status...    " "${applied_count:-?}" "$display_total"
    fi

    local progress_signature="${progress_state}|${current_filename}|${current_runtime_ms}|${last_completed_filename}|${last_completed_runtime_ms}|${updated_at}"
    if cli_verbose && [ -n "$artifact_log_path" ] && [ "$progress_signature" != "$last_progress_signature" ]; then
      echo ""

      [ -n "$artifact_status_path" ] && echo "    Status Artifact: $artifact_status_path"
      [ -n "$artifact_events_path" ] && echo "    Event Artifact: $artifact_events_path"
      [ -n "$artifact_log_path" ] && echo "    Log Artifact: $artifact_log_path"

      if [ -n "$current_filename" ]; then
        echo "    Current: ${current_filename}"
        [ -n "$current_description" ] && echo "    Desc: ${current_description}"
        [ -n "$current_started_at" ] && echo "    Started: ${current_started_at}"
        [ -n "$current_runtime_human" ] && echo "    Runtime: ${current_runtime_human}"
      fi

      if [ -n "$last_completed_filename" ]; then
        echo "    Last Finished: ${last_completed_filename}"
        [ -n "$last_completed_description" ] && echo "    Last Desc: ${last_completed_description}"
        [ -n "$last_completed_completed_at" ] && echo "    Finished At: ${last_completed_completed_at}"
        [ -n "$last_completed_runtime_human" ] && echo "    Last Runtime: ${last_completed_runtime_human}"
      fi

      if [ -n "$next_filename" ]; then
        echo "    Next: ${next_filename}"
        [ -n "$next_description" ] && echo "    Next Desc: ${next_description}"
      fi

      local artifact_events_tail
      artifact_events_tail=$(tail_migration_artifact_events "$artifact_events_path" 2)
      if [ -n "$artifact_events_tail" ]; then
        echo "    Progress JSON Tail:"
        printf '%s\n' "$artifact_events_tail" | sed 's/^/      /'
      fi

      local artifact_log_tail
      artifact_log_tail=$(tail_migration_artifact_log "$artifact_log_path" 3)
      if [ -n "$artifact_log_tail" ]; then
        echo "    Progress Log Tail:"
        printf '%s\n' "$artifact_log_tail" | sed 's/^/      /'
      fi

      last_progress_signature="$progress_signature"
    fi

    sleep $poll_interval
    wait_time=$((wait_time + poll_interval))
  done

  if [ "$migrations_complete" != true ]; then
    cli_verbose && { cli_quiet || echo ""; }
    if [ "$migrations_failed" = true ]; then
      log_fail "Migrations failed"
    else
      log_fail "Migration status unclear after ${max_wait}s"
    fi
    echo "  Check logs: $DOCKER_COMPOSE_CMD logs -f web"
    [ -n "$artifact_status_path" ] && echo "  Status artifact: $artifact_status_path"
    [ -n "$artifact_events_path" ] && echo "  Event artifact: $artifact_events_path"
    [ -n "$artifact_log_path" ] && echo "  Log artifact: $artifact_log_path"
    echo ""
    return 1
  fi
  cli_verbose && echo ""
  return 0
}

_wait_phase4_health() {
  # Phase 4 health checks — 60s per service. Web boot on a cold BEAM with
  # pg_ivm refresh can legitimately take 30–45s even after migrations report
  # complete; the old 20s window was tight and false-positive on slower disks.
  local release_bin
  release_bin=$(get_release_binary)

  _wait_phase_banner "Phase 4: Health checks..."

  repair_compose_bridge_once || true
  local web_healthy=false
  local i
  for i in {1..30}; do
    if $DOCKER_COMPOSE_CMD exec -T web curl -sf http://127.0.0.1:4080/healthz >/dev/null 2>&1; then
      web_healthy=true
      break
    fi
    sleep 2
  done

  if [ "$web_healthy" = true ]; then
    log_verbose_ok "Web application healthy"
  else
    log_fail "Web health check failed after 60s"
    _wait_record_failure health-check
  fi

  local traceroute_healthy=false
  for i in {1..30}; do
    if $DOCKER_COMPOSE_CMD exec -T traceroute bash -lc 'exec 3<>/dev/tcp/127.0.0.1/4100' >/dev/null 2>&1; then
      traceroute_healthy=true
      break
    fi
    sleep 2
  done

  if [ "$traceroute_healthy" = true ]; then
    log_verbose_ok "Traceroute service healthy"
  else
    log_fail "Traceroute health check failed after 60s"
    _wait_record_failure traceroute-health
  fi

  # Check for startup issues in logs
  local scheduler_errors
  scheduler_errors=$($DOCKER_COMPOSE_CMD logs --tail 100 web 2>&1 | grep -c "not started: invalid task function" 2>/dev/null | tail -1 || echo "0")
  scheduler_errors=${scheduler_errors:-0}
  if [ "$scheduler_errors" -gt 0 ] 2>/dev/null; then
    log_warn "$scheduler_errors scheduler jobs failed (non-fatal)"
  fi

  # RPC check
  local rpc_ok
  rpc_ok=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts("ok")' 2>&1)
  if [[ "$rpc_ok" == *"ok"* ]]; then
    log_verbose_ok "Application RPC responding"
  else
    log_fail "Application RPC not responding"
    _wait_record_failure rpc
  fi
}

wait_for_services() {
  local max_wait=3600
  local suppress_success="${1:-0}"
  local suppress_phase_banners="${2:-0}"
  local suppress_heartbeats="${3:-0}"

  _wait_reset_state
  _WAIT_SUPPRESS_PHASE_BANNERS="$suppress_phase_banners"
  _WAIT_SUPPRESS_HEARTBEATS="$suppress_heartbeats"

  if ! _wait_resolve_expected_services; then
    return 1
  fi

  if cli_verbose; then
    echo ""
    echo "Starting services..."
    echo ""
  else
    log_info "Waiting for services to become ready..."
  fi

  _wait_phase1_containers "${_WAIT_EXPECTED_SERVICES[@]}" \
    || _wait_record_failure containers
  local phase2_ok=true
  _wait_phase2_database || { _wait_record_failure database; phase2_ok=false; }

  # Gate each downstream phase on the containers it actually talks to.
  # Phase 3 `docker exec`s into db + web for migration polling; Phase 4
  # hits web + traceroute for healthz. If those specific containers
  # aren't running, the phase just burns its timeout budget (Phase 3's
  # max_wait defaults to 3600s — an hour of CLI stall after a 120s
  # container-startup failure).
  #
  # Gate per-phase rather than on a broad core set so optional profile
  # services (grafana, loki, jtapi-sidecar, caddy, nats, …) being down
  # doesn't rob the operator of diagnostics that ARE still available.
  if _wait_required_containers_ok db web && [ "$phase2_ok" = true ]; then
    _wait_phase3_migrations "$max_wait" \
      || _wait_record_failure migrations
  else
    log_warn "Migration checks skipped (db or web container not running, or DB not accepting connections)."
    cli_verbose && echo ""
  fi

  if _wait_required_containers_ok web traceroute; then
    _wait_phase4_health
  else
    log_warn "Health checks skipped (web or traceroute container not running)."
    cli_verbose && echo ""
  fi

  if cli_verbose; then
    echo ""
    show_system_activity
    echo ""
  fi

  if [ "$_WAIT_PHASE_FAILURES" -eq 0 ]; then
    if [ "$suppress_success" != "1" ]; then
      log_ok "Startup complete!"
    fi
    return 0
  fi

  log_fail "Startup failed — $_WAIT_PHASE_FAILURES phase(s) had errors:$_WAIT_FAILED_PHASES"
  collect_upgrade_diagnostics \
    "startup phases failed:${_WAIT_FAILED_PHASES}" \
    "${_WAIT_FAILED_PHASES}"
  return 1
}

# Function to purge unused Docker resources.
# Stays silent on the (common) "nothing to reclaim" case and prints a
# single-line itemized summary only of categories that actually changed.
# The previous implementation emitted 8 "Removing X... done (0)" lines
# every upgrade — all noise after a clean upgrade where nothing accumulates.
# Also fixes a bug where old_removed was incremented inside a `while read`
# subshell and the count was always reported as 0.
purge_docker() {
  local containers_bytes networks_count volumes_bytes images_count dangling_bytes
  local results=()

  containers_bytes=$(docker container prune -f 2>/dev/null \
    | awk '/Total reclaimed space/ {print $4 $5}')
  containers_bytes="${containers_bytes:-0B}"
  [ "$containers_bytes" != "0B" ] && results+=("containers: ${containers_bytes}")

  # `docker network prune` lists deleted network names under a "Deleted Networks:"
  # header on success; nothing on no-op. Count rows past the header.
  networks_count=$(docker network prune -f 2>/dev/null \
    | awk '/^Deleted Networks:/{flag=1; next} flag && NF {c++} END {print c+0}')
  [ "${networks_count:-0}" -gt 0 ] && results+=("networks: ${networks_count}")

  volumes_bytes=$(docker volume prune -f 2>/dev/null \
    | awk '/Total reclaimed space/ {print $4 $5}')
  volumes_bytes="${volumes_bytes:-0B}"
  [ "$volumes_bytes" != "0B" ] && results+=("volumes: ${volumes_bytes}")

  # Remove old calltelemetry images not in the active docker-compose.yml.
  local active_images=""
  if [ -f "$ORIGINAL_FILE" ]; then
    active_images=$(extract_images "$ORIGINAL_FILE" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
  fi
  images_count=0
  if [ -n "$active_images" ]; then
    # Process substitution (not a pipe) so the increment lands in the parent shell.
    while read -r img; do
      if ! echo "$img" | grep -qE "$active_images"; then
        docker rmi "$img" >/dev/null 2>&1 && images_count=$((images_count + 1))
      fi
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep "calltelemetry/" || true)
  fi
  [ "$images_count" -gt 0 ] && results+=("old calltelemetry images: ${images_count}")

  dangling_bytes=$(docker image prune -f 2>/dev/null \
    | awk '/Total reclaimed space/ {print $4 $5}')
  dangling_bytes="${dangling_bytes:-0B}"
  [ "$dangling_bytes" != "0B" ] && results+=("dangling images: ${dangling_bytes}")

  if [ ${#results[@]} -eq 0 ]; then
    log_ok "Docker cleanup: nothing to reclaim"
  else
    # Join the per-category items into a single comma-separated summary so
    # the operator gets one tidy line instead of a list. Per-category detail
    # is available via CLI_VERBOSE=1.
    local summary="${results[0]}"
    local i
    for ((i=1; i<${#results[@]}; i++)); do
      summary="${summary}, ${results[$i]}"
    done
    log_ok "Docker cleanup reclaimed: ${summary}"
    local item
    for item in "${results[@]}"; do
      log_verbose "  ${item}"
    done
  fi
}

# Function to create a backup and retain only the last 5 backups
backup() {
  backup_folder_path=$BACKUP_FOLDER_PATH
  file_name="dump-"`date "+%Y-%m-%d-%H-%M-%S"`".sql"
  mkdir -p ${backup_folder_path}

  dbname=calltelemetry_prod
  username=calltelemetry

  backup_file=${backup_folder_path}/${file_name}

  $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db pg_dump -U ${username} -d ${dbname} > ${backup_file}

  echo "Dump successful: ${backup_file}"

  find ${backup_folder_path} -maxdepth 1 -name "*.sql" -type f | xargs ls -t | awk 'NR>5' | xargs -I {} rm -f {}

  echo "Old backups removed, keeping only the most recent 5."
}

# Function to restore the database from a backup file
restore() {
  if [ -z "$1" ]; then
    echo "Error: No backup file specified."
    echo "Usage: script_name.sh restore <backup-file>"
    return 1
  fi

  backup_file="$1"

  if [ ! -f "$backup_file" ]; then
    echo "Error: Backup file not found: $backup_file"
    return 1
  fi

  echo "Restoring database from backup: $backup_file"

  dbname=calltelemetry_prod
  username=calltelemetry
  container=$(docker ps --filter "name=db" --format "{{.Names}}" | head -n 1)

  if [ -z "$container" ]; then
    echo "Error: Database container not found."
    return 1
  fi

  docker exec -i ${container} psql -U ${username} -d ${dbname} < "$backup_file"

  echo "Database restored from $backup_file."
}

# Function to list available backups
list_backups() {
  echo "Available backups in $BACKUP_FOLDER_PATH:"
  echo ""
  if [ -d "$BACKUP_FOLDER_PATH" ] && [ "$(ls -A $BACKUP_FOLDER_PATH/*.sql 2>/dev/null)" ]; then
    ls -lh "$BACKUP_FOLDER_PATH"/*.sql 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
  else
    echo "  No backups found"
  fi
}

# ---------------------------------------------------------------------------
# redact_literal — replace EVERY literal occurrence of $1 in stdin with $2.
#
# Why awk and not bash parameter substitution? `${var//"$needle"/repl}` looks
# like a literal substitution, but the pattern half of bash's substitution
# operator is glob-expanded — even when the variable is double-quoted. A
# password containing `*`, `?`, `[`, etc. would either fail to match or
# over-match, leaving cleartext in the operator's terminal. awk's index()
# is unambiguously literal substring search; pairing it with substr() gives
# us a portable literal replace that does not care about regex/glob metachars.
#
# Empty needle returns stdin unchanged (rather than infinite-looping on the
# zero-width match) — guards against caller passing an unpopulated variable.
# ---------------------------------------------------------------------------
redact_literal() {
  local needle="$1" repl="$2"
  if [ -z "$needle" ]; then
    cat
    return 0
  fi
  awk -v needle="$needle" -v repl="$repl" '
    BEGIN { nlen = length(needle) }
    {
      out = ""
      rest = $0
      while ((p = index(rest, needle)) > 0) {
        out = out substr(rest, 1, p - 1) repl
        rest = substr(rest, p + nlen)
      }
      print out rest
    }
  '
}

# ---------------------------------------------------------------------------
# users_list — print every user (id, email, roles, last_login) as an ASCII
# table. Read-only.
#
# Captures RPC output and validates exit code + sentinel pair BEFORE piping
# through awk+column. cli.sh has no global `set -e` or `set -o pipefail`,
# so a naive `rpc … | awk | column` pipeline always exits 0 (column's rc)
# even when the RPC itself failed or never reached the sentinels — silently
# producing empty output that looks successful.
# ---------------------------------------------------------------------------
users_list() {
  local release_bin raw rpc_rc
  release_bin=$(get_release_binary)

  raw=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc '
import Ecto.Query
users =
  Cdrcisco.Identity.User
  |> order_by(asc: :id)
  |> Cdrcisco.Repo.all()

IO.puts("CT_USERS_BEGIN")
IO.puts("ID\tEMAIL\tROLE\tROLES\tLAST_LOGIN")
Enum.each(users, fn u ->
  roles = case u.roles do
    nil -> ""
    list when is_list(list) -> Enum.join(list, "|")
    other -> to_string(other)
  end
  last = if u.last_login, do: NaiveDateTime.to_string(u.last_login), else: "—"
  IO.puts(Enum.join([u.id, u.email, u.role || "", roles, last], "\t"))
end)
IO.puts("CT_USERS_END")
' 2>&1)
  rpc_rc=$?

  if [ "$rpc_rc" -ne 0 ]; then
    log_fail "Failed to list users: RPC exited with rc=$rpc_rc. Raw output:"
    printf '%s\n' "$raw" >&2
    return 1
  fi

  if ! printf '%s\n' "$raw" | grep -qx 'CT_USERS_BEGIN' \
     || ! printf '%s\n' "$raw" | grep -qx 'CT_USERS_END'; then
    log_fail "Failed to list users: RPC succeeded but sentinel pair (CT_USERS_BEGIN/END) was missing. Raw output:"
    printf '%s\n' "$raw" >&2
    return 1
  fi

  printf '%s\n' "$raw" | awk '
    /^CT_USERS_BEGIN$/ { capture=1; next }
    /^CT_USERS_END$/   { exit }
    capture == 1       { print }
  ' | column -t -s $'\t'
}

# ---------------------------------------------------------------------------
# reset_password_cmd — admin-override password reset by email.
#
# Calls Cdrcisco.Identity.reset_user_password, the same code path the admin UI
# uses, so identity.user.password_updated telemetry fires normally.
#
# Credential transport: base64-inlined into the rpc snippet, decoded inside
# the BEAM via Base.decode64!. Why not env vars + `docker compose exec -e`?
# Because `bin/onprem rpc` connects via Erlang distribution to the
# already-running release node, and evaluates the snippet IN THAT node's
# environment — which was set at container startup, not per-exec. So env
# vars set via `-e` or via a stdin/sh-c wrapper around the rpc CLIENT never
# reach the BEAM that actually runs the code; the elixir would see nil.
#
# Why base64? It avoids Elixir-string-escape footguns (no quote/backslash/
# interpolation issues with arbitrary password contents) and keeps the shell
# substitution into the snippet a single alphanumeric token. The downside:
# the base64-encoded password DOES appear in the host's docker exec argv
# for the duration of the call — `ps`-visible to root. On a single-tenant
# appliance where this is a break-glass tool invoked by root (the operator
# already typed it on a command line / pasted it through curl|bash, so it's
# already in shell history), that's an acceptable trade-off. Switching to
# a temp-file/cp-in handoff would close that window but adds complexity not
# justified by this threat model.
# ---------------------------------------------------------------------------
reset_password_cmd() {
  # Strict arg count. `reset-password user@x.com new pass` would otherwise
  # silently set the password to "new" and ignore "pass" — terrible UX for
  # a credential command. Require exactly 2 args, fail loud on anything else.
  if [ "$#" -ne 2 ]; then
    log_fail "Usage: cli.sh reset-password <email> <new-password>"
    return 64  # EX_USAGE
  fi

  local email="$1"
  local password="$2"

  if [ -z "$email" ] || [ -z "$password" ]; then
    log_fail "Usage: cli.sh reset-password <email> <new-password>"
    return 64
  fi

  if [ ${#password} -lt 4 ]; then
    log_fail "Password must be at least 4 characters (matches Pow schema config)."
    return 64
  fi

  # Reject newline / carriage return so the operator gets a clear error
  # instead of a silently-truncated password reaching the database. A
  # newline in a CLI password is almost certainly an accident (paste
  # error, etc.), not an intentional choice.
  case "$password" in
    *$'\n'*|*$'\r'*)
      log_fail "Password must not contain newline or carriage return."
      return 64 ;;
  esac

  local release_bin email_b64 password_b64
  release_bin=$(get_release_binary)
  email_b64=$(printf '%s' "$email"    | base64 | tr -d '\n')
  password_b64=$(printf '%s' "$password" | base64 | tr -d '\n')

  local snippet
  snippet=$(cat <<ELIXIR
email = Base.decode64!("$email_b64")
password = Base.decode64!("$password_b64")

case Cdrcisco.Identity.reset_user_password(email, password) do
  {:ok, user} ->
    IO.puts("CT_RESET_OK:" <> user.email)

  {:error, %Ecto.Changeset{} = cs} ->
    errors =
      cs.errors
      |> Enum.map(fn {field, {msg, opts}} ->
        msg =
          Regex.replace(~r"%{(\w+)}", msg, fn _, k ->
            opts |> Keyword.get(String.to_existing_atom(k), "") |> to_string()
          end)
        "#{field}: #{msg}"
      end)
      |> Enum.join("; ")
    IO.puts("CT_RESET_ERR:" <> errors)

  {:error, :not_found} ->
    IO.puts("CT_RESET_ERR:no user with that email")

  _other ->
    # Deliberately generic — a stray changeset/struct in the fallback
    # could carry the password back to the operator terminal otherwise.
    # The detailed term stays inside the BEAM's logs only.
    IO.puts("CT_RESET_ERR:unexpected error from reset (see web container logs)")
end
ELIXIR
)

  local raw rpc_rc line
  raw=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc "$snippet" 2>&1)
  rpc_rc=$?

  # Redact the password (and its base64 form) from any captured output
  # BEFORE we expose it to the operator's terminal. If the BEAM
  # crash-logged the function args, the cleartext could otherwise echo
  # back through `$raw`. Use redact_literal (awk index-based) instead
  # of bash parameter substitution because the latter glob-expands its
  # match pattern even when quoted, so a password containing `*`/`?`/`[`
  # would fail to redact.
  local safe_raw
  safe_raw=$(printf '%s' "$raw" | redact_literal "$password_b64" "[redacted-b64]" | redact_literal "$password" "[redacted-pw]")

  if [ "$rpc_rc" -ne 0 ]; then
    log_fail "RPC failed (rc=$rpc_rc). Raw output (creds redacted):"
    printf '%s\n' "$safe_raw" >&2
    return 1
  fi

  line=$(printf '%s\n' "$raw" | grep -E '^CT_RESET_(OK|ERR):' | tail -1 || true)

  if [ -z "$line" ]; then
    log_fail "RPC produced no tagged result. Raw output (creds redacted):"
    printf '%s\n' "$safe_raw" >&2
    return 1
  fi

  if [[ "$line" == CT_RESET_OK:* ]]; then
    log_ok "Password reset for ${line#CT_RESET_OK:}"
    return 0
  else
    log_fail "${line#CT_RESET_ERR:}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# bootstrap_admin_cmd — idempotent first-admin provisioning.
#
# Use case: a freshly-deployed appliance boots with an empty database; the
# certification pipeline (and any unattended bring-up) needs a known admin
# to log in as. This command produces a deterministic, repeatable end state:
#
#   1. If a user with the given email already exists → reset its password
#      to the supplied value. This guarantees the cert lane can always log
#      in, even if a previous run left a user with a different password.
#   2. Else if no orgs exist yet (first_time_setup?) → create the org + user
#      in one transaction via Identity.create_user_with_org/1. Mirrors the
#      web UI's first-run wizard, including admin-role assignment and the
#      CDR-integration / purge-config / storage-pool side effects.
#   3. Else (orgs exist but this user does not) → create the user and
#      attach to the oldest org via Identity.create_admin_and_join_org/2.
#
# Same credential-transport rationale as reset_password_cmd: base64-inline
# into the rpc snippet because `bin/onprem rpc` evaluates inside the
# long-running release node, which does not see per-exec env vars set on
# the rpc CLIENT. See reset_password_cmd's comment block for the full
# write-up; the same threat model applies here (single-tenant root-only
# appliance, break-glass tool).
# ---------------------------------------------------------------------------
bootstrap_admin_cmd() {
  # Every error branch emits a CT_BOOTSTRAP_ERR:<reason> tag on stdout
  # before the human log line, so automated callers (cert lane, future
  # provisioners) see the same single-line tagged contract on success
  # AND failure. Human log lines stay on stderr.
  if [ "$#" -ne 2 ]; then
    printf '%s\n' "CT_BOOTSTRAP_ERR:usage"
    log_fail "Usage: cli.sh bootstrap-admin <email> <password>" >&2
    return 64  # EX_USAGE
  fi

  local email="$1"
  local password="$2"

  if [ -z "$email" ] || [ -z "$password" ]; then
    printf '%s\n' "CT_BOOTSTRAP_ERR:usage"
    log_fail "Usage: cli.sh bootstrap-admin <email> <password>" >&2
    return 64
  fi

  # Cheap shape check — reject obvious garbage before we round-trip through
  # the BEAM. Internal/test domains like 'admin@host' are valid; only
  # require an @ with non-empty parts on each side. Full email validation
  # lives in the Pow changeset.
  case "$email" in
    ?*@?*) : ;;
    *)
      printf '%s\n' "CT_BOOTSTRAP_ERR:invalid_email"
      log_fail "Email must be of the form local@domain (got: $email)." >&2
      return 64 ;;
  esac

  if [ ${#password} -lt 4 ]; then
    printf '%s\n' "CT_BOOTSTRAP_ERR:password_too_short"
    log_fail "Password must be at least 4 characters (matches Pow schema config)." >&2
    return 64
  fi

  case "$password" in
    *$'\n'*|*$'\r'*)
      printf '%s\n' "CT_BOOTSTRAP_ERR:invalid_password"
      log_fail "Password must not contain newline or carriage return." >&2
      return 64 ;;
  esac

  local release_bin email_b64 password_b64
  release_bin=$(get_release_binary)
  email_b64=$(printf '%s' "$email"    | base64 | tr -d '\n')
  password_b64=$(printf '%s' "$password" | base64 | tr -d '\n')

  local snippet
  snippet=$(cat <<ELIXIR
email = Base.decode64!("$email_b64")
password = Base.decode64!("$password_b64")

emit_changeset_error = fn cs ->
  errors =
    cs.errors
    |> Enum.map(fn {field, {msg, opts}} ->
      msg =
        Regex.replace(~r"%{(\w+)}", msg, fn _, k ->
          opts |> Keyword.get(String.to_existing_atom(k), "") |> to_string()
        end)
      "#{field}: #{msg}"
    end)
    |> Enum.join("; ")
  IO.puts("CT_BOOTSTRAP_ERR:" <> errors)
end

# Reusable: ensure user has full_admin role AND is attached to an org.
# Both ops are idempotent on the underlying Identity API:
#   - add_role only fires Repo.update if the role is missing.
#   - changeset_org dedups membership in its many-to-many shape.
ensure_admin_and_org = fn user ->
  user_with_orgs = Cdrcisco.Repo.preload(user, :orgs)

  with {:ok, user_after_org} <-
         (case Cdrcisco.Identity.get_first_org(user_with_orgs) do
            nil ->
              case Cdrcisco.Identity.get_oldest_org() do
                %Cdrcisco.Identity.Org{} = org ->
                  user_with_orgs
                  |> Cdrcisco.Identity.User.changeset_org(org)
                  |> Cdrcisco.Repo.update()
                nil ->
                  {:error, :no_orgs_to_attach}
              end
            %Cdrcisco.Identity.Org{} ->
              {:ok, user_with_orgs}
          end),
       {:ok, final_user} <-
         (if "full_admin" in (user_after_org.roles || []) do
            {:ok, user_after_org}
          else
            Cdrcisco.Identity.add_role(user_after_org, "full_admin")
          end) do
    {:ok, final_user}
  end
end

case Cdrcisco.Identity.get_user_by_email_ci(email) do
  %Cdrcisco.Identity.User{} = user ->
    # Wrap reset + org attach + role grant in a single transaction so a
    # late failure (role grant blew up after password update) does not
    # leave a partially-mutated user. Important for an unattended
    # bootstrap: the caller's contract is "either I can log in as this
    # email/password AND it's a full_admin attached to an org, or the
    # command failed and nothing changed."
    Cdrcisco.Repo.transaction(fn ->
      with {:ok, _u} <- Cdrcisco.Identity.reset_user_password(user, password),
           # Re-fetch so we see the post-reset state (roles/orgs may have
           # been mutated by intervening admin work).
           %Cdrcisco.Identity.User{} = fresh <- Cdrcisco.Identity.get_user_by_email_ci(email),
           {:ok, final} <- ensure_admin_and_org.(fresh) do
        final
      else
        {:error, %Ecto.Changeset{} = cs} ->
          Cdrcisco.Repo.rollback({:changeset, cs})
        {:error, :no_orgs_to_attach} ->
          Cdrcisco.Repo.rollback(:no_orgs)
        other ->
          Cdrcisco.Repo.rollback({:unexpected, other})
      end
    end)
    |> case do
      {:ok, final} ->
        IO.puts("CT_BOOTSTRAP_OK:reset:" <> final.email)
      {:error, {:changeset, cs}} ->
        emit_changeset_error.(cs)
      {:error, :no_orgs} ->
        IO.puts("CT_BOOTSTRAP_ERR:existing user has no org and no orgs exist to attach to (inconsistent DB)")
      {:error, {:unexpected, _}} ->
        IO.puts("CT_BOOTSTRAP_ERR:unexpected error promoting existing user (see web container logs)")
    end

  nil ->
    user_params = %{
      "email" => email,
      "password" => password,
      "password_confirmation" => password
    }

    if Cdrcisco.Identity.first_time_setup?() do
      case Cdrcisco.Identity.create_user_with_org(user_params) do
        {:ok, u} ->
          IO.puts("CT_BOOTSTRAP_OK:created_with_org:" <> u.email)
        {:error, %Ecto.Changeset{} = cs} ->
          emit_changeset_error.(cs)
        _other ->
          IO.puts("CT_BOOTSTRAP_ERR:unexpected error creating user+org (see web container logs)")
      end
    else
      case Cdrcisco.Identity.get_oldest_org() do
        %Cdrcisco.Identity.Org{id: org_id} ->
          case Cdrcisco.Identity.create_admin_and_join_org(user_params, org_id) do
            {:ok, u} ->
              IO.puts("CT_BOOTSTRAP_OK:joined_org:" <> u.email)
            {:error, %Ecto.Changeset{} = cs} ->
              emit_changeset_error.(cs)
            _other ->
              IO.puts("CT_BOOTSTRAP_ERR:unexpected error joining oldest org (see web container logs)")
          end
        nil ->
          IO.puts("CT_BOOTSTRAP_ERR:no orgs found and first_time_setup? returned false (inconsistent DB)")
      end
    end
end
ELIXIR
)

  local raw rpc_rc line
  raw=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc "$snippet" 2>&1)
  rpc_rc=$?

  # See redact_literal docstring — bash parameter substitution would
  # glob-expand the pattern even when quoted, so use the awk-based
  # literal redactor.
  local safe_raw
  safe_raw=$(printf '%s' "$raw" | redact_literal "$password_b64" "[redacted-b64]" | redact_literal "$password" "[redacted-pw]")

  if [ "$rpc_rc" -ne 0 ]; then
    printf '%s\n' "CT_BOOTSTRAP_ERR:rpc_failed"
    log_fail "RPC failed (rc=$rpc_rc). Raw output (creds redacted):" >&2
    printf '%s\n' "$safe_raw" >&2
    return 1
  fi

  line=$(printf '%s\n' "$raw" | grep -E '^CT_BOOTSTRAP_(OK|ERR):' | tail -1 || true)

  if [ -z "$line" ]; then
    printf '%s\n' "CT_BOOTSTRAP_ERR:missing_tagged_result"
    log_fail "RPC produced no tagged result. Raw output (creds redacted):" >&2
    printf '%s\n' "$safe_raw" >&2
    return 1
  fi

  # Preserve the machine-readable CT_BOOTSTRAP_* token on stdout for
  # callers that parse the result (cert lane, future automation).
  # Human-friendly log lines go to stderr so stdout stays a clean
  # single-line tagged payload.
  printf '%s\n' "$line"

  if [[ "$line" == CT_BOOTSTRAP_OK:* ]]; then
    # OK payload format: CT_BOOTSTRAP_OK:<mode>:<email>
    #   mode ∈ { reset, created_with_org, joined_org }
    local payload mode bemail
    payload=${line#CT_BOOTSTRAP_OK:}
    mode=${payload%%:*}
    bemail=${payload#*:}
    case "$mode" in
      reset)            log_ok "User existed; password reset for ${bemail}" >&2 ;;
      created_with_org) log_ok "First-time setup: created org + admin ${bemail}" >&2 ;;
      joined_org)       log_ok "Created admin ${bemail} attached to oldest org" >&2 ;;
      *)                log_ok "Bootstrap succeeded: ${payload}" >&2 ;;
    esac
    return 0
  else
    log_fail "${line#CT_BOOTSTRAP_ERR:}" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# seed_cmd — generate demo seed data and stream live progress
# ---------------------------------------------------------------------------
seed_cmd() {
  local subcommand="${1:-help}"
  shift || true

  local release_bin
  release_bin=$(get_release_binary)

  case "$subcommand" in
    run)
      local org_id=1
      local preset="comprehensive_demo"
      local curri_count=0
      local days=90

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --org)      org_id="$2";     shift 2 ;;
          --preset)   preset="$2";     shift 2 ;;
          --curri)    curri_count="$2"; shift 2 ;;
          --days)     days="$2";       shift 2 ;;
          *) echo "Unknown option: $1"; shift ;;
        esac
      done

      echo ""
      echo "╔══════════════════════════════════════════════════════╗"
      echo "║         CallTelemetry Demo Seed Generator            ║"
      echo "╚══════════════════════════════════════════════════════╝"
      echo ""
      echo "  Org:    $org_id"
      echo "  Preset: $preset"
      if [ "$curri_count" -gt 0 ] 2>/dev/null; then
        echo "  Curri:  $curri_count events (mega loader)"
      fi
      echo "  Days:   $days day spread"
      echo ""

      # Ensure org exists — bootstrap if needed
      echo "▶ Checking org $org_id..."
      local org_exists
      org_exists=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc \
        "IO.puts(if Cdrcisco.Repo.get(Cdrcisco.Identity.Org, ${org_id}), do: \"exists\", else: \"missing\")" 2>&1 | tail -1)

      if [ "$org_exists" != "exists" ]; then
        echo "  Org $org_id not found — bootstrapping demo org..."
        $DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc "
{:ok, user} = Cdrcisco.Identity.create_user_with_org(
  %{\"email\" => \"demo@calltelemetry.com\", \"password\" => \"demo\",
    \"password_confirmation\" => \"demo\", \"terms_accepted\" => true},
  %{name: \"CallTelemetry Demo\", check_new_version_on_login: true}
)
org = Cdrcisco.Identity.get_first_org(user)
{:ok, token, _} = Cdrcisco.Token.trial(\"demo@calltelemetry.com\", \"Demo\", 30)
{:ok, org} = Cdrcisco.Identity.update_org(org, %{license_token: token})
Cdrcisco.License.update_license(org)
IO.puts(\"created org \" <> to_string(org.id))
" 2>&1 | grep -v "^\s*$"
      else
        echo "  ✓ Org $org_id exists"
      fi
      echo ""

      # Enqueue preset via Oban (persistent — survives container restart)
      echo "▶ Enqueueing $preset seed job via Oban..."
      local job_id
      job_id=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc "
{:ok, job} = Cdrcisco.Seeds.DemoSeedWorker.new(%{
  \"action\" => \"preset\",
  \"org_id\" => ${org_id},
  \"preset_name\" => \"${preset}\",
  \"overrides\" => %{\"curri_call_events\" => %{\"count\" => ${days} * 10000, \"days\" => ${days}}}
}) |> Oban.insert()
IO.puts(to_string(job.id))
" 2>&1 | tail -1)

      echo "  ✓ Oban job enqueued (id=$job_id)"

      # Also kick off mega curri loader if requested
      if [ "$curri_count" -gt 0 ] 2>/dev/null; then
        echo "▶ Launching CurriMegaLoader ($curri_count events)..."
        $DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc "
Task.start(fn ->
  Cdrcisco.Seeds.CurriMegaLoader.load(${org_id}, %{
    count: ${curri_count}, days: ${days}, chunk_size: 100_000
  })
end)
IO.puts(\"mega loader started\")
" 2>&1 | grep -v "^\s*$"
      fi

      echo ""
      echo "▶ Streaming progress (Ctrl+C to stop monitoring, seeds continue in background)..."
      echo "──────────────────────────────────────────────────────────"
      seed_monitor "$org_id" "$job_id"
      ;;

    monitor)
      local org_id="${1:-1}"
      local job_id="${2:-}"
      seed_monitor "$org_id" "$job_id"
      ;;

    status)
      local org_id="${1:-1}"
      echo ""
      echo "=== Seed Status (org $org_id) ==="
      $DOCKER_COMPOSE_CMD exec -T db psql -U calltelemetry -d calltelemetry_prod -c "
SELECT
  (SELECT COUNT(*) FROM curri_events) AS curri_events,
  (SELECT COUNT(*) FROM reputation_signals) AS reputation_signals,
  (SELECT SUM(reltuples::bigint) FROM pg_class
   WHERE relname LIKE 'cdrcalls_%' AND relkind = 'r'
   AND relnamespace = 'public'::regnamespace) AS cdrcalls,
  (SELECT SUM(reltuples::bigint) FROM pg_class
   WHERE relname LIKE 'cmr_records_%' AND relkind = 'r'
   AND relnamespace = 'public'::regnamespace) AS cmr_records,
  (SELECT COUNT(*) FROM oban_jobs
   WHERE state IN ('available','executing','scheduled')
   AND worker LIKE '%Seed%') AS active_seed_jobs,
  (SELECT COUNT(*) FROM policies) AS policies,
  (SELECT COUNT(*) FROM watch_lists) AS watch_lists;
" 2>&1
      ;;

    cancel)
      echo "▶ Cancelling all active seed jobs..."
      $DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc "
import Ecto.Query
{:ok, n} = Oban.cancel_all_jobs(from j in Oban.Job,
  where: j.worker == \"Cdrcisco.Seeds.DemoSeedWorker\"
  and j.state in [\"available\",\"scheduled\",\"executing\"])
IO.puts(\"Cancelled \" <> to_string(n) <> \" jobs\")
" 2>&1 | tail -3
      ;;

    help|*)
      echo ""
      echo "Usage: cli.sh seed <subcommand> [options]"
      echo ""
      echo "Subcommands:"
      echo "  run      Generate demo seeds (enqueues Oban job + streams progress)"
      echo "  monitor  Re-attach to progress stream for an org"
      echo "  status   Quick DB row counts for all seed tables"
      echo "  cancel   Cancel all queued seed jobs"
      echo ""
      echo "Options for 'run':"
      echo "  --org <id>        Org ID (default: 1)"
      echo "  --preset <name>   Preset name (default: comprehensive_demo)"
      echo "  --curri <count>   Also run CurriMegaLoader with this many events"
      echo "  --days <n>        Day spread for data (default: 90)"
      echo ""
      echo "Examples:"
      echo "  cli.sh seed run"
      echo "  cli.sh seed run --curri 10000000"
      echo "  cli.sh seed run --preset comprehensive_demo --curri 1000000 --days 90"
      echo "  cli.sh seed status"
      echo "  cli.sh seed monitor 1"
      echo ""
      ;;
  esac
}

# Live seed progress monitor — tails logs filtered to seed output + polls DB counts
seed_monitor() {
  local org_id="${1:-1}"
  local job_id="${2:-}"
  local poll_interval=10

  echo ""
  echo "  Monitoring org=$org_id  (refreshes every ${poll_interval}s)"
  echo "  Logs: docker logs calltelemetry-web-1 | grep seed activity"
  echo ""

  # Background log tail filtered to seed-relevant lines
  $DOCKER_COMPOSE_CMD logs -f web 2>&1 | grep -v "CurriController\|Keepalive\|Renewal token\|session_controller" \
    | grep --line-buffered -E "DemoEngine|DemoSeedWorker|CurriMegaLoader|DemoStreamer|chunk=|Seed|seed|DONE|preset|ERROR|error" &
  local log_pid=$!

  # Foreground periodic DB count table
  while true; do
    sleep "$poll_interval"
    local counts
    counts=$($DOCKER_COMPOSE_CMD exec -T db psql -U calltelemetry -d calltelemetry_prod -t -A -c "
SELECT
  'curri=' || (SELECT COUNT(*) FROM curri_events) ||
  '  rep=' || (SELECT COUNT(*) FROM reputation_signals) ||
  '  cdr=' || COALESCE((SELECT SUM(reltuples::bigint) FROM pg_class
    WHERE relname LIKE 'cdrcalls_%' AND relkind = 'r'
    AND relnamespace = 'public'::regnamespace)::text, '?') ||
  '  jobs=' || (SELECT COUNT(*) FROM oban_jobs
    WHERE state IN ('available','executing','scheduled')
    AND worker LIKE '%Seed%');
" 2>/dev/null | tr -d ' ')

    local oban_state=""
    if [ -n "$job_id" ]; then
      oban_state=$($DOCKER_COMPOSE_CMD exec -T db psql -U calltelemetry -d calltelemetry_prod -t -A -c \
        "SELECT state FROM oban_jobs WHERE id = ${job_id};" 2>/dev/null | tr -d ' ')
      oban_state=" job=$job_id:$oban_state"
    fi

    echo "  [$(date +%H:%M:%S)]  $counts$oban_state"

    # Stop polling when job completes
    if [ -n "$job_id" ] && [ "$oban_state" = " job=$job_id:completed" ]; then
      echo ""
      log_ok "Seed job $job_id completed!"
      break
    fi
    if [ -n "$job_id" ] && [ "$oban_state" = " job=$job_id:discarded" ]; then
      echo ""
      log_fail "Seed job $job_id failed (discarded). Check logs above."
      break
    fi
  done

  kill "$log_pid" 2>/dev/null || true
  echo ""
  echo "Final counts:"
  seed_cmd status "$org_id"
}

# Consolidated database command
db_cmd() {
  local action="$1"
  shift

  case "$action" in
    backup)
      backup
      ;;
    restore)
      if [ -z "$1" ]; then
        echo "Error: No backup file specified."
        echo ""
        list_backups
        echo ""
        echo "Usage: cli.sh db restore <backup-file>"
        return 1
      fi
      restore "$1"
      ;;
    list)
      list_backups
      ;;
    compact)
      compact_system
      ;;
    tables)
      sql_table_size "$1"
      ;;
    purge)
      if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Error: Missing required parameters"
        echo "Usage: cli.sh db purge <table> <days>"
        echo ""
        echo "Example: cli.sh db purge cube_event_logs 30"
        return 1
      fi
      sql_purge_table "$1" "$2"
      ;;
    size)
      echo "=== Database Size ==="
      $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c \
        "SELECT pg_size_pretty(pg_database_size('calltelemetry_prod')) AS database_size;"
      ;;
    ""|status)
      echo "=== Database Status ==="
      if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
        log_ok "Database: accepting connections"
      else
        log_fail "Database: not accepting connections"
        return 1
      fi
      echo ""
      echo "=== Database Size ==="
      $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c \
        "SELECT pg_size_pretty(pg_database_size('calltelemetry_prod')) AS database_size;"
      echo ""
      list_backups
      echo ""
      echo "Commands: cli.sh db <backup|restore|list|compact|tables|purge|size>"
      ;;
    *)
      echo "Unknown db command: $action"
      echo ""
      echo "Usage: cli.sh db <command>"
      echo ""
      echo "Commands:"
      echo "  status          Show database status (default)"
      echo "  backup          Create a database backup"
      echo "  restore <file>  Restore from a backup file"
      echo "  list            List available backups"
      echo "  compact         Vacuum and compact the database"
      echo "  tables [name]   Show table sizes (optionally filter by name)"
      echo "  purge <t> <d>   Purge records older than <d> days from table <t>"
      echo "  size            Show database size"
      return 1
      ;;
  esac
}

# Function to get the release binary path
get_release_binary() {
  echo "/home/app/onprem/bin/onprem"
}

normalize_container_log_lines() {
  sed -n 's/^.*"message":"\([^"]*\)".*$/\1/p; t; p'
}

marker_value() {
  local key="$1"
  awk -v prefix="::$key=" 'index($0, prefix) == 1 {print substr($0, length(prefix) + 1); exit}'
}

parse_migration_status_markers() {
  local migration_status_raw="$1"

  progress_state=$(printf '%s\n' "$migration_status_raw" | marker_value "state")
  pending_count=$(printf '%s\n' "$migration_status_raw" | marker_value "pending_count")
  applied_count=$(printf '%s\n' "$migration_status_raw" | marker_value "applied_count")
  total_count=$(printf '%s\n' "$migration_status_raw" | marker_value "total_count")
  current_version=$(printf '%s\n' "$migration_status_raw" | marker_value "current_version")
  current_name=$(printf '%s\n' "$migration_status_raw" | marker_value "current_name")
  current_filename=$(printf '%s\n' "$migration_status_raw" | marker_value "current_filename")
  current_description=$(printf '%s\n' "$migration_status_raw" | marker_value "current_description")
  current_started_at=$(printf '%s\n' "$migration_status_raw" | marker_value "current_started_at")
  current_runtime_ms=$(printf '%s\n' "$migration_status_raw" | marker_value "current_runtime_ms")
  next_version=$(printf '%s\n' "$migration_status_raw" | marker_value "next_version")
  next_name=$(printf '%s\n' "$migration_status_raw" | marker_value "next_name")
  next_filename=$(printf '%s\n' "$migration_status_raw" | marker_value "next_filename")
  next_description=$(printf '%s\n' "$migration_status_raw" | marker_value "next_description")
  latest_applied_name=$(printf '%s\n' "$migration_status_raw" | marker_value "latest_applied_name")
  latest_applied_filename=$(printf '%s\n' "$migration_status_raw" | marker_value "latest_applied_filename")
  latest_applied_description=$(printf '%s\n' "$migration_status_raw" | marker_value "latest_applied_description")
  last_completed_version=$(printf '%s\n' "$migration_status_raw" | marker_value "last_completed_version")
  last_completed_name=$(printf '%s\n' "$migration_status_raw" | marker_value "last_completed_name")
  last_completed_filename=$(printf '%s\n' "$migration_status_raw" | marker_value "last_completed_filename")
  last_completed_description=$(printf '%s\n' "$migration_status_raw" | marker_value "last_completed_description")
  last_completed_completed_at=$(printf '%s\n' "$migration_status_raw" | marker_value "last_completed_completed_at")
  last_completed_runtime_ms=$(printf '%s\n' "$migration_status_raw" | marker_value "last_completed_runtime_ms")
  artifact_status_path=$(printf '%s\n' "$migration_status_raw" | marker_value "artifact_status_path")
  artifact_events_path=$(printf '%s\n' "$migration_status_raw" | marker_value "artifact_events_path")
  artifact_log_path=$(printf '%s\n' "$migration_status_raw" | marker_value "artifact_log_path")
  updated_at=$(printf '%s\n' "$migration_status_raw" | marker_value "updated_at")
  progress_error=$(printf '%s\n' "$migration_status_raw" | marker_value "error")
}

format_runtime_ms() {
  local runtime_ms="$1"

  if ! [[ "$runtime_ms" =~ ^[0-9]+$ ]]; then
    printf '%s' "unknown"
    return 0
  fi

  local total_seconds=$((runtime_ms / 1000))
  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))
  local milliseconds=$((runtime_ms % 1000))

  if [ "$hours" -gt 0 ]; then
    printf '%sh %sm %s.%03ds' "$hours" "$minutes" "$seconds" "$milliseconds"
  elif [ "$minutes" -gt 0 ]; then
    printf '%sm %s.%03ds' "$minutes" "$seconds" "$milliseconds"
  else
    printf '%s.%03ds' "$seconds" "$milliseconds"
  fi
}

tail_migration_artifact_log() {
  local artifact_log_path="$1"
  local tail_lines="${2:-4}"

  if [ -z "$artifact_log_path" ]; then
    return 0
  fi

  $DOCKER_COMPOSE_CMD exec -T web sh -lc '
    artifact_log_path="$1"
    tail_lines="$2"
    if [ -f "$artifact_log_path" ]; then
      tail -n "$tail_lines" "$artifact_log_path"
    fi
  ' -- "$artifact_log_path" "$tail_lines" 2>/dev/null
}

tail_migration_artifact_events() {
  local artifact_events_path="$1"
  local tail_lines="${2:-2}"

  if [ -z "$artifact_events_path" ]; then
    return 0
  fi

  $DOCKER_COMPOSE_CMD exec -T web sh -lc '
    artifact_events_path="$1"
    tail_lines="$2"
    if [ -f "$artifact_events_path" ]; then
      tail -n "$tail_lines" "$artifact_events_path"
    fi
  ' -- "$artifact_events_path" "$tail_lines" 2>/dev/null
}

get_release_migration_count() {
  local release_bin="${1:-$(get_release_binary)}"
  local release_root="${release_bin%/bin/*}"

  $DOCKER_COMPOSE_CMD exec -T web sh -lc "
    count=\$(find \"$release_root/lib\" -path '*/priv/repo/migrations/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_*.exs' -type f 2>/dev/null | wc -l)
    if [ \"\${count:-0}\" -eq 0 ]; then
      count=\$(find /app/lib -path '*/priv/repo/migrations/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_*.exs' -type f 2>/dev/null | wc -l)
    fi
    printf '%s' \"\$count\"
  " 2>/dev/null | tr -d '[:space:]'
}

print_sql_migration_snapshot() {
  local title="${1:-Database Migration Status}"

  echo "=== ${title} (SQL) ==="
  $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "SELECT COUNT(*) AS total_migrations FROM schema_migrations;" 2>/dev/null || \
      echo "Unable to fetch total migrations via SQL."
  echo ""
  $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "SELECT version, inserted_at FROM schema_migrations ORDER BY version DESC LIMIT 5;" 2>/dev/null || \
      echo "Unable to fetch recent migrations via SQL."
  echo "=============================="
  echo ""
}

show_system_activity() {
  local os_name=$(uname -s)
  local cpu_summary="CPU unavailable"
  local mem_summary="MEM unavailable"
  local disk_summary="DISK unavailable"

  if command -v top >/dev/null 2>&1; then
    if [ "$os_name" = "Darwin" ]; then
      cpu_summary=$(top -l 1 | awk '/CPU usage/ {gsub(",",""); gsub("%",""); printf("CPU usr:%s%% sys:%s%% idle:%s%%", $3, $5, $7)}')
      [ -z "$cpu_summary" ] && cpu_summary="CPU unavailable"
      mem_summary=$(top -l 1 | awk '/PhysMem/ {gsub(",",""); printf("MEM used:%s free:%s", $2, $6)}')
      [ -z "$mem_summary" ] && mem_summary="MEM unavailable"
    else
      cpu_summary=$(top -bn1 | awk -F'[ ,]+' '/Cpu\(s\)/ {gsub("%", "", $2); gsub("%", "", $4); gsub("%", "", $8); printf("CPU usr:%s%% sys:%s%% idle:%s%%", $2, $4, $8)}')
      [ -z "$cpu_summary" ] && cpu_summary="CPU unavailable"
      if command -v free >/dev/null 2>&1; then
        mem_summary=$(free -h | awk 'NR==2 {printf("MEM used:%s/%s", $3, $2)}')
      fi
      [ -z "$mem_summary" ] && mem_summary="MEM unavailable"
    fi
  fi

  disk_summary=$(df -h / 2>/dev/null | awk 'NR==2 {printf("DISK / %s/%s (%s used)", $3, $2, $5)}')
  [ -z "$disk_summary" ] && disk_summary="DISK unavailable"

  echo "📊 Appliance Stats | $cpu_summary | $mem_summary | $disk_summary"
}

probe_host_port() {
  local host_port="$1"
  local max_attempts="${2:-3}"

  PROBE_LAST_METHOD=""
  PROBE_LAST_ATTEMPTS=0

  local nc_cmd=""
  if command -v nc >/dev/null 2>&1; then
    nc_cmd=$(command -v nc)
  else
    for candidate in /usr/bin/nc /bin/nc /usr/local/bin/nc; do
      if [ -x "$candidate" ]; then
        nc_cmd="$candidate"
        break
      fi
    done
  fi

  local method
  if [ -n "$nc_cmd" ]; then
    method="nc"
  else
    method="bash-tcp"
  fi

  PROBE_LAST_METHOD="$method"

  local attempt
  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    case "$method" in
      nc)
        if "$nc_cmd" -z 127.0.0.1 "$host_port" >/dev/null 2>&1; then
          PROBE_LAST_ATTEMPTS=$attempt
          return 0
        fi
        ;;
      bash-tcp)
        if ( exec 3<>/dev/tcp/127.0.0.1/"$host_port" && exec 3>&- && exec 3<&- ) 2>/dev/null; then
          PROBE_LAST_ATTEMPTS=$attempt
          return 0
        fi
        ;;
    esac

    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep 1
    fi
  done

  PROBE_LAST_ATTEMPTS=$max_attempts
  return 1
}

check_service_ports() {
  local service="$1"
  shift
  local ports=($@)
  local container
  container=$($DOCKER_COMPOSE_CMD ps -q "$service" 2>/dev/null)
  if [ -z "$container" ]; then
    log_warn "$service ports: container not found"
    return 0
  fi

  local service_ok=true
  local port_proto
  for port_proto in "${ports[@]}"; do
    local port=${port_proto%/*}
    local mapping
    mapping=$(docker port "$container" "$port_proto" 2>/dev/null | head -n 1)
    if [ -n "$mapping" ]; then
      local host_port=${mapping##*:}
      local max_attempts=3
      if probe_host_port "$host_port" "$max_attempts"; then
        echo "    ✓ $service:$port (host port $host_port)"
      else
        local probe_method_desc
        case "$PROBE_LAST_METHOD" in
          nc) probe_method_desc="nc" ;;
          python3) probe_method_desc="python socket" ;;
          bash-tcp) probe_method_desc="/dev/tcp" ;;
          *) probe_method_desc="probe" ;;
        esac
        echo "    ✗ $service:$port unreachable on host port $host_port (after $max_attempts $probe_method_desc attempts)"
        service_ok=false
      fi
    else
      log_warn "$service:$port not published to host; skipping port probe"
    fi
  done

  $service_ok && return 0 || return 1
}

report_service_health() {
  local service="$1"
  shift
  local ports=($@)
  local container
  container=$($DOCKER_COMPOSE_CMD ps -q "$service" 2>/dev/null)
  if [ -z "$container" ]; then
    log_warn "$service: container not found"
    return 0
  fi

  local health
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null)

  case "$health" in
    healthy)
      echo "    ✓ $service healthcheck: healthy"
      return 0
      ;;
    starting)
      echo "    $service healthcheck: starting"
      return 1
      ;;
    unhealthy)
      log_warn "$service healthcheck: unhealthy"
      docker inspect --format '{{range .State.Health.Log}}{{println .Output}}{{end}}' "$container" 2>/dev/null | tail -n 3 | sed 's/^/      /'
      return 1
      ;;
    none)
      if [ ${#ports[@]} -gt 0 ]; then
        check_service_ports "$service" "${ports[@]}"
        return $?
      else
        echo "    ℹ️  $service: no Docker healthcheck reported; host probe skipped"
        return 0
      fi
      ;;
    *)
      log_warn "$service healthcheck: $health"
      return 1
      ;;
  esac
}

show_web_logs() {
  local logs=""
  if ! logs=$($DOCKER_COMPOSE_CMD logs --tail 200 web 2>&1); then
    echo "Unable to fetch web logs."
    return 1
  fi

  echo "=== Recent Web Logs (last 10 lines) ==="
  printf '%s\n' "$logs" | tail -n 10
  echo "=============================="

  # Check if migrations completed successfully
  if printf '%s\n' "$logs" | grep -q "All migrations completed successfully"; then
    log_ok "Migrations completed successfully (from logs)"
    echo ""
  fi

  local recent_errors
  # Filter out scheduler warnings which are non-fatal
  recent_errors=$(printf '%s\n' "$logs" | grep -iE "error|exception" 2>/dev/null | grep -v "metrics" | grep -v "invalid task function" | tail -n 5 || true)

  local pending_migrations
  pending_migrations=$(printf '%s\n' "$logs" | awk '/Pending migrations \(will run now\):/ {pending=1; next} pending && /^  - / {gsub(/^  - /, ""); print} pending && !/^  - / {pending=0}' || true)

  if [ -n "$pending_migrations" ]; then
    echo "Pending migrations detected from logs:"
    while IFS= read -r line; do
      [ -n "$line" ] && printf '  • %s\n' "$line"
    done <<< "$pending_migrations"
    echo "Some migrations can take 1–2 hours on large datasets. Watch CPU/memory (top) and this list for progress; many migrations emit no logs while they run."
    echo ""
  fi

  # Check for scheduler warnings (non-fatal but worth noting)
  local scheduler_warnings
  scheduler_warnings=$(printf '%s\n' "$logs" | grep "not started: invalid task function" | wc -l)
  if [ "$scheduler_warnings" -gt 0 ]; then
    log_warn "Note: $scheduler_warnings scheduler jobs have invalid task functions (non-fatal)"
    echo ""
  fi

  if [ -n "$recent_errors" ]; then
    echo "Detected recent error entries in web logs:"
    echo "$recent_errors"
    echo ""
    return 1
  else
    echo "No critical errors detected in the last 200 web log lines."
    echo ""
    return 0
  fi
}

run_migration_status_rpc() {
  local release_bin="$1"

  $DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts(Cdrcisco.Release.migration_progress_report())' 2>&1
}

run_migration_status_artifact() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  local status_json
  status_json=$($DOCKER_COMPOSE_CMD exec -T \
    -e CT_MIGRATION_PROGRESS_DIR="${CT_MIGRATION_PROGRESS_DIR:-}" \
    web sh -lc '
    artifact_dir="${CT_MIGRATION_PROGRESS_DIR:-/home/app/logs/migrations}"
    status_path="$artifact_dir/current_status.json"
    if [ -f "$status_path" ]; then
      cat "$status_path"
    fi
  ' 2>/dev/null)

  if [ -z "$status_json" ]; then
    return 1
  fi

  printf '%s\n' "$status_json" | python3 -c '
import json
import sys

raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(1)

data = json.loads(raw)

def emit(key, value):
    if value is None:
        return
    if isinstance(value, bool):
        value = "true" if value else "false"
    elif isinstance(value, float) and value.is_integer():
        value = int(value)
    elif isinstance(value, (dict, list)):
        value = json.dumps(value, separators=(",", ":"))
    else:
        value = str(value)
    value = value.replace("\r", " ").replace("\n", " ").strip()
    print(f"::{key}={value}")

def emit_migration(prefix, migration):
    if not isinstance(migration, dict):
        return
    for field in ("version", "name", "filename", "description", "started_at", "completed_at", "runtime_ms"):
        emit(f"{prefix}_{field}", migration.get(field))

emit("status", data.get("status"))
emit("state", data.get("state"))
emit("repository", data.get("repository"))
emit("applied_count", data.get("applied_count"))
emit("total_count", data.get("total_migrations"))
emit("pending_count", data.get("pending_count"))
emit("current_version", data.get("current_version") or (data.get("current_migration") or {}).get("version"))
emit("updated_at", data.get("updated_at"))
emit("error", data.get("error"))
emit("artifact_status_path", data.get("artifact_status_path"))
emit("artifact_events_path", data.get("artifact_events_path"))
emit("artifact_log_path", data.get("artifact_log_path"))
emit_migration("latest_applied", data.get("latest_applied"))
emit_migration("current", data.get("current_migration"))
emit_migration("last_completed", data.get("last_completed_migration"))
emit_migration("next", data.get("next_migration"))
' 2>/dev/null
}

run_migration_status_eval() {
  local release_bin="$1"

  $DOCKER_COMPOSE_CMD exec -T web "$release_bin" eval 'IO.puts(Cdrcisco.Release.migration_progress_report())' 2>&1
}

render_migration_progress_from_markers() {
  local raw_output="$1"
  local state=$(printf '%s\n' "$raw_output" | marker_value "state")
  local applied_count=$(printf '%s\n' "$raw_output" | marker_value "applied_count")
  local total_count=$(printf '%s\n' "$raw_output" | marker_value "total_count")
  local pending_count=$(printf '%s\n' "$raw_output" | marker_value "pending_count")
  local latest_applied_version=$(printf '%s\n' "$raw_output" | marker_value "latest_applied_version")
  local latest_applied_filename=$(printf '%s\n' "$raw_output" | marker_value "latest_applied_filename")
  local current_version=$(printf '%s\n' "$raw_output" | marker_value "current_version")
  local current_filename=$(printf '%s\n' "$raw_output" | marker_value "current_filename")
  local current_description=$(printf '%s\n' "$raw_output" | marker_value "current_description")
  local current_started_at=$(printf '%s\n' "$raw_output" | marker_value "current_started_at")
  local current_runtime_ms=$(printf '%s\n' "$raw_output" | marker_value "current_runtime_ms")
  local last_completed_version=$(printf '%s\n' "$raw_output" | marker_value "last_completed_version")
  local last_completed_filename=$(printf '%s\n' "$raw_output" | marker_value "last_completed_filename")
  local last_completed_description=$(printf '%s\n' "$raw_output" | marker_value "last_completed_description")
  local last_completed_completed_at=$(printf '%s\n' "$raw_output" | marker_value "last_completed_completed_at")
  local last_completed_runtime_ms=$(printf '%s\n' "$raw_output" | marker_value "last_completed_runtime_ms")
  local next_version=$(printf '%s\n' "$raw_output" | marker_value "next_version")
  local next_filename=$(printf '%s\n' "$raw_output" | marker_value "next_filename")
  local next_description=$(printf '%s\n' "$raw_output" | marker_value "next_description")
  local artifact_status_path=$(printf '%s\n' "$raw_output" | marker_value "artifact_status_path")
  local artifact_events_path=$(printf '%s\n' "$raw_output" | marker_value "artifact_events_path")
  local artifact_log_path=$(printf '%s\n' "$raw_output" | marker_value "artifact_log_path")
  local updated_at=$(printf '%s\n' "$raw_output" | marker_value "updated_at")
  local progress_error=$(printf '%s\n' "$raw_output" | marker_value "error")

  if [ -z "$state$applied_count$total_count$pending_count" ]; then
    return 1
  fi

  local current_runtime_human=""
  local last_completed_runtime_human=""
  if [[ "$current_runtime_ms" =~ ^[0-9]+$ ]]; then
    current_runtime_human=$(format_runtime_ms "$current_runtime_ms")
  fi
  if [[ "$last_completed_runtime_ms" =~ ^[0-9]+$ ]]; then
    last_completed_runtime_human=$(format_runtime_ms "$last_completed_runtime_ms")
  fi

  echo "=== Migration Progress ==="
  [ -n "$state" ] && echo "State: $state"
  [ -n "$applied_count$total_count" ] && echo "Applied migrations: ${applied_count:-?}/${total_count:-?}"
  [ -n "$pending_count" ] && echo "Pending migrations: $pending_count"
  if [ -n "$latest_applied_version$latest_applied_filename" ]; then
    echo "Latest applied: ${latest_applied_version:-unknown} - ${latest_applied_filename:-unknown}"
  fi
  if [ -n "$current_version$current_filename" ]; then
    echo "Current migration: ${current_version:-unknown} - ${current_filename:-unknown}"
    [ -n "$current_description" ] && echo "Current description: $current_description"
    [ -n "$current_started_at" ] && echo "Current started: $current_started_at"
    [ -n "$current_runtime_human" ] && echo "Current runtime: $current_runtime_human"
  fi
  if [ -n "$last_completed_version$last_completed_filename" ]; then
    echo "Last completed: ${last_completed_version:-unknown} - ${last_completed_filename:-unknown}"
    [ -n "$last_completed_description" ] && echo "Last completed description: $last_completed_description"
    [ -n "$last_completed_completed_at" ] && echo "Last completed at: $last_completed_completed_at"
    [ -n "$last_completed_runtime_human" ] && echo "Last completed runtime: $last_completed_runtime_human"
  fi
  if [ -n "$next_version$next_filename" ]; then
    echo "Next pending: ${next_version:-unknown} - ${next_filename:-unknown}"
    [ -n "$next_description" ] && echo "Next description: $next_description"
  fi
  [ -n "$updated_at" ] && echo "Updated at: $updated_at"
  [ -n "$artifact_status_path" ] && echo "Artifact status: $artifact_status_path"
  [ -n "$artifact_events_path" ] && echo "Artifact events: $artifact_events_path"
  [ -n "$artifact_log_path" ] && echo "Artifact log: $artifact_log_path"
  [ -n "$progress_error" ] && echo "Error: $progress_error"
}

# Function to check migration status using Elixir release
migration_status() {
  local watch_mode=false
  local interval=5
  local iterations_limit=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --watch|-w)
        watch_mode=true
        shift
        ;;
      --interval|-i)
        if [[ -z "$2" ]]; then
          echo "Error: --interval requires a value (seconds)."
          return 1
        fi
        interval="$2"
        if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
          echo "Error: --interval must be a positive integer."
          return 1
        fi
        shift 2
        ;;
      --iterations|-n)
        if [[ -z "$2" ]]; then
          echo "Error: --iterations requires a value."
          return 1
        fi
        iterations_limit="$2"
        if ! [[ "$iterations_limit" =~ ^[0-9]+$ ]] || [ "$iterations_limit" -le 0 ]; then
          echo "Error: --iterations must be a positive integer."
          return 1
        fi
        shift 2
        ;;
      --help|-h)
        echo "Usage: $0 migration_status [--watch|-w] [--interval|-i seconds] [--iterations|-n count]"
        echo ""
        echo "Monitors the database migrations by comparing the release's migration list to the schema_migrations table."
        echo "  --watch (-w)       Continuously refresh until pending migrations reach zero."
        echo "  --interval (-i)    Seconds between refreshes in watch mode (default: 5)."
        echo "  --iterations (-n)  Maximum refresh cycles before exiting watch mode."
        return 0
        ;;
      *)
        echo "Unknown option for migration_status: $1"
        return 1
        ;;
    esac
  done

  echo "Checking database migration status..."

  local report_file="migrations-report.txt"

  local web_container
  web_container=$($DOCKER_COMPOSE_CMD ps -q web 2>/dev/null)
  if [ -z "$web_container" ]; then
    echo "Error: Web container not found or not running."
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  local container_status
  container_status=$(docker inspect --format='{{.State.Status}}' "$web_container" 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    echo "Error: Web container is not running (status: $container_status)"
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  local release_bin
  release_bin=$(get_release_binary)

  echo "Testing RPC connection..."
  local rpc_test
  local rpc_available=true
  rpc_test=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts("RPC connection successful")' 2>&1)
  if [[ "$rpc_test" == *"noconnection"* ]]; then
    echo "RPC unavailable; falling back to release-side migration artifact status."
    rpc_available=false
  fi

  echo "Using release binary: $release_bin"

  if [ "$watch_mode" = true ]; then
    echo "Entering watch mode (interval: ${interval}s). Press Ctrl+C to stop."
    if [ -n "$iterations_limit" ]; then
      echo "Watch iteration limit: $iterations_limit"
    fi
    echo ""
  fi

  local iteration=0

  while true; do
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    local raw_output
    local rpc_status

    raw_output=$(run_migration_status_artifact 2>/dev/null)
    rpc_status=$?
    if [ -z "$raw_output" ] && [ "$rpc_available" = true ]; then
      raw_output=$(run_migration_status_rpc "$release_bin")
      rpc_status=$?
    elif [ -z "$raw_output" ]; then
      raw_output=$(run_migration_status_eval "$release_bin")
      rpc_status=$?
    else
      rpc_status=0
    fi

    if [ $rpc_status -ne 0 ] && [ -z "$raw_output" ]; then
      raw_output=$(run_migration_status_eval "$release_bin")
      rpc_status=$?
    fi

    local pending_count
    pending_count=$(printf '%s\n' "$raw_output" | marker_value "pending_count")
    if [ -z "$pending_count" ]; then
      pending_count="unknown"
    fi

    local display_output
    display_output=$(render_migration_progress_from_markers "$raw_output" 2>/dev/null || true)
    if [ -z "$display_output" ]; then
      display_output=$(printf '%s\n' "$raw_output" | sed '/^::[a-z_].*=.*/d')
    fi

    local artifact_events_path
    artifact_events_path=$(printf '%s\n' "$raw_output" | marker_value "artifact_events_path")
    local artifact_log_path
    artifact_log_path=$(printf '%s\n' "$raw_output" | marker_value "artifact_log_path")

    if [ $rpc_status -ne 0 ] && [ "$pending_count" = "unknown" ]; then
      printf '%s\n' "$display_output"
      echo "Error: Failed to retrieve migration status (exit code $rpc_status)."
      return 1
    fi

    if [ "$watch_mode" = true ]; then
      echo "[$timestamp]"
    fi

    printf '%s\n' "$display_output"

    local artifact_events_tail=""
    artifact_events_tail=$(tail_migration_artifact_events "$artifact_events_path" 2)
    if [ -n "$artifact_events_tail" ]; then
      echo ""
      echo "Recent JSON events:"
      printf '%s\n' "$artifact_events_tail"
    fi

    local artifact_log_tail=""
    artifact_log_tail=$(tail_migration_artifact_log "$artifact_log_path" 5)
    if [ -n "$artifact_log_tail" ]; then
      echo ""
      echo "Recent log lines:"
      printf '%s\n' "$artifact_log_tail"
    fi

    cat > "$report_file" <<EOF
Call Telemetry Database Migration Status Report
Generated: $timestamp
Release binary: $release_bin
==========================================

$display_output

Recent JSON events:
$artifact_events_tail

Recent log lines:
$artifact_log_tail

EOF

    if [ "$watch_mode" = true ]; then
      echo "Last updated: $timestamp (report: $report_file)"
    else
      echo ""
      log_ok "Migration status check completed"
      echo "Report saved to: $report_file"
    fi

    if [[ "$pending_count" =~ ^[0-9]+$ ]] && [ "$pending_count" -eq 0 ]; then
      if [ "$watch_mode" = true ]; then
        echo "All migrations are up to date. Exiting watch mode."
      fi
      break
    fi

    if [ "$watch_mode" = false ]; then
      if [ "$pending_count" = "error" ]; then
        return 1
      fi
      break
    fi

    if [ "$pending_count" = "error" ]; then
      echo "Encountered an error while fetching migration status. Exiting watch mode."
      return 1
    fi

    if [[ "$pending_count" =~ ^[0-9]+$ ]]; then
      echo "Migrations are running (pending: $pending_count). Updating again in ${interval}s..."
    else
      echo "Migrations are running. Updating again in ${interval}s..."
    fi

    iteration=$((iteration + 1))
    if [ -n "$iterations_limit" ] && [ "$iteration" -ge "$iterations_limit" ]; then
      echo "Reached watch iteration limit ($iterations_limit)."
      break
    fi

    sleep "$interval"
    echo ""
  done
}

# Function to show SQL migration status directly from database
sql_migration_status() {
  echo "Fetching migration status from database..."
  echo ""

  # Check if db container is running
  db_container=$($DOCKER_COMPOSE_CMD ps -q db 2>/dev/null)
  if [ -z "$db_container" ]; then
    echo "Error: Database container not found or not running."
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  container_status=$(docker inspect --format='{{.State.Status}}' $db_container 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    echo "Error: Database container is not running (status: $container_status)"
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  # Check if database is ready
  if ! $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "Error: Database is not ready to accept connections"
    return 1
  fi

  echo "=== Last 10 Applied Migrations ==="
  echo ""
  $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "SELECT version, inserted_at FROM schema_migrations ORDER BY version DESC LIMIT 10;"

  echo ""
  echo "=== Migration Count ==="
  $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "SELECT COUNT(*) as total_migrations FROM schema_migrations;"
}

# Function to show table sizes
sql_table_size() {
  echo "Fetching table size information from database..."
  echo ""

  # Check if db container is running
  db_container=$($DOCKER_COMPOSE_CMD ps -q db 2>/dev/null)
  if [ -z "$db_container" ]; then
    echo "Error: Database container not found or not running."
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  container_status=$(docker inspect --format='{{.State.Status}}' $db_container 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    echo "Error: Database container is not running (status: $container_status)"
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  # Check if database is ready
  if ! $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "Error: Database is not ready to accept connections"
    return 1
  fi

  # Parse table list if provided
  tables="$1"

  if [ -z "$tables" ]; then
    # Show all tables
    echo "=== All Table Sizes ==="
    echo ""
    $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c "
SELECT
  table_name,
  row_count,
  pg_size_pretty(total_bytes) AS total_size,
  pg_size_pretty(index_bytes) AS index_size,
  pg_size_pretty(toast_bytes) AS toast_size,
  pg_size_pretty(table_bytes) AS table_size
FROM (
  SELECT
    c.relname AS table_name,
    c.reltuples::BIGINT AS row_count,
    pg_total_relation_size(c.oid) AS total_bytes,
    pg_indexes_size(c.oid) AS index_bytes,
    pg_total_relation_size(reltoastrelid) AS toast_bytes,
    pg_relation_size(c.oid) AS table_bytes
  FROM pg_class c
  LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
) t
ORDER BY total_bytes DESC;
"
  else
    # Show specific tables
    # Convert comma-separated list to SQL IN clause format
    table_list=$(echo "$tables" | sed "s/,/','/g")

    echo "=== Table Sizes for: $tables ==="
    echo ""
    $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c "
SELECT
  table_name,
  row_count,
  pg_size_pretty(total_bytes) AS total_size,
  pg_size_pretty(index_bytes) AS index_size,
  pg_size_pretty(toast_bytes) AS toast_size,
  pg_size_pretty(table_bytes) AS table_size
FROM (
  SELECT
    c.relname AS table_name,
    c.reltuples::BIGINT AS row_count,
    pg_total_relation_size(c.oid) AS total_bytes,
    pg_indexes_size(c.oid) AS index_bytes,
    pg_total_relation_size(reltoastrelid) AS toast_bytes,
    pg_relation_size(c.oid) AS table_bytes
  FROM pg_class c
  LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname IN ('$table_list')
) t
ORDER BY total_bytes DESC;
"
  fi

  echo ""
  echo "=== Database Total Size ==="
  $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "SELECT pg_size_pretty(pg_database_size('calltelemetry_prod')) AS database_size;"
}

# Function to purge old records from a table
sql_purge_table() {
  local table_name="$1"
  local days="$2"

  # Validate parameters
  if [ -z "$table_name" ] || [ -z "$days" ]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 sql_purge_table <table_name> <days>"
    echo "Example: $0 sql_purge_table cube_event_logs 30"
    return 1
  fi

  # Validate days is a number
  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    echo "Error: Days must be a positive number"
    return 1
  fi

  echo "Preparing to purge records from table: $table_name"
  echo "Records older than: $days days"
  echo ""

  # Check if db container is running
  db_container=$($DOCKER_COMPOSE_CMD ps -q db 2>/dev/null)
  if [ -z "$db_container" ]; then
    echo "Error: Database container not found or not running."
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  container_status=$(docker inspect --format='{{.State.Status}}' $db_container 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    echo "Error: Database container is not running (status: $container_status)"
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  # Check if database is ready
  if ! $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "Error: Database is not ready to accept connections"
    return 1
  fi

  # Check if table exists
  echo "Checking if table exists..."
  table_exists=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table_name');" | tr -d ' ')

  if [ "$table_exists" != "t" ]; then
    echo "Error: Table '$table_name' does not exist in the database"
    return 1
  fi

  # Check if table has inserted_at column
  echo "Checking for 'inserted_at' column..."
  column_exists=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$table_name' AND column_name = 'inserted_at');" | tr -d ' ')

  if [ "$column_exists" != "t" ]; then
    echo "Error: Table '$table_name' does not have an 'inserted_at' column"
    echo "This command requires the table to have a timestamp column named 'inserted_at'"
    return 1
  fi

  # Get count of records to be deleted
  echo ""
  echo "Counting records to be deleted..."
  records_to_delete=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT COUNT(*) FROM $table_name WHERE inserted_at < NOW() - INTERVAL '$days days';" | tr -d ' ')

  if [ -z "$records_to_delete" ] || [ "$records_to_delete" = "0" ]; then
    echo "No records found older than $days days. Nothing to purge."
    return 0
  fi

  echo "Found $records_to_delete records to delete (older than $days days)"
  echo ""

  # Show date cutoff
  cutoff_date=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT (NOW() - INTERVAL '$days days')::timestamp(0);" | tr -d ' ')
  echo "Cutoff date: $cutoff_date"
  echo ""

  # Confirm before deletion
  if [[ -t 0 ]]; then
    read -p "Are you sure you want to delete $records_to_delete records? (yes/NO): " -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
      echo "Purge cancelled by user"
      return 0
    fi
  else
    echo "Running in non-interactive mode - skipping confirmation"
    echo "Use interactive mode to confirm deletions"
    return 1
  fi

  echo "Starting purge operation..."
  echo ""

  # Perform the deletion and show progress
  start_time=$(date +%s)

  delete_result=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "DELETE FROM $table_name WHERE inserted_at < NOW() - INTERVAL '$days days';" 2>&1)

  end_time=$(date +%s)
  duration=$((end_time - start_time))

  echo "$delete_result"
  echo ""
  log_ok "Purge completed in ${duration} seconds"
  echo ""

  # Show updated table size
  echo "=== Updated Table Size ==="
  $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -c "
SELECT
  '$table_name' AS table_name,
  COUNT(*) AS remaining_rows,
  pg_size_pretty(pg_total_relation_size('$table_name')) AS total_size,
  pg_size_pretty(pg_relation_size('$table_name')) AS table_size,
  pg_size_pretty(pg_indexes_size('$table_name')) AS index_size
FROM $table_name;
"

  echo ""
  echo "Tip: Run 'VACUUM FULL $table_name' to reclaim disk space"
  echo "   Use: $DOCKER_COMPOSE_CMD exec -T db psql -U calltelemetry -d calltelemetry_prod -c 'VACUUM FULL $table_name;'"
}

# Function to run pending migrations using Elixir release
migration_run() {
  echo "Running pending database migrations..."

  # Check if web container is running and application is ready
  web_container=$($DOCKER_COMPOSE_CMD ps -q web 2>/dev/null)
  if [ -z "$web_container" ]; then
    echo "Error: Web container not found or not running."
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  container_status=$(docker inspect --format='{{.State.Status}}' $web_container 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    echo "Error: Web container is not running (status: $container_status)"
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  # Test RPC connection
  release_bin=$(get_release_binary)
  rpc_test=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts("RPC connection successful")' 2>&1)
  if [[ "$rpc_test" == *"noconnection"* ]]; then
    echo "Error: Cannot connect to running application via RPC"
    echo "The application may still be starting up. Please wait and try again."
    return 1
  fi

  echo "Using release binary: $release_bin"

  # Execute migrations — stream output live (no variable capture)
  echo "Executing migrations..."
  $DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc '
    IO.puts("=== Running Migrations ===")

    try do
      result = Ecto.Migrator.run(Cdrcisco.Repo, :up, all: true)

      case result do
        [] ->
          IO.puts("No pending migrations to run.")
        migrations ->
          IO.puts("Successfully ran #{length(migrations)} migrations:")
          for {status, version, name} <- migrations do
            IO.puts("  #{status} #{version} #{name}")
          end
      end

      IO.puts("")
      IO.puts("Migration run completed successfully!")
    rescue
      e ->
        IO.puts("Error running migrations: #{inspect(e)}")
        System.halt(1)
    end
  ' 2>&1

  if [ $? -eq 0 ]; then
    echo ""
    log_ok "Migration run completed successfully"
  else
    echo ""
    log_fail "Migration run failed"
    return 1
  fi
}

# ── ct-cli migration state helpers ──
# Read/write ~/.ct/migrations.json in the same format ct-cli uses:
#   { "completed": { "014_partition_drain": { "at": "ISO8601", "result": "applied" } } }
# This lets ct-cli skip migrations already completed by cli.sh.
CT_MIGRATIONS_FILE="$HOME/.ct/migrations.json"

# Check if a migration ID is already completed. Returns 0 (true) if done.
ct_migration_done() {
  local id="$1"
  if [ ! -f "$CT_MIGRATIONS_FILE" ]; then
    return 1
  fi
  # Use python3 (available on AlmaLinux) for reliable JSON parsing
  python3 -c "
import json, sys
try:
    state = json.load(open('$CT_MIGRATIONS_FILE'))
    sys.exit(0 if '$id' in state.get('completed', {}) else 1)
except:
    sys.exit(1)
" 2>/dev/null
}

# Mark a migration as completed with timestamp.
ct_migration_mark() {
  local id="$1"
  local result="${2:-applied}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "$HOME/.ct"

  # Merge into existing state or create new
  python3 -c "
import json, os
path = '$CT_MIGRATIONS_FILE'
state = {'completed': {}, 'errors': {}}
if os.path.exists(path):
    try:
        state = json.load(open(path))
    except:
        pass
state.setdefault('completed', {})['$id'] = {'at': '$ts', 'result': '$result'}
with open(path, 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')
" 2>/dev/null
}

# Drain legacy partition tables and default partition overflow.
# Runs synchronously — may take a while for large tables (progress is streamed).
# Safe to run multiple times (idempotent).
migration_drain() {
  echo "=== Partition Data Migration ==="
  echo "Checking for legacy tables and default partition overflow..."
  echo ""
  echo "The application will be stopped during this operation to avoid"
  echo "lock contention. It will be restarted automatically when complete."
  echo ""

  release_bin=$(get_release_binary)

  # Stop the web container — drain needs exclusive DB access.
  # CREATE TABLE PARTITION OF takes ACCESS EXCLUSIVE on the parent table;
  # running this while the app serves traffic blocks all queries.
  echo "Stopping application..."
  $DOCKER_COMPOSE_CMD stop web 2>/dev/null

  # Start the container without the app (just the OS) so we can exec into it.
  # Override the entrypoint to sleep instead of running the app.
  echo "Starting drain container..."
  $DOCKER_COMPOSE_CMD run --rm -T --no-deps --entrypoint "" web \
    "$release_bin" eval 'Cdrcisco.Release.drain_legacy_partitions()' 2>&1

  drain_exit=$?

  # Restart the full stack (entrypoint runs migrations then starts app)
  echo ""
  echo "Restarting application..."
  $DOCKER_COMPOSE_CMD up -d web 2>/dev/null

  if [ $drain_exit -eq 0 ]; then
    log_ok "Partition drain completed — application restarting"
  else
    log_fail "Partition drain failed (exit code $drain_exit)"
    echo "       Application is restarting. Retry with: cli.sh migrate drain"
    return 1
  fi
}

# Function to rollback migrations using Elixir release
migration_rollback() {
  steps=${1:-1}
  echo "Rolling back $steps migration(s)..."
  
  # Check if web container is running and application is ready
  web_container=$($DOCKER_COMPOSE_CMD ps -q web 2>/dev/null)
  if [ -z "$web_container" ]; then
    echo "Error: Web container not found or not running."
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  container_status=$(docker inspect --format='{{.State.Status}}' $web_container 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    echo "Error: Web container is not running (status: $container_status)"
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    return 1
  fi

  # Test RPC connection
  release_bin=$(get_release_binary)
  rpc_test=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts("RPC connection successful")' 2>&1)
  if [[ "$rpc_test" == *"noconnection"* ]]; then
    echo "Error: Cannot connect to running application via RPC"
    echo "The application may still be starting up. Please wait and try again."
    return 1
  fi

  echo "Using release binary: $release_bin"
  
  # Execute rollback
  echo "Executing rollback..."
  rollback_output=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc "
    IO.puts(\"=== Rolling Back Migrations ===\")
    
    try do
      result = Ecto.Migrator.run(Cdrcisco.Repo, :down, step: $steps)
      
      case result do
        [] -> 
          IO.puts(\"No migrations to rollback.\")
        migrations ->
          IO.puts(\"Successfully rolled back #{length(migrations)} migrations:\")
          for {status, version, name} <- migrations do
            IO.puts(\"  #{status} #{version} #{name}\")
          end
      end
      
      IO.puts(\"\")
      IO.puts(\"Migration rollback completed successfully!\")
    rescue
      e -> 
        IO.puts(\"Error rolling back migrations: #{inspect(e)}\")
        System.halt(1)
    end
  " 2>&1)

  # Display output
  echo "$rollback_output"
  
  if [ $? -eq 0 ]; then
    echo ""
    log_ok "Migration rollback completed successfully"
  else
    echo ""
    log_fail "Migration rollback failed"
    return 1
  fi
}

# Consolidated migration command
migrate_cmd() {
  local action="$1"
  shift

  case "$action" in
    run)
      migration_run
      ;;
    drain)
      migration_drain
      ;;
    rollback)
      migration_rollback "${1:-1}"
      ;;
    history)
      sql_migration_status
      ;;
    watch)
      migration_status --watch "$@"
      ;;
    ""|status)
      migration_status "$@"
      ;;
    *)
      echo "Unknown migrate command: $action"
      echo ""
      echo "Usage: cli.sh migrate <command>"
      echo ""
      echo "Commands:"
      echo "  status            Show migration status (default)"
      echo "  run               Run pending migrations + partition drain"
      echo "  drain             Run partition drain only (idempotent)"
      echo "  rollback [n]      Rollback n migrations (default: 1)"
      echo "  history           Show last 10 migrations from database"
      echo "  watch             Watch migration progress continuously"
      return 1
      ;;
  esac
}

# Hide known-benign application log lines that otherwise look like actionable
# status errors to appliance operators.
_status_filter_benign_log_noise() {
  local line
  while IFS= read -r line; do
    case "$line" in
      *'"message":"[CTSFTPD] Starting SSH daemon on port 3022",'*|*'| [CTSFTPD] Starting SSH daemon on port 3022')
        continue
        ;;
    esac
    printf '%s\n' "$line"
  done
}

# Function to show comprehensive application status and diagnostics
app_status() {
  local app_migration_status=""
  local app_migrations_complete=0
  local migration_count=""
  local total_migrations=""

  echo "============================================"
  echo "     Call Telemetry Application Status"
  echo "============================================"
  echo ""

  # Container status
  echo "=== Container Status ==="
  $DOCKER_COMPOSE_CMD $(get_compose_files) ps
  echo ""

  # JTAPI feature status
  if is_jtapi_enabled; then
    echo "=== JTAPI Status ==="
    log_ok "JTAPI: enabled"
    echo ""
  fi

  # Check if web container is running
  web_container=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps -q web 2>/dev/null)
  if [ -z "$web_container" ]; then
    log_fail "Web container not running"
    return 1
  fi

  container_status=$(docker inspect --format='{{.State.Status}}' "$web_container" 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    log_fail "Web container status: $container_status"
    return 1
  fi

  # Database connectivity
  echo "=== Database Status ==="
  if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    log_ok "Database: accepting connections"

    # Get applied migration count from DB
    migration_count=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
      "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null | tr -d ' ')

    # Get total expected migrations from release
    total_migrations=$(get_release_migration_count "$release_bin")
    total_migrations=${total_migrations:-"?"}

    log_ok "Migrations in database: $migration_count / $total_migrations"

    # Get latest migration
    latest=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
      "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;" 2>/dev/null | tr -d ' ')
    log_ok "Latest migration: $latest"
  else
    log_fail "Database: not accepting connections"
  fi
  echo ""

  # RPC status check
  echo "=== Application RPC Status ==="
  release_bin=$(get_release_binary)
  rpc_test=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts("ok")' 2>&1)
  if [[ "$rpc_test" == *"ok"* ]]; then
    log_ok "RPC connection: working"

    # Get app-side migration status
    echo ""
    echo "=== Migration Status (from application) ==="
    app_migration_status=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc '
      alias Cdrcisco.Repo
      try do
        migrations = Ecto.Migrator.migrations(Repo)
        {applied, pending} = Enum.split_with(migrations, fn {status, _, _} -> status == :up end)
        IO.puts("Applied: #{length(applied)}")
        IO.puts("Pending: #{length(pending)}")
        if length(pending) > 0 do
          IO.puts("")
          IO.puts("Pending migrations:")
          Enum.each(pending, fn {_, version, name} -> IO.puts("  - #{version}: #{name}") end)
        else
          IO.puts("✓ All migrations complete!")
        end
      rescue
        e -> IO.puts("Error: #{inspect(e)}")
      end
    ' 2>&1)
    printf '%s\n' "$app_migration_status"
    if printf '%s\n' "$app_migration_status" | grep -q "All migrations complete"; then
      app_migrations_complete=1
    fi
  else
    log_fail "RPC connection: failed"
    echo "   Application may still be starting up"
    echo "   Error: $rpc_test"
  fi
  echo ""

  # Host-facing service ports
  echo "=== Service Ports ==="
  local port_ok=true

  # CURRI HTTP (Caddy port 80)
  if probe_host_port 80 2; then
    log_ok "CURRI HTTP (port 80): reachable"
  else
    log_fail "CURRI HTTP (port 80): not reachable"
    port_ok=false
  fi

  # Admin HTTPS (Caddy port 443)
  if probe_host_port 443 2; then
    log_ok "Admin HTTPS (port 443): reachable"
  else
    log_fail "Admin HTTPS (port 443): not reachable"
    port_ok=false
  fi

  # SFTP (port 22)
  if probe_host_port 22 2; then
    log_ok "SFTP (port 22): reachable"
  else
    log_fail "SFTP (port 22): not reachable"
    port_ok=false
  fi

  if $port_ok; then
    echo ""
    log_ok "All service ports healthy"
  fi
  echo ""

  # Check for scheduler/startup progress. Filter known-benign startup lines that
  # carry error severity in the application log but are not operator issues.
  echo "=== Recent Startup Messages ==="
  recent_startup_messages=$(
    $DOCKER_COMPOSE_CMD logs --tail 50 web 2>&1 |
      _status_filter_benign_log_noise |
      grep -E "(Migration|completed|scheduler|not started|error|Error|started)" |
      grep -Ev 'Migration process completed' |
      tail -15 || true
  )
  if [ -n "$recent_startup_messages" ]; then
    printf '%s\n' "$recent_startup_messages"
  else
    log_ok "No recent startup issues detected"
  fi
  echo ""

  # Check for specific issues
  echo "=== Issue Detection ==="
  recent_logs=$(
    $DOCKER_COMPOSE_CMD logs --tail 100 web 2>&1 |
      _status_filter_benign_log_noise
  )

  # Check for migration completion
  if [ "$app_migrations_complete" = "1" ] ||
     { [ -n "${migration_count:-}" ] && [ -n "${total_migrations:-}" ] &&
       [ "$total_migrations" != "?" ] && [ "$migration_count" = "$total_migrations" ]; }; then
    log_ok "Migrations: completed successfully"
  elif echo "$recent_logs" | grep -q "Pending migrations"; then
    echo "Migrations: still running"
  else
    log_info "Migrations: status not found in recent logs; use the database/application status above"
  fi

  # Check for scheduler errors
  scheduler_errors=$(echo "$recent_logs" | grep "not started: invalid task function" | wc -l)
  if [ "$scheduler_errors" -gt 0 ]; then
    log_warn "Scheduler: $scheduler_errors jobs failed to start (invalid task function)"
    echo "   This may indicate version mismatch or missing modules"
    echo "$recent_logs" | grep "not started: invalid task function" | head -5 | sed 's/^/   /'
  else
    log_ok "Scheduler: no startup errors detected"
  fi

  # Check for NATS connectivity
  if echo "$recent_logs" | grep -q "WorkflowNatsSupervisor"; then
    log_ok "NATS: supervisor initialized"
  fi
  echo ""

  # System resources
  show_system_activity
  echo ""
}

# Function to get current logging level
get_logging_level() {
  if [ ! -f "$ORIGINAL_FILE" ]; then
    echo "unknown"
    return
  fi

  local level=$(grep -oP 'LOGGING_LEVEL=\K[a-z]+' "$ORIGINAL_FILE" 2>/dev/null || \
                grep 'LOGGING_LEVEL=' "$ORIGINAL_FILE" | sed 's/.*LOGGING_LEVEL=//' | tr -d ' "')
  echo "${level:-warning}"
}

# Function to toggle/show logging level
logging_toggle() {
  local level="$1"

  if [ -z "$level" ]; then
    # Show current status
    local current_level=$(get_logging_level)
    echo "Logging Level: $current_level"
    echo ""
    echo "Available levels: debug, info, warning, error"
    echo "Usage: cli.sh logging <level>"
    return 0
  fi

  case "$level" in
    debug|info|warning|error)
      local current_level=$(get_logging_level)
      echo "Changing logging level: $current_level -> $level"
      sed -i -E "s/^(.*LOGGING_LEVEL=).*$/\1$level/" "$ORIGINAL_FILE"
      echo "Logging level set to $level"
      echo ""
      fix_systemd_service_if_needed
      if ! restart_service "logging $level"; then
        log_fail "Service restart failed after logging level change."
        return 1
      fi
      echo ""
      wait_for_services
      ;;
    status)
      local current_level=$(get_logging_level)
      echo "Logging Level: $current_level"
      echo ""
      echo "Available levels:"
      echo "  debug   - Verbose debugging information"
      echo "  info    - General information messages"
      echo "  warning - Warning messages only (default)"
      echo "  error   - Error messages only"
      ;;
    *)
      echo "Error: Invalid logging level '$level'"
      echo ""
      echo "Available levels: debug, info, warning, error"
      echo "Usage: cli.sh logging <level>"
      return 1
      ;;
  esac
}

# Function to build the appliance by fetching and executing the prep script
# Supports CT_PREP_SCRIPT_PATH environment variable to use a local script instead of downloading
build_appliance() {
  local prep_script="/tmp/prep.sh"
  local cleanup_script=true

  # Check if a local prep script path was provided
  if [ -n "${CT_PREP_SCRIPT_PATH:-}" ] && [ -f "${CT_PREP_SCRIPT_PATH}" ]; then
    echo "Using local prep script: ${CT_PREP_SCRIPT_PATH}"
    prep_script="${CT_PREP_SCRIPT_PATH}"
    cleanup_script=false
  else
    echo "Downloading and executing the prep script to build the appliance..."
    wget -q "$PREP_SCRIPT_URL" -O /tmp/prep.sh
    if [ $? -ne 0 ]; then
      echo "Failed to download the prep script. Please check your internet connection."
      return 1
    fi
    echo "Script downloaded."
    chmod +x /tmp/prep.sh
  fi

  echo "Executing the prep script..."
  # Run the script - it will pick up CT_NONINTERACTIVE from the environment
  "$prep_script"
  local result=$?

  if [ $result -eq 0 ]; then
    sudo chown -R "$INSTALL_USER" "$BACKUP_DIR"
    sudo chown -R "$INSTALL_USER" "$BACKUP_FOLDER_PATH"
  fi

  # Cleanup only if we downloaded the script
  if [ "$cleanup_script" = true ] && [ -f /tmp/prep.sh ]; then
    rm -f /tmp/prep.sh
  fi

  return $result
}

# Function to prepare the cluster node with necessary tools
prep_cluster_node() {
  # Disable Firewall and SELinux
  sudo systemctl stop firewalld
  sudo systemctl disable firewalld
  sudo setenforce permissive
  sudo systemctl disable rpcbind

  # Install Kubectl and Helm via SNAPS
  sudo yum install -y wget epel-release
  sudo yum install -y snapd
  sudo systemctl enable --now snapd.socket
  sudo ln -s /var/lib/snapd/snap /snap
  sudo snap wait system seed.loaded
  sudo systemctl restart snapd.seeded.service
  sudo snap install kubectl --classic
  sudo snap install helm --classic

  # Install K9s Kubernetes Management tool
  echo "Installing k9s toolkit - https://github.com/derailed/k9s/"
  K9S_LATEST_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep "tag_name" | cut -d '"' -f 4)
  wget https://github.com/derailed/k9s/releases/download/$K9S_LATEST_VERSION/k9s_Linux_amd64.tar.gz
  tar -xzf k9s_Linux_amd64.tar.gz
  sudo mv k9s /usr/local/bin
  mkdir -p ~/.k9s
  rm -rf k9s_Linux_amd64.tar.gz

  # Install GIT
  sudo dnf install -y git

  # Copy k3s kubeconfig so kubectl/k9s/helm work without sudo
  if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown "$(id -u):$(id -g)" ~/.kube/config
    echo "k3s kubeconfig copied to ~/.kube/config"
  else
    echo "k3s not installed yet — run k3s install first, then re-run prep-cluster-node to copy kubeconfig"
  fi
}

# Function to generate self-signed certificates if they do not exist, are expired, or are mismatched
generate_self_signed_certificates() {
  cert_dir="./certs"
  cert_file="$cert_dir/appliance.crt"
  key_file="$cert_dir/appliance_key.pem"

  local need_generate=false

  if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
    need_generate=true
  elif command -v openssl >/dev/null 2>&1; then
    # Regenerate if expired
    if ! openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1; then
      echo "Certificate is expired. Regenerating..."
      need_generate=true
    else
      # Regenerate if cert and key don't match
      local cert_mod key_mod
      cert_mod=$(openssl x509 -in "$cert_file" -noout -modulus 2>/dev/null | md5sum)
      key_mod=$(openssl rsa -in "$key_file" -noout -modulus 2>/dev/null | md5sum)
      if [ "$cert_mod" != "$key_mod" ]; then
        echo "Certificate and key do not match. Regenerating..."
        need_generate=true
      fi
    fi
  fi

  if [ "$need_generate" = true ]; then
    echo "Generating self-signed certificates..."
    mkdir -p "$cert_dir"
    if ! openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" -subj "/CN=appliance.calltelemetry.internal" >/dev/null 2>&1; then
      log_fail "Failed to generate self-signed certificates."
      return 1
    fi
    echo "Self-signed certificates generated."
  else
    log_verbose "Certificates already exist and are valid. Skipping generation."
  fi
}

# Function to reset certificates by deleting all files in the certs folder and generating new ones
reset_certs() {
  cert_dir="./certs"
  echo "Deleting all files in the certs folder..."
  rm -rf "$cert_dir"/*
  echo "All files in the certs folder have been deleted."

  echo "Generating new self-signed certificates..."
  generate_self_signed_certificates
  echo "New self-signed certificates generated."
}

# Function to show certificate status
certs_status() {
  local cert_dir="./certs"
  local cert_file="$cert_dir/appliance.crt"
  local key_file="$cert_dir/appliance_key.pem"

  echo "=== Certificate Status ==="
  echo ""

  if [ ! -d "$cert_dir" ]; then
    log_fail "Certificate directory not found: $cert_dir"
    return 1
  fi

  echo "Certificate directory: $cert_dir"
  echo ""

  # Check certificate file
  if [ -f "$cert_file" ]; then
    log_ok "Certificate file: $cert_file"

    # Get certificate details using openssl
    if command -v openssl >/dev/null 2>&1; then
      echo ""
      echo "  Subject:    $(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')"

      local end_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
      echo "  Expires:    $end_date"

      # Check if expired
      if openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1; then
        # Check if expiring within 30 days
        if openssl x509 -in "$cert_file" -noout -checkend 2592000 >/dev/null 2>&1; then
          echo "  Status:     ✓ Valid"
        else
          echo "  Status:     [WARN] Expiring soon (within 30 days)"
        fi
      else
        echo "  Status:     ✗ EXPIRED"
      fi

      local issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/issuer=//')
      echo "  Issuer:     $issuer"

      # Check if self-signed
      local subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null)
      local issuer_check=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null)
      if [ "$subject" = "$issuer_check" ]; then
        echo "  Type:       Self-signed"
      else
        echo "  Type:       CA-signed"
      fi
    fi
  else
    log_fail "Certificate file not found: $cert_file"
  fi

  echo ""

  # Check key file
  if [ -f "$key_file" ]; then
    log_ok "Private key: $key_file"

    # Verify key matches certificate
    if [ -f "$cert_file" ] && command -v openssl >/dev/null 2>&1; then
      local cert_modulus=$(openssl x509 -in "$cert_file" -noout -modulus 2>/dev/null | md5sum)
      local key_modulus=$(openssl rsa -in "$key_file" -noout -modulus 2>/dev/null | md5sum)
      if [ "$cert_modulus" = "$key_modulus" ]; then
        echo "  Key match:  ✓ Key matches certificate"
      else
        echo "  Key match:  ✗ Key does NOT match certificate"
      fi
    fi
  else
    log_fail "Private key not found: $key_file"
  fi

  echo ""

  # List all files in cert directory
  echo "Files in $cert_dir:"
  ls -la "$cert_dir" 2>/dev/null | tail -n +2 | awk '{print "  " $0}'
}

# Consolidated certificate command
certs_cmd() {
  local action="$1"

  case "$action" in
    reset)
      reset_certs
      ;;
    generate)
      generate_self_signed_certificates
      ;;
    ""|status)
      certs_status
      ;;
    *)
      echo "Unknown certs command: $action"
      echo ""
      echo "Usage: cli.sh certs <command>"
      echo ""
      echo "Commands:"
      echo "  status      Show certificate status and expiry (default)"
      echo "  reset       Delete and regenerate self-signed certificates"
      echo "  generate    Generate certificates if missing"
      return 1
      ;;
  esac
}

# Auto-migrate legacy .jtapi-enabled to .env on any CLI invocation
migrate_jtapi_state
# Sync preferences.json → COMPOSE_PROFILES for optional stacks
sync_prefs_to_env_storage
sync_prefs_to_env_syslog
sync_prefs_to_env_otel

# Main script logic
case "$1" in
  --help|-h|help)
    show_help
    ;;
  update)
    shift
    for _arg in "$@"; do
      case "$_arg" in
        --verbose|-v) export CLI_VERBOSE=1 ;;
      esac
    done
    unset _arg
    self_update_and_reexec "$@"
    ensure_ip_forward
    nm_heal_connections
    generate_self_signed_certificates
    update "$@"
    ;;
  rollback)
    shift
    rollback "$@"
    ;;
  reset)
    reset_app
    ;;
  status)
    app_status
    ;;

  # Seed / demo data commands
  seed)
    shift
    seed_cmd "$@"
    ;;

  # User management commands
  users)
    users_list
    ;;

  reset-password)
    shift
    reset_password_cmd "$@"
    ;;

  bootstrap-admin)
    shift
    bootstrap_admin_cmd "$@"
    ;;

  # Database commands
  db)
    shift
    db_cmd "$@"
    ;;

  # Migration commands
  migrate)
    shift
    migrate_cmd "$@"
    ;;

  # Configuration commands
  logging)
    logging_toggle "$2"
    ;;
  ipv6)
    ipv6_toggle "$2"
    ;;
  network)
    shift
    network_cmd "$@"
    ;;
  certs)
    certs_cmd "$2"
    ;;
  postgres)
    case "$2" in
      ""|status)
        echo "PostgreSQL Configuration"
        echo "========================"
        echo "Configured version: $(get_postgres_version)"
        echo "Current image:      $(get_current_postgres_image)"
        echo "Supported versions: $POSTGRES_SUPPORTED_VERSIONS"
        echo ""
        echo "Usage:"
        echo "  cli.sh postgres set <version>              Set version for next update"
        echo "  cli.sh postgres upgrade <version>          Upgrade to new major version"
        echo "  cli.sh postgres convert-bitnami [--dry-run] Repair missing config files in postgres-data/data"
        echo "  cli.sh postgres profile <small|medium|large|show>  Set connection sizing profile"
        ;;
      profile)
        subaction="${3:-show}"
        case "$subaction" in
          show)
            current=$(env_get "PG_PROFILE")
            echo "Current PostgreSQL profile: ${current:-small (default)}"
            echo ""
            echo "  small  — 100 max_connections, 15 per repo pool"
            echo "  medium — 200 max_connections, 20 per repo pool"
            echo "  large  — 300 max_connections, 25 per repo pool"
            echo "  migration pool defaults to 20 for small/medium and 25 for large"
            echo ""
            echo "Current values:"
            echo "  max_connections:       $(env_get PG_MAX_CONNECTIONS || echo '100 (default)')"
            echo "  db_pool (main):        $(env_get DB_POOL_SIZE || echo '15 (default)')"
            echo "  db_pool (migration):   $(env_get DB_MIGRATION_POOL_SIZE || echo '20 (default)')"
            echo "  db_pool (callctl):     $(env_get DB_CALL_CONTROL_POOL_SIZE || echo '15 (default)')"
            echo "  db_pool (background):  $(env_get DB_BACKGROUND_POOL_SIZE || echo '15 (default)')"
            echo "  db_pool (discovery):   $(env_get DB_DISCOVERY_POOL_SIZE || echo '15 (default)')"
            echo "  db_pool (oban):        $(env_get DB_OBAN_POOL_SIZE || echo '15 (default)')"
            ;;
          small|medium|large)
            apply_postgres_profile "$subaction"
            ;;
          *)
            echo "Usage: cli.sh postgres profile <small|medium|large|show>"
            exit 1
            ;;
        esac
        ;;
      set)
        if [ -z "$3" ]; then
          echo "Usage: cli.sh postgres set <version>"
          echo "Supported versions: $POSTGRES_SUPPORTED_VERSIONS"
          exit 1
        fi
        set_postgres_version "$3"
        echo ""
        echo "Note: Run 'cli.sh update' to apply the new PostgreSQL version."
        ;;
      upgrade)
        if [ -z "$3" ]; then
          echo "Usage: cli.sh postgres upgrade <version>"
          echo "Supported versions: $POSTGRES_SUPPORTED_VERSIONS"
          exit 1
        fi
        target_version="$3"
        current_image=$(get_current_postgres_image)

        echo "PostgreSQL Major Version Upgrade"
        echo "================================="
        echo "Current image: $current_image"
        echo "Target version: $target_version"
        echo ""
        echo "WARNING: Major version upgrades require a full database dump and restore."
        echo "The data directory format changes between major versions."
        echo ""
        echo "This process will:"
        echo "  1. Set PostgreSQL $target_version override"
        echo "  2. Create a database backup (pg_dump)"
        echo "  3. Stop all services"
        echo "  4. Remove the old postgres-data directory"
        echo "  5. Start PostgreSQL $target_version (fresh initialization)"
        echo "  6. Restore the database from backup"
        echo "  7. Restart all services"
        echo ""

        # Check if running in interactive mode
        if [[ -t 0 ]]; then
          read -p "Do you want to proceed? (yes/no): " confirm
          if [ "$confirm" != "yes" ]; then
            echo "Upgrade cancelled."
            exit 0
          fi
        else
          echo "Running in non-interactive mode - proceeding automatically in 10 seconds..."
          echo "Press Ctrl+C to cancel."
          sleep 10
        fi

        # Pre-flight: disk space check
        echo "Checking disk space..."
        db_size_kb=$($DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db \
          psql -U calltelemetry -d calltelemetry_prod -t -c \
          "SELECT pg_database_size('calltelemetry_prod') / 1024" 2>/dev/null | tr -d ' ')
        free_kb=$(df -k "$INSTALL_DIR" | tail -1 | awk '{print $4}')

        if [ -n "$db_size_kb" ] && [ -n "$free_kb" ]; then
          # Compressed dump needs ~20% of DB size (conservative estimate)
          required_kb=$((db_size_kb / 5))
          db_size_mb=$((db_size_kb / 1024))
          free_mb=$((free_kb / 1024))
          required_mb=$((required_kb / 1024))

          echo "  Database size:  ${db_size_mb} MB"
          echo "  Free space:     ${free_mb} MB"
          echo "  Required:       ~${required_mb} MB (compressed backup)"

          if [ "$free_kb" -lt "$required_kb" ]; then
            echo ""
            echo "ERROR: Insufficient disk space for PostgreSQL upgrade"
            echo "  Free up at least ${required_mb} MB before proceeding."
            exit 1
          fi
          echo "  Sufficient disk space"
        else
          echo "  Could not determine database size - proceeding anyway"
        fi

        # Set the new version (Step 1)
        echo ""
        echo "Step 1: Setting PostgreSQL $target_version override..."
        if ! set_postgres_version "$target_version"; then
          exit 1
        fi

        # Create compressed backup
        echo ""
        echo "Step 2: Creating compressed database backup..."
        backup_file="postgres-upgrade-$(date +%Y%m%d-%H%M%S).sql.gz"
        if ! $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db \
          pg_dump -U calltelemetry -d calltelemetry_prod | gzip > "$backup_file"; then
          echo "ERROR: Failed to create database backup"
          exit 1
        fi
        backup_size=$(du -h "$backup_file" | cut -f1)
        echo "Backup created: $backup_file ($backup_size compressed)"

        # Stop services
        echo ""
        echo "Step 3: Stopping all services..."
        $DOCKER_COMPOSE_CMD $(get_compose_files) down

        # Remove old data directory
        echo ""
        echo "Step 4: Removing old postgres-data directory..."
        sudo rm -rf "$POSTGRES_DATA_DIR"

        # Start just the database (override file already set in Step 1)
        echo ""
        echo "Step 5: Starting PostgreSQL $target_version..."
        $DOCKER_COMPOSE_CMD $(get_compose_files) up -d db

        echo "Waiting for PostgreSQL to initialize..."
        sleep 10

        # Wait for database to be ready
        for i in {1..30}; do
          if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
            echo "PostgreSQL is ready."
            break
          fi
          echo "Waiting for PostgreSQL... ($i/30)"
          sleep 2
        done

        # Restore the database from compressed backup
        echo ""
        echo "Step 6: Restoring database from compressed backup..."
        if ! gunzip -c "$backup_file" | \
          $DOCKER_COMPOSE_CMD exec -e "PGPASSWORD=$(_db_password)" -T db \
          psql -q -U calltelemetry -d calltelemetry_prod; then
          echo "ERROR: Failed to restore database"
          echo "Backup file preserved at: $backup_file"
          exit 1
        fi
        echo "Database restored successfully."

        # Start all services
        echo ""
        echo "Step 7: Starting all services..."
        $DOCKER_COMPOSE_CMD $(get_compose_files) up -d

        # If upgraded to the base default (17), the override is no longer needed
        if [ "$target_version" = "17" ] && [ -f "$POSTGRES_OVERRIDE_FILE" ]; then
          echo "Removing PostgreSQL override (now matches base default)."
          rm -f "$POSTGRES_OVERRIDE_FILE"
        fi

        echo ""
        echo "PostgreSQL upgrade complete!"
        echo "New image: calltelemetry/postgres:$target_version"
        echo ""

        # Post-upgrade verification and backup cleanup
        if [[ -t 0 ]]; then
          echo "─────────────────────────────────────────────"
          echo "  Post-Upgrade Verification"
          echo "─────────────────────────────────────────────"
          echo ""
          echo "Please verify the database upgrade was successful:"
          echo "  - Log in to the web UI"
          echo "  - Check that dashboards and reports load correctly"
          echo "  - Verify historical data is intact"
          echo ""
          read -p "Was the upgrade successful? (yes/no): " upgrade_ok
          if [[ "$upgrade_ok" =~ ^[Yy] ]]; then
            echo ""
            echo "The database backup is at:"
            echo "  $backup_file ($backup_size compressed)"
            read -p "Would you like to delete the backup file? (yes/no): " delete_backup
            if [[ "$delete_backup" =~ ^[Yy] ]]; then
              rm -f "$backup_file"
              log_ok "Backup file deleted."
            else
              echo "Backup preserved at: $backup_file"
            fi
          else
            echo ""
            echo "The database backup is preserved at: $backup_file"
            echo "To restore manually:"
            echo "  gunzip -c $backup_file | docker exec -i <db-container> psql -U calltelemetry -d calltelemetry_prod"
          fi
        else
          echo "Backup preserved at: $backup_file"
        fi
        ;;
      convert-bitnami)
        shift 2
        repair_postgres_compat "$(get_current_postgres_image)" "$@"
        ;;
      *)
        echo "Unknown postgres command: $2"
        echo "Usage: cli.sh postgres [status|set <version>|upgrade <version>|convert-bitnami [--dry-run]|profile <small|medium|large|show>]"
        exit 1
        ;;
    esac
    ;;

  jtapi)
    # Pass all positional args (subcommand + any flags like --section) through
    # to the jtapi dispatcher so e.g. `cli.sh jtapi troubleshoot --section nats`
    # doesn't drop the flag at the top level.
    shift
    jtapi_cmd "$@"
    ;;

  storage)
    storage_cmd "$2"
    ;;

  syslog)
    syslog_cmd "$2"
    ;;

  otel)
    otel_cmd "$2"
    ;;

  # Maintenance commands
  selfupdate)
    cli_update
    ;;
  fix-service)
    echo "Updating systemd service to use modern docker compose..."
    SERVICE_FILE="/etc/systemd/system/docker-compose-app.service"

    if [ ! -f "$SERVICE_FILE" ]; then
      echo "Error: Service file not found at $SERVICE_FILE"
      return 1
    fi

    # Check if already using modern syntax
    if grep -q "/usr/bin/docker compose" "$SERVICE_FILE"; then
      echo "Service file already uses modern 'docker compose' syntax."
      return 0
    fi

    # Backup existing service file
    sudo cp "$SERVICE_FILE" "${SERVICE_FILE}.backup"
    echo "Backed up existing service to ${SERVICE_FILE}.backup"

    # Update the service file to use modern docker compose
    sudo sed -i 's|/usr/bin/docker-compose|/usr/bin/docker compose|g' "$SERVICE_FILE"

    echo "Updated service file."
    echo ""
    echo "Reloading systemd daemon..."
    sudo systemctl daemon-reload

    echo ""
    echo "Service file updated successfully."
    echo "To apply changes, restart the service with:"
    echo "  sudo systemctl restart docker-compose-app.service"
    ;;

  # OS automatic update scheduling
  os-updates)
    shift
    os_updates_cmd "$@"
    ;;

  # Offline/Air-Gap commands for environments without internet access
  offline)
    offline_download() {
      local version="$1"
      local start_dir="$(pwd)"

      if [ -z "$version" ]; then
        echo "Usage: cli.sh offline download <version>"
        echo ""
        echo "Build a complete offline bundle with Docker images."
        echo "Example: cli.sh offline download 0.8.4-rc191"
        return 1
      fi

      local config_bundle="calltelemetry-bundle-${version}.tar.gz"
      local bundle_dir="calltelemetry-offline-${version}"
      local bundle_name="calltelemetry-offline-${version}.tar.gz"

      echo "=== Creating Offline Bundle (with Docker Images) ==="
      echo "Version: $version"
      echo "Output: $bundle_name"
      echo ""

      # Step 1: Download pre-built config bundle from GCS
      echo "Step 1: Downloading pre-built config bundle..."
      local bundle_url="${GCS_BUNDLE_BASE_URL}/${version}/${config_bundle}"

      if command -v wget >/dev/null 2>&1 && wget -q --show-progress "$bundle_url" -O "$config_bundle" 2>&1; then
        :
      elif command -v curl >/dev/null 2>&1 && curl -fL --progress-bar "$bundle_url" -o "$config_bundle"; then
        :
      else
        echo ""
        log_fail "ERROR: Failed to download config bundle for version $version"
        echo "URL: $bundle_url"
        echo ""
        echo "Make sure this version exists. Check:"
        echo "  https://github.com/calltelemetry/calltelemetry/releases"
        rm -f "$config_bundle"
        return 1
      fi
      log_ok "Config bundle downloaded"
      echo ""

      # Step 2: Extract config bundle
      echo "Step 2: Extracting config bundle..."
      rm -rf "$bundle_dir"
      mkdir -p "$bundle_dir"
      extract_tarball "$config_bundle" "$bundle_dir" --strip-components=1
      sanitize_metadata_artifacts "$bundle_dir"
      rm -f "$config_bundle"
      log_ok "Config bundle extracted"
      echo ""

      # Step 3: Extract image list and pull images
      echo "Step 3: Pulling Docker images..."
      cd "$bundle_dir" || return 1

      if [ ! -f "docker-compose.yml" ]; then
        log_fail "ERROR: docker-compose.yml not found in bundle"
        cd "$start_dir"
        rm -rf "$bundle_dir"
        return 1
      fi

      local images
      if [ -f "image-digests.tsv" ]; then
        # image-digests.tsv is the authoritative offline image set —
        # re-rendering compose with a hard-coded profile list duplicates
        # release knowledge and silently misses images when a new optional
        # profile or required env var is added upstream.
        images=$(awk -F '\t' 'NF >= 2 && $1 !~ /^#/ { print $1 }' image-digests.tsv | sort -u)
      else
        images=$(grep -E '^\s*image:' docker-compose.yml | sed 's/.*image:[[:space:]]*["'\'']*\([^"'\'']*\)["'\'']*[[:space:]]*$/\1/' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sort -u)
      fi

      echo "Images to download:"
      echo "$images" | while read img; do [ -n "$img" ] && echo "  - $img"; done
      echo ""

      local pull_failed=false
      local image_count=0
      local digest
      local total_images=$(echo "$images" | wc -l | tr -d ' ')

      for img in $images; do
        [ -z "$img" ] && continue
        image_count=$((image_count + 1))
        printf "[%s/%s] " "$image_count" "$total_images"
        if [ -f "image-digests.tsv" ]; then
          digest=$(awk -F '\t' -v image="$img" '$1 == image { print $2; exit }' image-digests.tsv)
          if [ -z "$digest" ]; then
            log_fail "ERROR: image-digests.tsv is missing a digest for $img"
            cd "$start_dir"
            rm -rf "$bundle_dir"
            return 1
          fi
          if ! _pull_image_at_digest "$img" "$digest"; then
            log_fail "ERROR: Failed to pull $img@$digest"
            cd "$start_dir"
            rm -rf "$bundle_dir"
            return 1
          fi
        elif ! pull_image_quiet "$img"; then
          log_warn "Warning: Failed to pull $img"
          pull_failed=true
        fi
      done

      if [ "$pull_failed" = true ]; then
        echo ""
        log_warn "Warning: Some images failed to pull. Bundle may be incomplete."
      fi

      # Step 4: Save Docker images to tar
      echo ""
      echo "Step 4: Saving Docker images to images.tar..."
      # shellcheck disable=SC2086
      if docker save $images -o images.tar; then
        log_ok "Images saved: $(du -h images.tar | cut -f1)"
      else
        log_fail "ERROR: Failed to save Docker images"
        cd "$start_dir"
        rm -rf "$bundle_dir"
        return 1
      fi

      # Step 5: Create final bundle
      echo ""
      echo "Step 5: Creating final bundle archive..."
      cd "$start_dir"
      tar -czf "$bundle_name" "$bundle_dir"
      rm -rf "$bundle_dir"

      echo ""
      echo "=== Offline Bundle Created Successfully ==="
      echo "File: $bundle_name"
      echo "Size: $(du -h "$bundle_name" | cut -f1)"
      echo ""
      echo "Contents:"
      echo "  - Configuration files (cli.sh, docker-compose.yml, etc.)"
      echo "  - Docker images (images.tar)"
      echo ""
      echo "Transfer this file to your air-gapped system and run:"
      echo "  tar -xzf $bundle_name"
      echo "  cd $bundle_dir"
      echo "  ./cli.sh offline apply ../$bundle_name"
    }

    offline_apply() {
      local bundle_file="$1"

      if [ -z "$bundle_file" ]; then
        echo "Usage: cli.sh offline apply <bundle.tar.gz>"
        echo ""
        echo "Apply an offline bundle to this system."
        return 1
      fi

      if [ ! -f "$bundle_file" ]; then
        echo "Error: Bundle file not found: $bundle_file"
        return 1
      fi

      require_root "offline apply" || return 1

      echo "=== Applying Offline Bundle ==="
      echo "Bundle: $bundle_file"
      echo ""

      # Create temp extraction directory
      local extract_dir="offline-extract-$$"
      mkdir -p "$extract_dir"

      echo "Extracting bundle..."
      extract_tarball "$bundle_file" "$extract_dir"
      sanitize_metadata_artifacts "$extract_dir"

      # Find the inner directory (bundle creates a subdirectory)
      local inner_dir=$(find "$extract_dir" -maxdepth 1 -type d -name "offline-bundle-*" | head -1)
      if [ -z "$inner_dir" ]; then
        inner_dir="$extract_dir"
      fi

      echo "Loading Docker images (this may take a while)..."
      if [ -f "$inner_dir/images.tar" ]; then
        docker load -i "$inner_dir/images.tar"
        echo "Docker images loaded."
      else
        echo "Warning: images.tar not found in bundle"
      fi

      echo ""
      echo "Backing up current configuration..."
      local timestamp=$(date +%Y%m%d-%H%M%S)
      [ -f docker-compose.yml ] && cp docker-compose.yml "$BACKUP_DIR/docker-compose-$timestamp.yml"
      [ -f Caddyfile ] && cp Caddyfile "$BACKUP_DIR/Caddyfile-$timestamp"

      echo "Installing configuration files..."
      [ -f "$inner_dir/docker-compose.yml" ] && cp "$inner_dir/docker-compose.yml" ./docker-compose.yml && echo "  - docker-compose.yml"
      [ -f "$inner_dir/Caddyfile" ] && cp "$inner_dir/Caddyfile" ./Caddyfile && echo "  - Caddyfile"
      [ -f "$inner_dir/cli.sh" ] && cp "$inner_dir/cli.sh" ./cli.sh && chmod +x ./cli.sh && echo "  - cli.sh"
      [ -f "$inner_dir/nats.conf" ] && cp "$inner_dir/nats.conf" ./nats.conf && echo "  - nats.conf"

      # Install prometheus config if present
      if [ -f "$inner_dir/prometheus/prometheus.yml" ]; then
        mkdir -p prometheus
        cp "$inner_dir/prometheus/prometheus.yml" ./prometheus/prometheus.yml
        echo "  - prometheus/prometheus.yml"
      fi

      # Install grafana configs if present
      if [ -d "$inner_dir/grafana" ]; then
        mkdir -p grafana/provisioning/datasources grafana/provisioning/dashboards grafana/dashboards
        [ -f "$inner_dir/grafana/provisioning/datasources/calltelemetry.yml" ] && cp "$inner_dir/grafana/provisioning/datasources/calltelemetry.yml" ./grafana/provisioning/datasources/
        [ -f "$inner_dir/grafana/provisioning/dashboards/calltelemetry.yaml" ] && cp "$inner_dir/grafana/provisioning/dashboards/calltelemetry.yaml" ./grafana/provisioning/dashboards/
        sanitize_grafana_assets ./grafana/provisioning ./grafana/dashboards
        echo "  - grafana configs"
      fi

      # Install otel-collector config if present
      if [ -f "$inner_dir/otel-collector/otel-collector-config.yaml" ]; then
        mkdir -p otel-collector
        [ -d "./otel-collector/otel-collector-config.yaml" ] && rm -rf "./otel-collector/otel-collector-config.yaml"
        cp "$inner_dir/otel-collector/otel-collector-config.yaml" ./otel-collector/otel-collector-config.yaml
        echo "  - otel-collector-config.yaml"
      fi

      # Install Tempo config if present
      if [ -f "$inner_dir/tempo/tempo.yaml" ]; then
        mkdir -p tempo
        [ -d "./tempo/tempo.yaml" ] && rm -rf "./tempo/tempo.yaml"
        cp "$inner_dir/tempo/tempo.yaml" ./tempo/tempo.yaml
        echo "  - tempo/tempo.yaml"
      fi

      # Install Loki config if present
      if [ -f "$inner_dir/loki/loki.yaml" ]; then
        mkdir -p loki
        # Docker may have created loki.yaml as a directory — remove it first
        [ -d "./loki/loki.yaml" ] && rm -rf "./loki/loki.yaml"
        cp "$inner_dir/loki/loki.yaml" ./loki/loki.yaml
        echo "  - loki/loki.yaml"
      fi

      # Install Alloy config if present
      if [ -f "$inner_dir/alloy/config.alloy" ]; then
        mkdir -p alloy
        [ -d "./alloy/config.alloy" ] && rm -rf "./alloy/config.alloy"
        cp "$inner_dir/alloy/config.alloy" ./alloy/config.alloy
        echo "  - alloy/config.alloy"
      fi

      # Cleanup extraction directory
      rm -rf "$extract_dir"

      echo ""
      echo "Restarting services..."
      fix_systemd_service_if_needed
      fix_systemd_compose_files
      if ! restart_service "offline apply"; then
        log_fail "Service restart failed after offline bundle apply."
        echo "   Images are loaded but services may not be running."
        echo "   Retry with: systemctl restart docker-compose-app.service"
        return 1
      fi

      echo ""
      echo "=== Offline Bundle Applied ==="
      echo "Verifying containers..."
      sleep 5
      $DOCKER_COMPOSE_CMD $(get_compose_files) ps

      echo ""
      echo "Check status with: ./cli.sh status"
    }

    offline_list() {
      echo "=== Images in docker-compose.yml ==="
      if [ ! -f docker-compose.yml ]; then
        echo "Error: docker-compose.yml not found in current directory"
        return 1
      fi

      local images=$(grep -E '^\s*image:' docker-compose.yml | sed 's/.*image:[[:space:]]*["'\'']*\([^"'\'']*\)["'\'']*[[:space:]]*$/\1/' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

      echo ""
      for img in $images; do
        [ -z "$img" ] && continue
        # Check if image exists locally
        if docker image inspect "$img" >/dev/null 2>&1; then
          local size=$(docker image inspect "$img" --format '{{.Size}}' | awk '{printf "%.1f MB", $1/1024/1024}')
          echo "  ✓ $img ($size)"
        else
          echo "  ✗ $img (not downloaded)"
        fi
      done
      echo ""
      echo "Total images: $(echo "$images" | grep -c .)"
    }

    # Fetch pre-built bundle from GCS (no Docker images, just configs)
    offline_fetch() {
      local version="$1"

      if [ -z "$version" ]; then
        echo "Usage: cli.sh offline fetch <version>"
        echo ""
        echo "Download a pre-built config bundle from cloud storage."
        echo "This bundle contains configs only (no Docker images)."
        echo ""
        echo "Example: cli.sh offline fetch 0.8.4-rc191"
        return 1
      fi

      local bundle_url="${GCS_BUNDLE_BASE_URL}/${version}/calltelemetry-bundle-${version}.tar.gz"
      local checksum_url="${GCS_BUNDLE_BASE_URL}/${version}/calltelemetry-bundle-${version}.tar.gz.sha256"
      local bundle_file="calltelemetry-bundle-${version}.tar.gz"

      echo "=== Fetching Pre-built Bundle ==="
      echo "Version: $version"
      echo "URL: $bundle_url"
      echo ""

      # Download bundle
      echo "Downloading bundle..."
      if command -v wget >/dev/null 2>&1; then
        if ! wget -q --show-progress "$bundle_url" -O "$bundle_file" 2>&1; then
          echo ""
          log_fail "ERROR: Failed to download bundle for version $version"
          echo ""
          echo "The version may not exist or network error occurred."
          echo "Check available versions at: https://github.com/calltelemetry/calltelemetry/releases"
          rm -f "$bundle_file"
          return 1
        fi
      elif command -v curl >/dev/null 2>&1; then
        if ! curl -fL --progress-bar "$bundle_url" -o "$bundle_file"; then
          echo ""
          log_fail "ERROR: Failed to download bundle for version $version"
          echo ""
          echo "The version may not exist or network error occurred."
          rm -f "$bundle_file"
          return 1
        fi
      else
        echo "Error: Neither wget nor curl is available"
        return 1
      fi

      # Download and verify checksum
      echo ""
      echo "Verifying checksum..."
      local checksum_file="${bundle_file}.sha256"
      if command -v wget >/dev/null 2>&1; then
        wget -q "$checksum_url" -O "$checksum_file" 2>/dev/null
      else
        curl -sfL "$checksum_url" -o "$checksum_file" 2>/dev/null
      fi

      if [ -f "$checksum_file" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
          if sha256sum -c "$checksum_file" >/dev/null 2>&1; then
            log_ok "Checksum verified"
          else
            log_warn "Checksum mismatch - file may be corrupted"
          fi
        else
          echo "ℹ️  sha256sum not available, skipping verification"
        fi
        rm -f "$checksum_file"
      fi

      echo ""
      echo "=== Bundle Downloaded ==="
      echo "File: $bundle_file"
      echo "Size: $(du -h "$bundle_file" | cut -f1)"
      echo ""
      echo "To apply this bundle:"
      echo "  ./cli.sh offline apply $bundle_file"
      echo ""
      echo "Note: This bundle contains configs only."
      echo "Docker images will be pulled when you run 'offline apply'."
    }

    case "$2" in
      download)
        offline_download "$3"
        ;;
      fetch)
        offline_fetch "$3"
        ;;
      apply)
        offline_apply "$3"
        ;;
      list)
        offline_list
        ;;
      ""|help)
        echo "Usage: cli.sh offline <command>"
        echo ""
        echo "Air-gapped/offline installation commands:"
        echo ""
        echo "  fetch <version>        Download pre-built config bundle from cloud"
        echo "                         Fast - configs only, no Docker images"
        echo "                         Example: cli.sh offline fetch 0.8.4-rc191"
        echo ""
        echo "  download [version]     Build full offline bundle with Docker images"
        echo "                         Slow - includes all images for air-gapped install"
        echo "                         Default version: latest"
        echo ""
        echo "  apply <bundle.tar.gz>  Apply an offline bundle to this system"
        echo "                         Loads images (if present) and installs configs"
        echo ""
        echo "  list                   List images in current docker-compose.yml"
        echo "                         Shows which are downloaded locally"
        echo ""
        echo "Workflow (with internet on target):"
        echo "  1. ./cli.sh offline fetch 0.8.4-rc191"
        echo "  2. ./cli.sh offline apply calltelemetry-bundle-0.8.4-rc191.tar.gz"
        echo ""
        echo "Workflow (air-gapped target):"
        echo "  1. On internet machine: ./cli.sh offline download 0.8.4-rc191"
        echo "  2. Transfer bundle via USB/SFTP"
        echo "  3. On target: ./cli.sh offline apply calltelemetry-offline-*.tar.gz"
        ;;
      *)
        echo "Unknown offline command: $2"
        echo "Run 'cli.sh offline' for available commands."
        ;;
    esac
    ;;

  docker)
    case "$2" in
      prune)
        purge_docker
        ;;
      network)
        echo "Running: docker network inspect \$(docker network ls -q -f name=ct)"
        echo ""
        docker network inspect $(docker network ls -q -f name=ct) 2>/dev/null || echo "Network 'ct' not found"
        ;;
      ""|status)
        echo "=== Docker Status ==="
        echo ""
        echo "Containers:"
        $DOCKER_COMPOSE_CMD $(get_compose_files) ps
        echo ""
        echo "Images:"
        docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep -E "calltelemetry|REPOSITORY"
        echo ""
        echo "Networks:"
        docker network ls --filter name=ct --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"
        echo ""
        echo "Commands: cli.sh docker <prune|network|status>"
        ;;
      *)
        echo "Unknown docker command: $2"
        echo ""
        echo "Usage: cli.sh docker <command>"
        echo ""
        echo "Commands:"
        echo "  status    Show Docker status (default)"
        echo "  network   Show detailed network configuration"
        echo "  prune     Remove unused Docker resources"
        ;;
    esac
    ;;

  # Diagnostic commands
  diag)
    case "$2" in
      tesla)
        ip_mode="$3"
        url="$4"

        if [ -z "$ip_mode" ] || [ -z "$url" ]; then
          echo "Usage: cli.sh diag tesla <ipv4|ipv6> <url>"
          echo ""
          echo "Test TCP and HTTP connectivity to an endpoint using Tesla HTTP client."
          echo ""
          echo "Options:"
          echo "  ipv4    Test IPv4 connection"
          echo "  ipv6    Test IPv6 connection"
          echo ""
          echo "Examples:"
          echo "  cli.sh diag tesla ipv6 http://[dead:beef:cafe:1::11]:8090"
          echo "  cli.sh diag tesla ipv4 http://192.168.1.100:8090"
          return 1
        fi

        if [[ ! "$ip_mode" =~ ^(ipv4|ipv6)$ ]]; then
          echo "Error: Invalid mode '$ip_mode'. Use ipv4 or ipv6."
          return 1
        fi

        # Parse URL to extract host and port
        host port
        if [[ "$url" =~ http://\[([^\]]+)\]:([0-9]+) ]]; then
          # IPv6 format: http://[host]:port
          host="${BASH_REMATCH[1]}"
          port="${BASH_REMATCH[2]}"
        elif [[ "$url" =~ http://([^:/]+):([0-9]+) ]]; then
          # IPv4/hostname format: http://host:port
          host="${BASH_REMATCH[1]}"
          port="${BASH_REMATCH[2]}"
        else
          echo "Error: Could not parse URL. Expected format:"
          echo "  http://[ipv6-address]:port"
          echo "  http://ipv4-address:port"
          return 1
        fi

        echo "=== Tesla Connectivity Test ==="
        echo ""
        echo "URL:  $url"
        echo "Host: $host"
        echo "Port: $port"
        echo "Mode: $ip_mode"
        echo ""

        # Get current image tag
        image_tag=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "calltelemetry/web" | head -1)
        if [ -z "$image_tag" ]; then
          image_tag="calltelemetry/web:latest"
        fi

        echo "Using image: $image_tag"
        echo ""

        # Build Elixir code based on mode
        elixir_code="Application.ensure_all_started(:hackney)"

        if [ "$ip_mode" = "ipv4" ]; then
          elixir_code="$elixir_code

IO.puts(\"=== IPv4 TCP Connection Test ===\")
case :gen_tcp.connect(~c\"$host\", $port, [:inet], 5000) do
  {:ok, sock} ->
    :gen_tcp.close(sock)
    IO.puts(\"TCP CONNECT (IPv4): SUCCESS\")
  {:error, e} ->
    IO.puts(\"TCP CONNECT (IPv4): FAILED - #{inspect(e)}\")
end

IO.puts(\"\")
IO.puts(\"=== IPv4 HTTP POST Test ===\")
case Tesla.post(\"http://$host:$port/cisco_xcc\", \"\") do
  {:ok, resp} -> IO.puts(\"HTTP POST (IPv4): SUCCESS - status #{resp.status}\")
  {:error, e} -> IO.puts(\"HTTP POST (IPv4): FAILED - #{inspect(e)}\")
end
"
        elif [ "$ip_mode" = "ipv6" ]; then
          # Convert IPv6 to Erlang tuple format
          ipv6_tuple=$(echo "$host" | python3 -c "
import sys
import ipaddress
addr = ipaddress.ip_address(sys.stdin.read().strip())
parts = [hex(int(x, 16)) for x in addr.exploded.split(':')]
print('{' + ','.join(parts) + '}')
" 2>/dev/null || echo "")

          if [ -z "$ipv6_tuple" ]; then
            echo "Error: Could not parse IPv6 address. Ensure python3 is installed."
            return 1
          fi

          elixir_code="$elixir_code

IO.puts(\"=== IPv6 TCP Connection Test ===\")
case :gen_tcp.connect($ipv6_tuple, $port, [:inet6], 5000) do
  {:ok, sock} ->
    :gen_tcp.close(sock)
    IO.puts(\"TCP CONNECT (IPv6): SUCCESS\")
  {:error, e} ->
    IO.puts(\"TCP CONNECT (IPv6): FAILED - #{inspect(e)}\")
end

IO.puts(\"\")
IO.puts(\"=== IPv6 HTTP POST Test ===\")
case Tesla.post(\"http://[$host]:$port/cisco_xcc\", \"\") do
  {:ok, resp} -> IO.puts(\"HTTP POST (IPv6): SUCCESS - status #{resp.status}\")
  {:error, e} -> IO.puts(\"HTTP POST (IPv6): FAILED - #{inspect(e)}\")
end
"
        fi

        echo "Running connectivity test..."
        echo ""
        docker run --rm --network host "$image_tag" /home/app/onprem/bin/onprem eval "$elixir_code"
        ;;
      raw_tcp)
        ip_mode="$3"
        url="$4"

        if [ -z "$ip_mode" ] || [ -z "$url" ]; then
          echo "Usage: cli.sh diag raw_tcp <ipv4|ipv6> <url>"
          echo ""
          echo "Test raw TCP socket connectivity to an endpoint."
          echo ""
          echo "Options:"
          echo "  ipv4    Test IPv4 connection"
          echo "  ipv6    Test IPv6 connection"
          echo ""
          echo "Examples:"
          echo "  cli.sh diag raw_tcp ipv6 http://[dead:beef:cafe:1::11]:8090"
          echo "  cli.sh diag raw_tcp ipv4 http://192.168.1.100:8090"
          return 1
        fi

        if [[ ! "$ip_mode" =~ ^(ipv4|ipv6)$ ]]; then
          echo "Error: Invalid mode '$ip_mode'. Use ipv4 or ipv6."
          return 1
        fi

        # Parse URL to extract host and port
        host port
        if [[ "$url" =~ http://\[([^\]]+)\]:([0-9]+) ]]; then
          host="${BASH_REMATCH[1]}"
          port="${BASH_REMATCH[2]}"
        elif [[ "$url" =~ http://([^:/]+):([0-9]+) ]]; then
          host="${BASH_REMATCH[1]}"
          port="${BASH_REMATCH[2]}"
        else
          echo "Error: Could not parse URL. Expected format:"
          echo "  http://[ipv6-address]:port"
          echo "  http://ipv4-address:port"
          return 1
        fi

        echo "=== Raw TCP Connectivity Test ==="
        echo ""
        echo "URL:  $url"
        echo "Host: $host"
        echo "Port: $port"
        echo "Mode: $ip_mode"
        echo ""

        # Get current image tag
        image_tag=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "calltelemetry/web" | head -1)
        if [ -z "$image_tag" ]; then
          image_tag="calltelemetry/web:latest"
        fi

        echo "Using image: $image_tag"
        echo ""

        elixir_code=""

        if [ "$ip_mode" = "ipv4" ]; then
          elixir_code="
IO.puts(\"=== IPv4 TCP Connection Test ===\")
case :gen_tcp.connect(~c\"$host\", $port, [:inet], 5000) do
  {:ok, sock} ->
    :gen_tcp.close(sock)
    IO.puts(\"TCP CONNECT (IPv4): SUCCESS\")
  {:error, e} ->
    IO.puts(\"TCP CONNECT (IPv4): FAILED - #{inspect(e)}\")
end
"
        elif [ "$ip_mode" = "ipv6" ]; then
          ipv6_tuple=$(echo "$host" | python3 -c "
import sys
import ipaddress
addr = ipaddress.ip_address(sys.stdin.read().strip())
parts = [hex(int(x, 16)) for x in addr.exploded.split(':')]
print('{' + ','.join(parts) + '}')
" 2>/dev/null || echo "")

          if [ -z "$ipv6_tuple" ]; then
            echo "Error: Could not parse IPv6 address. Ensure python3 is installed."
            return 1
          fi

          elixir_code="
IO.puts(\"=== IPv6 TCP Connection Test ===\")
case :gen_tcp.connect($ipv6_tuple, $port, [:inet6], 5000) do
  {:ok, sock} ->
    :gen_tcp.close(sock)
    IO.puts(\"TCP CONNECT (IPv6): SUCCESS\")
  {:error, e} ->
    IO.puts(\"TCP CONNECT (IPv6): FAILED - #{inspect(e)}\")
end
"
        fi

        echo "Running connectivity test..."
        echo ""
        docker run --rm --network host "$image_tag" /home/app/onprem/bin/onprem eval "$elixir_code"
        ;;
      capture)
        duration="$3"
        filter="$4"
        output_file="$5"

        if [ -z "$duration" ]; then
          echo "Usage: cli.sh diag capture <duration> [filter] [output.pcap]"
          echo ""
          echo "Capture network packets using tcpdump for the specified duration."
          echo ""
          echo "Arguments:"
          echo "  duration     Capture duration in seconds (required)"
          echo "  filter       Optional tcpdump filter expression (e.g., 'port 5060')"
          echo "  output.pcap  Optional output file (default: capture-TIMESTAMP.pcap)"
          echo ""
          echo "Examples:"
          echo "  cli.sh diag capture 30"
          echo "  cli.sh diag capture 60 'port 5060'"
          echo "  cli.sh diag capture 120 'port 5060 or port 5061' sip-traffic.pcap"
          echo "  cli.sh diag capture 30 'host 192.168.1.100' debug.pcap"
          return 1
        fi

        # Validate duration is a positive integer
        if ! [[ "$duration" =~ ^[0-9]+$ ]] || [ "$duration" -eq 0 ]; then
          echo "Error: Duration must be a positive integer (seconds)."
          return 1
        fi

        # Set default output file if not provided
        if [ -z "$output_file" ]; then
          output_file="capture-$(date '+%Y%m%d-%H%M%S').pcap"
        fi

        # Ensure output file has .pcap extension
        if [[ "$output_file" != *.pcap ]]; then
          output_file="${output_file}.pcap"
        fi

        # Check if tcpdump is available
        if ! command -v tcpdump &> /dev/null; then
          echo "Error: tcpdump is not installed."
          echo "Install with: sudo apt-get install tcpdump"
          return 1
        fi

        echo "=== Packet Capture ==="
        echo ""
        echo "Duration:    ${duration} seconds"
        echo "Filter:      ${filter:-none}"
        echo "Output file: ${output_file}"
        echo ""

        # Build tcpdump command
        tcpdump_cmd="sudo tcpdump -w '$output_file'"
        if [ -n "$filter" ]; then
          tcpdump_cmd="$tcpdump_cmd $filter"
        fi

        echo "Starting capture..."
        echo "Command: $tcpdump_cmd"
        echo ""

        # Run tcpdump with timeout
        if [ -n "$filter" ]; then
          sudo timeout "$duration" tcpdump -w "$output_file" $filter 2>&1 || true
        else
          sudo timeout "$duration" tcpdump -w "$output_file" 2>&1 || true
        fi

        echo ""
        if [ -f "$output_file" ]; then
          file_size=$(ls -lh "$output_file" | awk '{print $5}')
          packet_count=$(sudo tcpdump -r "$output_file" 2>/dev/null | wc -l)
          echo "Capture complete!"
          echo "  File:    $output_file"
          echo "  Size:    $file_size"
          echo "  Packets: $packet_count"
          echo ""
          echo "To analyze: tcpdump -r $output_file"
          echo "Or copy to your machine and open with Wireshark."
        else
          echo "Warning: No packets captured or capture failed."
        fi
        ;;
      database|db)
        echo "=== Database Diagnostics ==="
        echo ""

        echo "--- 1. Container CPU/Memory Usage ---"
        docker stats --no-stream
        echo ""

        echo "--- 2. Active Running Queries (consuming CPU now) ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state, wait_event_type, wait_event FROM pg_stat_activity WHERE state <> 'idle' AND query NOT ILIKE '%pg_stat_activity%' ORDER BY duration DESC LIMIT 20;"
        echo ""

        echo "--- 3. All Connections & Long-Running Queries ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT pid, usename, application_name, client_addr, now() - query_start AS duration, state, LEFT(query, 100) as query_preview FROM pg_stat_activity WHERE query_start IS NOT NULL ORDER BY query_start ASC LIMIT 20;"
        echo ""

        echo "--- 4. Blocked Queries (lock contention) ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT blocked_locks.pid AS blocked_pid, blocked_activity.usename AS blocked_user, blocking_locks.pid AS blocking_pid, blocking_activity.usename AS blocking_user, LEFT(blocked_activity.query,50) AS blocked_stmt, LEFT(blocking_activity.query,50) AS blocking_stmt FROM pg_catalog.pg_locks blocked_locks JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid JOIN pg_catalog.pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation AND blocking_locks.pid <> blocked_locks.pid JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid WHERE NOT blocked_locks.granted;"
        echo ""

        echo "--- 5. Tables with High Sequential Scans (missing indexes) ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT relname, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch, n_tup_ins, n_tup_upd, n_tup_del FROM pg_stat_user_tables ORDER BY seq_scan DESC LIMIT 15;"
        echo ""

        echo "--- 6. Connection Count by State ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT count(*) as total_connections, state, usename FROM pg_stat_activity GROUP BY state, usename ORDER BY count(*) DESC;"
        echo ""

        echo "--- 7. Dead Tuples (needs vacuum) ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT schemaname, relname, n_dead_tup, n_live_tup, last_vacuum, last_autovacuum FROM pg_stat_user_tables WHERE n_dead_tup > 1000 ORDER BY n_dead_tup DESC LIMIT 10;"
        echo ""

        echo "--- 8. Active MV Refreshes, Index Builds, Vacuum, Analyze ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT pid, now() - query_start AS duration, state, wait_event_type, LEFT(query, 80) as operation FROM pg_stat_activity WHERE query ILIKE '%REFRESH MATERIALIZED%' OR query ILIKE '%CREATE INDEX%' OR query ILIKE '%REINDEX%' OR query ILIKE '%VACUUM%' OR query ILIKE '%ANALYZE%';"
        echo ""

        echo "--- 9. Index Creation Progress ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT p.pid, p.datname, p.command, p.phase, p.blocks_total, p.blocks_done, ROUND(100.0 * p.blocks_done / NULLIF(p.blocks_total, 0), 2) AS pct_done, LEFT(a.query, 60) as query FROM pg_stat_progress_create_index p JOIN pg_stat_activity a ON p.pid = a.pid;"
        echo ""

        echo "--- 10. Vacuum Progress ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT p.pid, p.datname, p.relid::regclass AS table_name, p.phase, p.heap_blks_total, p.heap_blks_scanned, ROUND(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 2) AS pct_done FROM pg_stat_progress_vacuum p;"
        echo ""

        echo "--- 11. List All Materialized Views ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT matviewname, hasindexes, ispopulated FROM pg_matviews ORDER BY matviewname;"
        echo ""

        echo "--- 12. Autovacuum Workers Active ---"
        docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -c "SELECT pid, datname, relid::regclass AS table_name, phase, heap_blks_total, heap_blks_scanned, index_vacuum_count FROM pg_stat_progress_vacuum WHERE datname IS NOT NULL;"
        echo ""

        echo "=== Database Diagnostics Complete ==="
        ;;
      db-watch|dbwatch)
        echo "=== Live Database Activity Monitor ==="
        echo "Refreshing every 2 seconds. Press Ctrl+C to stop."
        echo ""
        watch -n 2 -d -- docker exec calltelemetry-db-1 env "PGPASSWORD=$(_db_password)" psql -U calltelemetry -d calltelemetry_prod -xc \
          "SELECT pid, state, wait_event_type, now() - query_start AS duration, left(query, 120) AS query
           FROM pg_stat_activity
           WHERE datname = 'calltelemetry_prod'
             AND state != 'idle'
             AND query NOT ILIKE '%pg_stat_activity%'
           ORDER BY query_start;"
        ;;
      network)
        echo "=== Network Diagnostics ==="
        echo ""

        # Get primary interface (the one with default route)
        PRIMARY_IF=$(ip route | grep default | head -1 | awk '{print $5}')
        echo "--- Primary Interface: $PRIMARY_IF ---"

        # IP Address and Subnet
        echo ""
        echo "--- IP Address & Subnet ---"
        ip -4 addr show "$PRIMARY_IF" 2>/dev/null | grep inet | awk '{print "  IPv4: " $2}'
        ip -6 addr show "$PRIMARY_IF" 2>/dev/null | grep inet6 | grep -v fe80 | awk '{print "  IPv6: " $2}'

        # Default Gateway
        echo ""
        echo "--- Default Gateway ---"
        DEFAULT_GW=$(ip route | grep default | head -1 | awk '{print $3}')
        echo "  Gateway: $DEFAULT_GW"

        # DNS Servers
        echo ""
        echo "--- DNS Servers ---"
        if [ -f /etc/resolv.conf ]; then
          DNS_SERVERS=$(grep "^nameserver" /etc/resolv.conf | awk '{print $2}')
          PRIMARY_DNS=$(echo "$DNS_SERVERS" | head -1)
          SECONDARY_DNS=$(echo "$DNS_SERVERS" | sed -n '2p')
          echo "$DNS_SERVERS" | while read dns; do echo "  $dns"; done
        else
          echo "  Unable to read /etc/resolv.conf"
        fi

        # Ping Gateway
        echo ""
        echo "--- Ping Gateway ($DEFAULT_GW) ---"
        if ping -c 3 -W 2 "$DEFAULT_GW" >/dev/null 2>&1; then
          echo "  Result: SUCCESS"
          ping -c 3 -W 2 "$DEFAULT_GW" 2>&1 | tail -1
        else
          echo "  Result: FAILED"
        fi

        # Ping DNS Servers
        echo ""
        echo "--- Ping DNS Servers ---"
        if [ -n "$PRIMARY_DNS" ]; then
          echo "  Primary DNS ($PRIMARY_DNS):"
          if ping -c 2 -W 2 "$PRIMARY_DNS" >/dev/null 2>&1; then
            echo "    Result: SUCCESS"
          else
            echo "    Result: FAILED"
          fi
        fi
        if [ -n "$SECONDARY_DNS" ]; then
          echo "  Secondary DNS ($SECONDARY_DNS):"
          if ping -c 2 -W 2 "$SECONDARY_DNS" >/dev/null 2>&1; then
            echo "    Result: SUCCESS"
          else
            echo "    Result: FAILED"
          fi
        fi

        # DNS Resolution Tests
        echo ""
        echo "--- DNS Resolution (www.google.com) ---"
        if [ -n "$PRIMARY_DNS" ]; then
          echo "  Query Primary DNS ($PRIMARY_DNS):"
          if command -v nslookup >/dev/null 2>&1; then
            nslookup www.google.com "$PRIMARY_DNS" 2>&1 | grep -A1 "Name:" | head -2 | sed 's/^/    /'
          elif command -v dig >/dev/null 2>&1; then
            dig +short www.google.com @"$PRIMARY_DNS" 2>&1 | head -2 | sed 's/^/    /'
          elif command -v host >/dev/null 2>&1; then
            host www.google.com "$PRIMARY_DNS" 2>&1 | head -2 | sed 's/^/    /'
          else
            echo "    No DNS tools available (nslookup/dig/host)"
          fi
        fi
        if [ -n "$SECONDARY_DNS" ]; then
          echo "  Query Secondary DNS ($SECONDARY_DNS):"
          if command -v nslookup >/dev/null 2>&1; then
            nslookup www.google.com "$SECONDARY_DNS" 2>&1 | grep -A1 "Name:" | head -2 | sed 's/^/    /'
          elif command -v dig >/dev/null 2>&1; then
            dig +short www.google.com @"$SECONDARY_DNS" 2>&1 | head -2 | sed 's/^/    /'
          elif command -v host >/dev/null 2>&1; then
            host www.google.com "$SECONDARY_DNS" 2>&1 | head -2 | sed 's/^/    /'
          else
            echo "    No DNS tools available (nslookup/dig/host)"
          fi
        fi

        # Ping www.google.com
        echo ""
        echo "--- Ping www.google.com ---"
        if ping -c 3 -W 2 www.google.com >/dev/null 2>&1; then
          echo "  Result: SUCCESS"
          ping -c 3 -W 2 www.google.com 2>&1 | tail -1
        else
          echo "  Result: FAILED"
        fi

        # Traceroute to 8.8.8.8
        echo ""
        echo "--- Traceroute to 8.8.8.8 ---"
        if command -v traceroute >/dev/null 2>&1; then
          traceroute -m 15 -w 2 8.8.8.8 2>&1
        elif command -v tracepath >/dev/null 2>&1; then
          tracepath -m 15 8.8.8.8 2>&1
        else
          echo "  No traceroute tool available (traceroute/tracepath)"
          echo "  Install with: sudo dnf install traceroute"
        fi

        # HTTPS connectivity test
        echo ""
        echo "--- HTTPS Connectivity Test (GCS) ---"
        TEST_URL="${GCS_BASE_URL}/cli.sh"
        echo "  URL: $TEST_URL"
        echo ""
        if command -v wget >/dev/null 2>&1; then
          WGET_OUTPUT=$(wget --timeout=10 --tries=1 -O /dev/null "$TEST_URL" 2>&1)
          WGET_EXIT=$?
          if [ $WGET_EXIT -eq 0 ]; then
            echo "  Result: SUCCESS"
            echo "$WGET_OUTPUT" | grep -E "(Length|saved|response)" | sed 's/^/  /'
          else
            echo "  Result: FAILED (exit code: $WGET_EXIT)"
            echo ""
            echo "  Error details:"
            echo "$WGET_OUTPUT" | sed 's/^/    /'
            echo ""
            echo "  Common causes:"
            case $WGET_EXIT in
              1) echo "    - Generic error (check output above)" ;;
              2) echo "    - Command line parse error" ;;
              3) echo "    - File I/O error" ;;
              4) echo "    - Network failure (DNS, connection refused, timeout)" ;;
              5)
                echo "    - SSL/TLS verification failure"
                echo ""
                echo "  SSL Certificate Issue Detected!"
                echo "  This often means a corporate proxy/firewall is intercepting HTTPS traffic."
                echo ""
                echo "  Checking certificate issuer..."
                CERT_ISSUER=$(echo | openssl s_client -connect storage.googleapis.com:443 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
                if [ -n "$CERT_ISSUER" ]; then
                  echo "    $CERT_ISSUER"
                  if echo "$CERT_ISSUER" | grep -qi "cisco\|umbrella\|zscaler\|palo alto\|fortinet\|fortigate\|bluecoat\|symantec\|mcafee\|websense"; then
                    echo ""
                    log_warn "Corporate proxy detected! The firewall is doing SSL inspection."
                    echo "  Solutions:"
                    echo "    1. Add the corporate CA certificate to /etc/pki/ca-trust/source/anchors/"
                    echo "       then run: sudo update-ca-trust"
                    echo "    2. Ask IT to whitelist storage.googleapis.com from SSL inspection"
                  fi
                fi
                ;;
              6) echo "    - Authentication required" ;;
              7) echo "    - Protocol error" ;;
              8) echo "    - Server error response" ;;
            esac
          fi
        elif command -v curl >/dev/null 2>&1; then
          CURL_OUTPUT=$(curl -sS --connect-timeout 10 -o /dev/null -w "%{http_code}" "$TEST_URL" 2>&1)
          CURL_EXIT=$?
          if [ $CURL_EXIT -eq 0 ] && [ "$CURL_OUTPUT" = "200" ]; then
            echo "  Result: SUCCESS (HTTP $CURL_OUTPUT)"
          else
            echo "  Result: FAILED"
            echo "  HTTP Code: $CURL_OUTPUT"
            echo "  Exit Code: $CURL_EXIT"
            # Get verbose output for debugging
            echo ""
            echo "  Error details:"
            curl -v --connect-timeout 10 "$TEST_URL" -o /dev/null 2>&1 | grep -E "(Could not|Failed|error|SSL|connect)" | sed 's/^/    /'
          fi
        else
          echo "  No HTTP client available (wget/curl)"
        fi

        echo ""
        echo "=== Network Diagnostics Complete ==="
        ;;
      service)
        echo "=== Service Diagnostics ==="
        echo ""

        SERVICE_FILE="/etc/systemd/system/docker-compose-app.service"

        # Print systemd service file
        echo "--- Systemd Service File ($SERVICE_FILE) ---"
        if [ -f "$SERVICE_FILE" ]; then
          cat "$SERVICE_FILE"
        else
          echo "  Service file not found!"
        fi
        echo ""

        # Get systemd service logs
        echo "--- Systemd Service Logs (Last 50 lines) ---"
        sudo journalctl -u docker-compose-app.service -n 50 --no-pager
        echo ""

        # Get Docker Compose logs for specific containers
        echo "--- Docker Container Logs ---"
        echo ""

        echo "=== Web Container (Last 50 lines) ==="
        $DOCKER_COMPOSE_CMD logs --tail=50 web 2>/dev/null || echo "  Web container logs not available"
        echo ""

        echo "=== Database Container (Last 50 lines) ==="
        $DOCKER_COMPOSE_CMD logs --tail=50 db 2>/dev/null || echo "  Database container logs not available"
        echo ""

        echo "=== NATS Container (Last 50 lines) ==="
        $DOCKER_COMPOSE_CMD logs --tail=50 nats 2>/dev/null || echo "  NATS container logs not available"
        echo ""

        echo "=== Caddy Container (Last 50 lines) ==="
        $DOCKER_COMPOSE_CMD logs --tail=50 caddy 2>/dev/null || echo "  Caddy container logs not available"
        echo ""

        echo "=== Service Diagnostics Complete ==="
        ;;
      ""|help)
        echo "Usage: cli.sh diag <command>"
        echo ""
        echo "Diagnostic commands:"
        echo "  network                    Run comprehensive network diagnostics"
        echo "  service                    Display systemd service and container logs"
        echo "  tesla <ipv4|ipv6> <url>    Test TCP + HTTP connectivity"
        echo "  raw_tcp <ipv4|ipv6> <url>  Test raw TCP socket only"
        echo "  capture <secs> [filter] [file]  Capture packets with tcpdump"
        echo "  database                   Run comprehensive database diagnostics"
        echo "  db-watch                   Live database activity monitor (refreshes every 2s)"
        echo ""
        echo "Examples:"
        echo "  cli.sh diag network"
        echo "  cli.sh diag service"
        echo "  cli.sh diag tesla ipv6 http://[dead:beef:cafe:1::11]:8090"
        echo "  cli.sh diag tesla ipv4 http://192.168.1.100:8090"
        echo "  cli.sh diag raw_tcp ipv6 http://[dead:beef:cafe:1::11]:8090"
        echo "  cli.sh diag raw_tcp ipv4 http://192.168.1.100:8090"
        echo "  cli.sh diag capture 30"
        echo "  cli.sh diag capture 60 'port 5060' sip.pcap"
        echo "  cli.sh diag database"
        ;;
      *)
        echo "Unknown diag command: $2"
        echo "Run 'cli.sh diag' for available commands."
        ;;
    esac
    ;;

  # Service lifecycle commands
  restart)
    echo "Restarting Call Telemetry services..."
    restart_service "cli restart"
    ;;
  stop)
    echo "Stopping Call Telemetry services..."
    systemctl stop docker-compose-app.service
    log_ok "Services stopped."
    ;;
  start)
    echo "Starting Call Telemetry services..."
    if ! ensure_postgres_password || ! ensure_grafana_password; then
      log_fail "Failed to ensure required secrets; aborting service start"
      exit 1
    fi
    ensure_bind_mount_files
    systemctl start docker-compose-app.service
    log_ok "Services started."
    ;;

  # Advanced commands
  build-appliance)
    ensure_ip_forward
    build_appliance
    ;;
  prep-cluster-node)
    prep_cluster_node
    ;;
  __test_wait_for_services)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      wait_for_services "${CT_CLI_TEST_WAIT_SUPPRESS_SUCCESS:-0}" "${CT_CLI_TEST_WAIT_SUPPRESS_PHASES:-0}" "${CT_CLI_TEST_WAIT_SUPPRESS_HEARTBEATS:-0}"
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_ensure_grafana_password)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      __test_ensure_grafana_password
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_check_cpu)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Runs check_cpu against the override in CT_CLI_TEST_CPU_COUNT and
      # exits with the function's return code. Test harness captures rc
      # and stdout/stderr.
      check_cpu
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_ensure_cpu_defaults)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Runs ensure_cpu_defaults against CT_CLI_TEST_CPU_COUNT and
      # writes to the ENV_FILE the test harness has prepared.
      ensure_cpu_defaults
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_detect_cpu_count)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Prints the detected count (or empty on failure) and exits with
      # the detector's return code.
      _detect_cpu_count
      rc=$?
      printf '%s' "${_LAST_CPU_COUNT:-}"
      exit $rc
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_preflight_summary)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Args: <force_upgrade:true|false> <had_warnings:0|1> [metric ...]
      # Exercises _update_preflight_summary so tests can assert the
      # "PASS · ..." vs "see warnings above" phrasing without driving
      # the full preflight pipeline. Extra positionals after the first
      # two are forwarded as metric tokens (e.g. "RAM 30GB", "6 vCPU").
      shift
      _update_preflight_summary "$@"
      exit 0
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_update_dispatch_verbose)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Simulates the top-level `update)` dispatcher's early verbose
      # parse. Echoes the resulting CLI_VERBOSE value so tests can
      # confirm --verbose / -v are honored *before* pre-update hooks run.
      shift
      for _arg in "$@"; do
        case "$_arg" in
          --verbose|-v) export CLI_VERBOSE=1 ;;
        esac
      done
      unset _arg
      printf '%s' "${CLI_VERBOSE:-}"
      exit 0
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_update_confirm_apply)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      shift
      TEMP_FILE="${TEMP_FILE:-/tmp/ct-cli-test-temp-file}"
      sleep() { :; }
      _update_confirm_apply "${1:-not installed}" "${2:-test-version}" "${3:-false}"
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_filter_status_logs)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      _status_filter_benign_log_noise
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_bundle_deploy_cli_update)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      shift
      extract_dir="${1:?extract_dir required}"
      CURRENT_SCRIPT_PATH="${2:?current cli path required}"
      INSTALL_DIR="$(dirname "$CURRENT_SCRIPT_PATH")"
      _bundle_deploy_configs "$extract_dir"
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_extract_images)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      shift
      extract_images "${1:?compose file required}"
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_format_bytes)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      shift
      _update_format_bytes "${1:-0}"
      exit 0
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_backup_compose)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Runs _update_backup_current_compose against the sandbox HOME the
      # harness has prepared. Stdout is "snapshot_ts=<ts>" so tests can
      # parse the chosen timestamp. Exit code reflects helper rc.
      _update_backup_current_compose
      rc=$?
      printf 'snapshot_ts=%s\n' "${_UPDATE_SNAPSHOT_TS:-}"
      exit $rc
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_prune_old_snapshots)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      shift
      _update_prune_old_snapshots "${1:-}"
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_list_snapshots)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      _update_list_snapshots
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_restore_snapshot)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Args: <ts> <with_env> <with_db>
      # Use with_db=1 only for the early validation paths (missing dump /
      # missing meta / mismatched meta_ts) — those return before the
      # docker-stop/replay path that needs a real db container.
      # Stub restart_service + fix_systemd_service_if_needed: the real
      # ones require root + systemd, which CI doesn't have. The helper's
      # success path still asserts they were reached (rc=0).
      restart_service() { return 0; }
      fix_systemd_service_if_needed() { return 0; }
      shift
      _update_restore_snapshot "${1:-}" "${2:-0}" "${3:-0}"
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_create_snapshot)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Args: <snapshot_ts> <yes|no|prompt>. Stubs the expensive pg_dump
      # path so tests can assert empty-DB fallback vs data-bearing abort
      # behavior without Docker.
      shift
      if [ -n "${CT_CLI_TEST_PROMPT_DB_BACKUP_RC:-}" ]; then
        _update_prompt_db_backup() { return "${CT_CLI_TEST_PROMPT_DB_BACKUP_RC}"; }
      fi
      if [ -n "${CT_CLI_TEST_SNAPSHOT_DB_RC:-}" ]; then
        _update_snapshot_db() { return "${CT_CLI_TEST_SNAPSHOT_DB_RC}"; }
      fi
      if [ -n "${CT_CLI_TEST_DB_HAS_APP_DATA_RC:-}" ]; then
        _update_db_has_application_data() { return "${CT_CLI_TEST_DB_HAS_APP_DATA_RC}"; }
      fi
      if [ -n "${CT_CLI_TEST_DB_HAS_APP_DATA_RC_SEQUENCE:-}" ]; then
        CT_CLI_TEST_DB_HAS_APP_DATA_RC_SEQUENCE_INDEX=1
        _update_db_has_application_data() {
          local rc
          rc=$(printf '%s\n' "$CT_CLI_TEST_DB_HAS_APP_DATA_RC_SEQUENCE" | cut -d, -f"$CT_CLI_TEST_DB_HAS_APP_DATA_RC_SEQUENCE_INDEX")
          [ -n "$rc" ] || rc=$(printf '%s\n' "$CT_CLI_TEST_DB_HAS_APP_DATA_RC_SEQUENCE" | awk -F, '{print $NF}')
          CT_CLI_TEST_DB_HAS_APP_DATA_RC_SEQUENCE_INDEX=$((CT_CLI_TEST_DB_HAS_APP_DATA_RC_SEQUENCE_INDEX + 1))
          return "$rc"
        }
      fi
      if [ -n "${CT_CLI_TEST_DOCKER_COMPOSE_CMD:-}" ]; then
        DOCKER_COMPOSE_CMD="${CT_CLI_TEST_DOCKER_COMPOSE_CMD}"
      fi
      _update_create_snapshot "${1:-2026-01-01-00-00-00}" "${2:-prompt}"
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;
  __test_migrate_pg_max)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Runs _migrate_pg_max_connections against the sandbox .env.
      # Prints "PG_MAX_CONNECTIONS=<value>" after migration so tests can verify.
      _migrate_pg_max_connections
      rc=$?
      printf 'PG_MAX_CONNECTIONS=%s\n' "$(env_get PG_MAX_CONNECTIONS)"
      exit $rc
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;

  __test_prompt_db_backup)
    if [ "${CT_CLI_TEST_MODE:-0}" = "1" ]; then
      # Args: <yes|no|prompt>. Tests cover "yes"/"no" plus the non-TTY
      # "prompt" branches (TTY read-prompts a human, untestable here).
      # CT_CLI_TEST_DB_SIZE_BYTES and CT_CLI_TEST_FREE_BYTES override the
      # measurement helpers so the non-TTY backup-default + insufficient-
      # disk paths are reachable without a live db / docker.
      shift
      # Direct function definitions read the env vars via normal
      # parameter expansion — eval was unnecessary and presented a
      # fragile injection surface (CodeRabbit finding on PR #76).
      if [ -n "${CT_CLI_TEST_DB_SIZE_BYTES:-}" ]; then
        _update_measure_db_size() { printf '%s' "${CT_CLI_TEST_DB_SIZE_BYTES}"; }
      fi
      if [ -n "${CT_CLI_TEST_FREE_BYTES:-}" ]; then
        _update_measure_backup_dir_free() { printf '%s' "${CT_CLI_TEST_FREE_BYTES}"; }
      fi
      _update_prompt_db_backup "${1:-prompt}"
      exit $?
    else
      echo "Unknown command: $1"
      exit 1
    fi
    ;;

  "")
    show_help
    ;;
  *)
    echo "Unknown command: $1"
    echo "Run 'cli.sh --help' for usage information."
    ;;
esac
