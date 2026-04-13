#!/bin/bash

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
else
  CURRENT_SCRIPT_PATH="$CLI_INSTALL_PATH"
fi

# Prep script from GCS
PREP_SCRIPT_URL="${GCS_BASE_URL}/prep.sh"

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
if [ ! -f "${INSTALL_DIR}/prometheus/alert_rules.yml" ]; then
  echo 'groups: []' > "${INSTALL_DIR}/prometheus/alert_rules.yml"
fi

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

  # Ensure Docker uses nftables backend to avoid iptables/nftables conflicts
  # with firewalld on RHEL 9 / AlmaLinux 9 OVAs.
  local DAEMON_JSON="/etc/docker/daemon.json"
  if [ -f "$DAEMON_JSON" ] && command -v python3 &>/dev/null; then
    if ! python3 -c "import json,sys; d=json.load(open('$DAEMON_JSON')); sys.exit(0 if d.get('firewall-backend')=='nftables' and d.get('bip')=='100.64.0.1/24' else 1)" 2>/dev/null; then
      python3 - "$DAEMON_JSON" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
changed = False
if d.get("firewall-backend") != "nftables":
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

# JTAPI feature state — now driven by COMPOSE_PROFILES in .env
JTAPI_STATE_FILE=".jtapi-enabled"
ENV_FILE="${INSTALL_DIR}/.env"

# Read a key from .env (returns empty string if not found)
env_get() {
  local key="$1"
  if [ -f "$ENV_FILE" ]; then
    grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-
  fi
}

# Set or update a key in .env (creates file if needed)
env_set() {
  local key="$1" value="$2"
  if [ ! -f "$ENV_FILE" ]; then
    echo "${key}=${value}" > "$ENV_FILE"
    return
  fi
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# Apply a PostgreSQL memory sizing profile (small/medium/large)
apply_postgres_profile() {
  local profile="$1"
  case "$profile" in
    small)
      env_set "PG_PROFILE" "small"
      env_set "PG_SHM_SIZE" "1gb"
      env_set "PG_SHARED_BUFFERS" "512MB"
      env_set "PG_EFFECTIVE_CACHE_SIZE" "1536MB"
      env_set "PG_WORK_MEM" "8MB"
      env_set "PG_MAINTENANCE_WORK_MEM" "256MB"
      env_set "PG_WAL_BUFFERS" "64MB"
      env_set "PG_PARALLEL_WORKERS" "1"
      env_set "PG_MAX_PARALLEL_WORKERS" "2"
      env_set "PG_AUTOVACUUM_WORKERS" "2"
      env_set "PG_AUTOVACUUM_VACUUM_SCALE" "0.05"
      env_set "PG_AUTOVACUUM_ANALYZE_SCALE" "0.02"
      env_set "PG_MAX_CONNECTIONS" "105"
      env_set "DB_MEM_LIMIT" "3g"
      env_set "WEB_MEM_LIMIT" "2g"
      env_set "DB_POOL_SIZE" "30"
      env_set "DB_BACKGROUND_POOL_SIZE" "5"
      env_set "DB_DISCOVERY_POOL_SIZE" "10"
      env_set "DB_OBAN_POOL_SIZE" "10"
      ;;
    medium)
      # 8GB RAM target — DB gets 4g, web gets 2.5g, ~1.5g for OS/containers
      env_set "PG_PROFILE" "medium"
      env_set "PG_SHM_SIZE" "2gb"
      env_set "PG_SHARED_BUFFERS" "1GB"
      env_set "PG_EFFECTIVE_CACHE_SIZE" "3GB"
      env_set "PG_WORK_MEM" "16MB"
      env_set "PG_MAINTENANCE_WORK_MEM" "512MB"
      env_set "PG_WAL_BUFFERS" "64MB"
      env_set "PG_PARALLEL_WORKERS" "1"
      env_set "PG_MAX_PARALLEL_WORKERS" "2"
      env_set "PG_AUTOVACUUM_WORKERS" "2"
      env_set "PG_AUTOVACUUM_VACUUM_SCALE" "0.02"
      env_set "PG_AUTOVACUUM_ANALYZE_SCALE" "0.01"
      env_set "PG_MAX_CONNECTIONS" "150"
      env_set "DB_MEM_LIMIT" "4g"
      env_set "WEB_MEM_LIMIT" "2500m"
      env_set "DB_POOL_SIZE" "35"
      env_set "DB_BACKGROUND_POOL_SIZE" "8"
      env_set "DB_DISCOVERY_POOL_SIZE" "12"
      env_set "DB_OBAN_POOL_SIZE" "12"
      ;;
    large)
      # 16GB+ RAM target — DB gets 8g, web gets 4g, rest for OS/containers
      env_set "PG_PROFILE" "large"
      env_set "PG_SHM_SIZE" "4gb"
      env_set "PG_SHARED_BUFFERS" "2GB"
      env_set "PG_EFFECTIVE_CACHE_SIZE" "8GB"
      env_set "PG_WORK_MEM" "32MB"
      env_set "PG_MAINTENANCE_WORK_MEM" "1GB"
      env_set "PG_WAL_BUFFERS" "128MB"
      env_set "PG_PARALLEL_WORKERS" "2"
      env_set "PG_MAX_PARALLEL_WORKERS" "4"
      env_set "PG_AUTOVACUUM_WORKERS" "3"
      env_set "PG_AUTOVACUUM_VACUUM_SCALE" "0.01"
      env_set "PG_AUTOVACUUM_ANALYZE_SCALE" "0.005"
      env_set "PG_MAX_CONNECTIONS" "305"
      env_set "DB_MEM_LIMIT" "20g"
      env_set "WEB_MEM_LIMIT" "6g"
      env_set "DB_POOL_SIZE" "60"
      env_set "DB_BACKGROUND_POOL_SIZE" "10"
      env_set "DB_DISCOVERY_POOL_SIZE" "25"
      env_set "DB_OBAN_POOL_SIZE" "20"
      ;;
    *)
      echo "Usage: cli.sh postgres profile <small|medium|large|show>"
      return 1
      ;;
  esac
  echo "PostgreSQL profile set to: $profile"
  echo "  shared_buffers:        $(env_get PG_SHARED_BUFFERS)"
  echo "  effective_cache_size:  $(env_get PG_EFFECTIVE_CACHE_SIZE)"
  echo "  work_mem:              $(env_get PG_WORK_MEM)"
  echo "  maintenance_work_mem:  $(env_get PG_MAINTENANCE_WORK_MEM)"
  echo "  wal_buffers:           $(env_get PG_WAL_BUFFERS)"
  echo "  parallel_workers:      $(env_get PG_PARALLEL_WORKERS)/$(env_get PG_MAX_PARALLEL_WORKERS)"
  echo "  autovacuum_workers:    $(env_get PG_AUTOVACUUM_WORKERS)"
  echo "  db_cpu_limit:          $(env_get DB_CPU_LIMIT || echo '2.0 (default)')"
  echo "  max_connections:       $(env_get PG_MAX_CONNECTIONS)"
  echo "  db_mem_limit:          $(env_get DB_MEM_LIMIT)"
  echo "  web_mem_limit:         $(env_get WEB_MEM_LIMIT)"
  echo "  db_pool (main):        $(env_get DB_POOL_SIZE)"
  echo "  db_pool (background):  $(env_get DB_BACKGROUND_POOL_SIZE)"
  echo "  db_pool (discovery):   $(env_get DB_DISCOVERY_POOL_SIZE)"
  echo "  db_pool (oban):        $(env_get DB_OBAN_POOL_SIZE)"
  echo ""
  echo "Restart required to apply: cli.sh restart"
}

# Remove a key from .env
env_remove() {
  local key="$1"
  [ -f "$ENV_FILE" ] && sed -i "/^${key}=/d" "$ENV_FILE"
}

# Migrate legacy .jtapi-enabled state file to .env COMPOSE_PROFILES
migrate_jtapi_state() {
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

jtapi_cmd() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true

  # Auto-migrate legacy state file on any jtapi command
  migrate_jtapi_state

  case "$subcmd" in
    enable)
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
      echo "[OK] JTAPI enabled — restarting services..."
      echo ""
      if ! restart_service "jtapi enable"; then
        echo "[FAIL] Service restart failed. JTAPI config was saved but services may not be running."
        echo "   Retry with: systemctl restart docker-compose-app.service"
        return 1
      fi
      # Force recreate web to pick up new env vars
      sleep 3
      $DOCKER_COMPOSE_CMD $(get_compose_files) up -d --force-recreate web 2>/dev/null
      echo "Services restarted."
      echo ""
      echo "Next steps:"
      echo "  1. Wait for sidecar to start (~90s)"
      echo "  2. Upload JTAPI JAR via UI (Settings > JTAPI)"
      echo "  3. Sidecar auto-restarts when JAR is received"
      echo "  4. Add CUCM server via UI (Settings > JTAPI > Servers)"
      echo "  5. Sidecar auto-connects when credentials appear in NATS KV"
      ;;
    disable)
      # Remove jtapi from COMPOSE_PROFILES
      local profiles
      profiles=$(env_get "COMPOSE_PROFILES")
      local new_profiles
      new_profiles=$(echo "$profiles" | sed 's/,*jtapi,*//' | sed 's/^,//' | sed 's/,$//')
      env_set "COMPOSE_PROFILES" "$new_profiles"
      # Clear JTAPI env vars
      env_remove "JTAPI_MODE"
      env_remove "JTAPI_SIDECAR_ENDPOINT"
      env_remove "JTAPI_SIDECAR_URL"
      env_remove "S3_ENABLED"
      env_remove "CT_MEDIA_ENDPOINT"
      # Clean up legacy state file if present
      rm -f "$JTAPI_STATE_FILE"
      fix_systemd_compose_files
      echo "[OK] JTAPI disabled — restarting services..."
      if ! restart_service "jtapi disable"; then
        echo "[FAIL] Service restart failed. JTAPI config was saved but services may not be running."
        echo "   Retry with: systemctl restart docker-compose-app.service"
        return 1
      fi
      echo "JTAPI services removed."
      ;;
    status)
      if is_jtapi_enabled; then
        echo "JTAPI: enabled"
        $DOCKER_COMPOSE_CMD $(get_compose_files) ps jtapi-sidecar ct-media seaweedfs 2>/dev/null || true
      else
        echo "JTAPI: disabled"
      fi
      ;;
    troubleshoot)
      echo "=== JTAPI Troubleshooting ==="
      echo ""

      # --- 1. Feature State ---
      echo "--- Feature State ---"
      if is_jtapi_enabled; then
        echo "✓ JTAPI enabled (COMPOSE_PROFILES includes jtapi)"
      else
        echo "[FAIL] JTAPI disabled (COMPOSE_PROFILES does not include jtapi)"
      fi
      echo "  COMPOSE_PROFILES=$(env_get COMPOSE_PROFILES)"
      echo "  Compose files: $(get_compose_files)"
      echo ""

      # --- 2. Container Health ---
      echo "--- Container Health ---"
      export DEFAULT_IPV4="${DEFAULT_IPV4:-}"
      for svc in jtapi-jar-init jtapi-sidecar ct-media seaweedfs; do
        local cid
        cid=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps -q "$svc" 2>/dev/null)
        if [ -z "$cid" ]; then
          # Init container may not show in ps after completion — check all containers
          cid=$(docker ps -a --filter "name=${svc}" --format '{{.ID}}' 2>/dev/null | head -1)
        fi

        if [ -z "$cid" ]; then
          if [ "$svc" = "jtapi-jar-init" ]; then
            echo "[WARN] $svc: not found (may have been cleaned up after successful run)"
          else
            echo "[FAIL] $svc: not found (not deployed or not in compose files)"
          fi
        else
          local cstate
          cstate=$(docker inspect --format='{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
          local exit_code
          exit_code=$(docker inspect --format='{{.State.ExitCode}}' "$cid" 2>/dev/null || echo "N/A")

          if [ "$svc" = "jtapi-jar-init" ]; then
            # Init container is expected to exit with code 0
            if [ "$cstate" = "exited" ] && [ "$exit_code" = "0" ]; then
              echo "✓ $svc: completed successfully (exit 0)"
            elif [ "$cstate" = "exited" ]; then
              echo "[FAIL] $svc: failed (exit $exit_code)"
            else
              echo "[WARN] $svc: $cstate"
            fi
          elif [ "$cstate" = "running" ]; then
            echo "✓ $svc: running"
          else
            echo "[FAIL] $svc: $cstate (exit $exit_code)"
          fi
        fi
      done
      # Show restart counts
      echo ""
      echo "  Container restart counts:"
      for svc in jtapi-sidecar ct-media seaweedfs; do
        local restart_count
        restart_count=$(docker inspect --format='{{.RestartCount}}' "$($DOCKER_COMPOSE_CMD $(get_compose_files) ps -q "$svc" 2>/dev/null)" 2>/dev/null || echo "N/A")
        echo "    $svc: $restart_count restarts"
      done
      echo ""

      # --- 3. NATS Connectivity ---
      echo "--- NATS Connectivity ---"
      # Check NATS is accepting connections via health endpoint
      local nats_health
      nats_health=$($DOCKER_COMPOSE_CMD $(get_compose_files) exec -T nats wget -q -O- http://127.0.0.1:8222/healthz 2>&1)
      if echo "$nats_health" | grep -qi "ok\|status"; then
        echo "✓ NATS server is healthy"
      else
        # Fallback: check container health status (pgrep not available in nats:2.11 image)
        local nats_status
        nats_status=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps nats --format '{{.Status}}' 2>/dev/null || echo "unknown")
        echo "  NATS: $nats_status"
      fi
      echo ""

      # Use nats-box for KV/ObjectStore checks (nats CLI not in server image)
      local CT_NETWORK
      CT_NETWORK=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps --format '{{.Networks}}' nats 2>/dev/null | head -1 | cut -d',' -f1)
      if [ -z "$CT_NETWORK" ]; then
        CT_NETWORK="calltelemetry_ct"
      fi

      echo "  NATS KV buckets:"
      docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 nats -s nats://nats:4222 kv ls 2>&1 | sed 's/^/    /' || echo "    [FAIL] Could not list KV buckets"
      echo ""

      echo "  NATS ObjectStore (jtapi-jars-1):"
      local objstore_result
      objstore_result=$(docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 nats -s nats://nats:4222 object ls jtapi-jars-1 2>&1)
      if echo "$objstore_result" | grep -q "jtapi.jar"; then
        echo "    ✓ jtapi.jar found in NATS ObjectStore"
      elif echo "$objstore_result" | grep -qi "not found\|no such\|error"; then
        echo "    [WARN] jtapi-jars-1 bucket: $objstore_result"
      else
        echo "    $objstore_result" | sed 's/^/    /'
      fi
      echo ""

      echo "--- NATS ObjectStore Buckets ---"
      docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 \
        sh -c 'nats -s nats://nats:4222 object ls 2>/dev/null' 2>/dev/null | sed 's/^/    /' || echo "    Failed to list ObjectStore buckets"
      echo ""

      echo "--- jtapi-jars-1 bucket contents ---"
      docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 \
        sh -c 'nats -s nats://nats:4222 object ls jtapi-jars-1 2>/dev/null' 2>/dev/null | sed 's/^/    /' || echo "    Bucket jtapi-jars-1 not found or empty"
      echo ""

      # --- 4. JAR Status ---
      echo "--- JAR Status ---"
      local jar_vol_check
      jar_vol_check=$(docker run --rm -v calltelemetry_jtapi-jars:/jars alpine ls -la /jars/jtapi.jar 2>&1)
      if echo "$jar_vol_check" | grep -q "jtapi.jar"; then
        echo "✓ JAR found in Docker volume"
        echo "    $jar_vol_check"
      else
        echo "[FAIL] JAR not found in Docker volume"
        echo "    $jar_vol_check"
      fi
      echo ""
      echo "  NATS ObjectStore JAR info:"
      docker run --rm --network "$CT_NETWORK" natsio/nats-box:0.14.5 nats -s nats://nats:4222 object info jtapi-jars-1 jtapi.jar 2>&1 | sed 's/^/    /' || echo "    [FAIL] Could not query NATS ObjectStore"
      echo ""

      # --- 5. Sidecar Health ---
      echo "--- Sidecar Health ---"
      local sidecar_health
      sidecar_health=$($DOCKER_COMPOSE_CMD $(get_compose_files) exec -T jtapi-sidecar wget -q -O- http://127.0.0.1:8080/actuator/health 2>&1 || echo "Sidecar not responding")
      if echo "$sidecar_health" | grep -qi '"status":"UP"\|"status":"up"'; then
        echo "✓ Sidecar health: $sidecar_health"
      else
        echo "[WARN] Sidecar health: $sidecar_health"
      fi
      echo ""
      echo "  Last 20 lines of sidecar logs:"
      $DOCKER_COMPOSE_CMD $(get_compose_files) logs --tail=20 jtapi-sidecar 2>&1 | sed 's/^/    /'
      echo ""

      # --- 6. SeaweedFS Health ---
      echo "--- SeaweedFS Health ---"
      local seaweedfs_health
      seaweedfs_health=$($DOCKER_COMPOSE_CMD $(get_compose_files) exec -T seaweedfs curl -sf http://127.0.0.1:9333/cluster/healthz 2>&1)
      if [ $? -eq 0 ]; then
        echo "✓ SeaweedFS is healthy"
      else
        echo "[FAIL] SeaweedFS health check failed: $seaweedfs_health"
      fi
      echo ""
      echo "  SeaweedFS buckets:"
      $DOCKER_COMPOSE_CMD $(get_compose_files) exec -T seaweedfs curl -sf http://localhost:9333/cluster/healthz 2>&1 | sed 's/^/    /' || echo "    [WARN] Could not check SeaweedFS cluster status"
      echo ""

      # --- 7. ct-media Health ---
      echo "--- ct-media Health ---"
      local media_state
      media_state=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps --format '{{.State}}' ct-media 2>/dev/null || echo "not found")
      if [ "$media_state" = "running" ]; then
        echo "✓ ct-media is running"
      else
        echo "[FAIL] ct-media state: ${media_state:-not found}"
      fi
      echo ""
      echo "  Last 10 lines of ct-media logs:"
      $DOCKER_COMPOSE_CMD $(get_compose_files) logs --tail=10 ct-media 2>&1 | sed 's/^/    /'
      echo ""

      # --- 8. Web Service JTAPI Config ---
      echo "--- Web Service JTAPI Config ---"
      echo "  Environment variables:"
      $DOCKER_COMPOSE_CMD $(get_compose_files) exec -T web env 2>/dev/null | grep -E 'JTAPI|S3_|CT_MEDIA|NATS_URL' | sort | sed 's/^/    /' || echo "    [FAIL] Could not read web container env"
      echo ""

      # --- 9. CallManager CTI Credentials Check ---
      echo "--- CallManager CTI Credentials ---"
      local release_bin
      release_bin=$(get_release_binary)
      $DOCKER_COMPOSE_CMD $(get_compose_files) exec -T web "$release_bin" rpc '
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
      ' 2>&1 | sed 's/^/  /' || echo "  [FAIL] Could not query JTAPI server configuration (web container may not be running)"
      echo ""

      # --- 10. JTAPI Runtime Diagnostics (from web logs) ---
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

      # --- 11. JTAPI Health API Response ---
      echo ""
      echo "=== JTAPI Health API Response ==="
      echo ""

      # Detect Docker Compose network name (reuse CT_NETWORK if already set)
      if [ -z "${CT_NETWORK:-}" ]; then
        CT_NETWORK=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep '_ct$' | head -1)
        if [ -z "$CT_NETWORK" ]; then
          CT_NETWORK="${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}_ct"
        fi
      fi

      # Call the health endpoint directly (org_id=1 for OVA single-org)
      local health_response
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

      echo "=== Troubleshooting Complete ==="
      ;;
    *)
      echo "Usage: $0 jtapi {enable|disable|status|troubleshoot}"
      echo ""
      echo "Commands:"
      echo "  enable        Enable JTAPI sidecar, ct-media, and SeaweedFS services"
      echo "  disable       Disable JTAPI services"
      echo "  status        Show JTAPI status and service health"
      echo "  troubleshoot  Run comprehensive JTAPI diagnostics"
      ;;
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
      profile_down \
        calltelemetry-prometheus-1 calltelemetry-grafana-1 calltelemetry-loki-1 \
        calltelemetry-alloy-1 calltelemetry-tempo-1 calltelemetry-otel-collector-1 \
        calltelemetry-node-exporter-1 calltelemetry-nats-exporter-1 \
        calltelemetry-postgres-exporter-1 calltelemetry-alertmanager-1
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
      echo "[WARN] Unable to adjust permissions for $dir automatically."
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

  # API too old or no compose available - install latest standalone
  install_latest_docker_compose
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return 0
  fi

  # Neither available
  echo ""
  return 1
}

# Set the docker compose command to use throughout the script
DOCKER_COMPOSE_CMD=$(detect_docker_compose)
if [ -z "$DOCKER_COMPOSE_CMD" ]; then
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

# Restart the docker-compose systemd service with error handling.
# Checks exit code, logs diagnostics on failure, retries once.
# Returns 0 on success, 1 on failure.
restart_service() {
  local context="${1:-}" # optional caller context for log messages
  local service="docker-compose-app.service"

  # Ensure bind-mount files exist before Docker starts (prevents directory auto-creation)
  ensure_bind_mount_files

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

  echo "Restarting Docker Compose service..."

  # Restart synchronously — no log tailing during boot.
  # Progress is shown by wait_for_services() which reports stepped
  # container startup, DB readiness, migration status, and health checks.
  systemctl restart "$service"
  local restart_exit=$?

  if [ "$restart_exit" -eq 0 ]; then
    echo ""
    echo "[OK] Docker Compose service restarted successfully."
    return 0
  fi

  # First attempt failed — capture diagnostics
  echo "[WARN] Service restart failed (exit code: $restart_exit). Gathering diagnostics..."
  echo ""

  # Show recent journal entries for context
  echo "--- systemd journal (last 15 lines) ---"
  journalctl -u "$service" --no-pager -n 15 2>/dev/null || true
  echo "--- end journal ---"
  echo ""

  # Check if the service file itself is valid
  if ! systemctl cat "$service" >/dev/null 2>&1; then
    echo "[FAIL] Service unit file is invalid or missing."
    echo "   Check: /etc/systemd/system/$service"
    return 1
  fi

  # Reload daemon in case unit file was modified
  echo "Reloading systemd daemon and retrying..."
  systemctl daemon-reload 2>/dev/null

  if systemctl restart "$service" 2>/dev/null; then
    echo "[OK] Service restarted on retry."
    return 0
  fi

  # Second attempt also failed
  echo ""
  echo "[FAIL] Service restart failed after retry."
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
      echo "[OK] NM connection profiles checked."
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
  echo "  update <version>    Update to specific version (e.g., 0.8.4-rc191)"
  echo "                      Options: --force-upgrade, --no-cleanup, --ipv6"
  echo "  rollback            Roll back to previous docker-compose configuration"
  echo "  reset               Stop application, remove data, and restart"
  echo "  restart             Restart all services (docker compose down/up)"
  echo "  stop                Stop all services"
  echo "  start               Start all services"
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
  echo "  otel                Show observability stack status"
  echo "  otel enable         Start Prometheus, Grafana, Loki, Alloy, Tempo, and exporters"
  echo "  otel disable        Stop otel stack (~900 MiB freed)"
  echo
  echo "Maintenance Commands:"
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

  # Download the latest script
  if ! wget -q "$SCRIPT_URL" -O "$tmp_file"; then
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

  # Extract raw image lines and resolve env vars
  grep -E "^\s+image:.*calltelemetry" "$compose_file" | sed 's/.*image: *["]*//;s/["]*$//' | grep -v "^$" | while read -r img; do
    # Resolve ${VAR:-default} patterns
    resolved="$img"
    while echo "$resolved" | grep -qE '\$\{[A-Z_]+:-[^}]*\}'; do
      var_expr=$(echo "$resolved" | grep -oE '\$\{[A-Z_]+:-[^}]*\}' | head -1)
      var_name=$(echo "$var_expr" | sed 's/\${//;s/:-.*//')
      var_default=$(echo "$var_expr" | sed 's/.*:-//;s/}//')
      var_value=$(echo "$env_vars" | grep "^${var_name}=" | head -1 | cut -d= -f2-)
      [ -z "$var_value" ] && var_value="$var_default"
      resolved=$(echo "$resolved" | sed "s|\${${var_name}:-[^}]*}|${var_value}|")
    done

    # Resolve ${VAR} patterns (no default — must come from .env)
    while echo "$resolved" | grep -qE '\$\{[A-Z_]+\}'; do
      var_expr=$(echo "$resolved" | grep -oE '\$\{[A-Z_]+\}' | head -1)
      var_name=$(echo "$var_expr" | sed 's/\${\|}//g')
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

# Check if a single Docker image is available (local or remote)
# Returns 0 if available, 1 if not
check_single_image() {
  local image="$1"

  # 1. Already pulled locally — no network needed
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "✓ Available (local)"
    return 0
  fi

  # 2. Try registry via docker manifest inspect (needs experimental on older Docker)
  # timeout 10 prevents hanging indefinitely on slow/rate-limited networks
  if timeout 10 bash -c "DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect '$image'" >/dev/null 2>&1; then
    echo "✓ Available (registry)"
    return 0
  fi

  # 3. Lightweight HEAD check against Docker Hub v2 API (no auth needed for public images)
  local repo="${image%%:*}"        # e.g. calltelemetry/postgres
  local tag="${image##*:}"         # e.g. 14
  [ "$tag" = "$image" ] && tag="latest"
  local hub_url="https://hub.docker.com/v2/repositories/${repo}/tags/${tag}"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --max-time 5 -o /dev/null -w '' "$hub_url" 2>/dev/null; then
      echo "✓ Available (hub API)"
      return 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --timeout=5 --spider "$hub_url" 2>/dev/null; then
      echo "✓ Available (hub API)"
      return 0
    fi
  fi

  echo "✗ Not available"
  return 1
}

# Function to check if Docker images are available
check_image_availability() {
  local compose_file="$1"
  local images=$(extract_images "$compose_file")
  local all_available=true
  local unavailable_images=""

  echo "Checking image availability..."

  for image in $images; do
    echo -n "  Checking $image... "
    if check_single_image "$image"; then
      : # message already printed by check_single_image
    else
      all_available=false
      unavailable_images="$unavailable_images$image\n"
    fi
  done

  if [ "$all_available" = true ]; then
    echo "[OK] All images are available"
    return 0
  else
    echo "[FAIL] Some images are not available:"
    echo -e "$unavailable_images"
    return 1
  fi
}

# Download and extract the pre-built config bundle from GCS
# This consolidates all config files: docker-compose.yml, prometheus, grafana, cli.sh, etc.
download_bundle() {
  local version="$1"
  local bundle_name="calltelemetry-bundle-${version}.tar.gz"
  local bundle_url="${GCS_BUNDLE_BASE_URL}/${version}/${bundle_name}"
  local extract_dir="bundle-extract-$$"

  echo "Downloading config bundle for version $version..."

  # Download bundle
  if command -v wget >/dev/null 2>&1; then
    if ! wget -q --show-progress "$bundle_url" -O "$bundle_name" 2>&1; then
      echo ""
      echo "[FAIL] Failed to download bundle from GCS"
      echo "URL: $bundle_url"
      echo ""
      echo "Possible causes:"
      echo "  - Version $version may not exist"
      echo "  - Network connectivity issue"
      echo ""
      echo "Check available releases at:"
      echo "  https://github.com/calltelemetry/calltelemetry/releases"
      rm -f "$bundle_name"
      return 1
    fi
  elif command -v curl >/dev/null 2>&1; then
    if ! curl -fL --progress-bar "$bundle_url" -o "$bundle_name"; then
      echo "[FAIL] Failed to download bundle from GCS"
      rm -f "$bundle_name"
      return 1
    fi
  else
    echo "Error: Neither wget nor curl is available"
    return 1
  fi

  echo "[OK] Bundle downloaded"

  # Extract bundle
  echo "Extracting config files..."
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  if ! tar -xzf "$bundle_name" -C "$extract_dir" --strip-components=1; then
    echo "[FAIL] Failed to extract bundle"
    rm -f "$bundle_name"
    rm -rf "$extract_dir"
    return 1
  fi

  sanitize_metadata_artifacts "$extract_dir"

  # Move files to proper locations
  # docker-compose.yml -> temp file for validation
  if [ -f "$extract_dir/docker-compose.yml" ]; then
    mv "$extract_dir/docker-compose.yml" "$TEMP_FILE"
    echo "  [OK] docker-compose.yml"
  else
    echo "[FAIL] Bundle missing docker-compose.yml"
    rm -f "$bundle_name"
    rm -rf "$extract_dir"
    return 1
  fi

  # .env -> merge version pins from bundle into existing .env
  # Only update version keys (*_VERSION); preserve user customizations (secrets, network, profiles)
  if [ -f "$extract_dir/.env" ]; then
    if [ -f "$ENV_FILE" ]; then
      # Merge all *_VERSION keys from bundle .env into existing .env
      # This auto-discovers new version keys (e.g., CT_SYSLOG_INGEST_VERSION)
      grep -E '^[A-Z_]+_VERSION=' "$extract_dir/.env" | grep -v '^#' | while IFS='=' read -r key val; do
        if [ -n "$key" ] && [ -n "$val" ]; then
          env_set "$key" "$val"
        fi
      done
      echo "  [OK] .env (version pins merged)"
    else
      cp "$extract_dir/.env" "$ENV_FILE"
      echo "  [OK] .env (created from bundle)"
    fi
  fi

  # .env.example -> always overwrite template
  if [ -f "$extract_dir/.env.example" ]; then
    cp "$extract_dir/.env.example" ./.env.example
    echo "  [OK] .env.example"
  fi

  # cli.sh -> update current script
  if [ -f "$extract_dir/cli.sh" ]; then
    if ! diff -q "$extract_dir/cli.sh" "$CURRENT_SCRIPT_PATH" >/dev/null 2>&1; then
      cp "$extract_dir/cli.sh" "$CURRENT_SCRIPT_PATH"
      chmod +x "$CURRENT_SCRIPT_PATH"
      echo "  [OK] cli.sh (updated)"
    else
      echo "  [OK] cli.sh (no changes)"
    fi
  fi

  # prometheus/prometheus.yml
  if [ -f "$extract_dir/prometheus/prometheus.yml" ]; then
    mkdir -p prometheus
    rm -f prometheus/prometheus.yml 2>/dev/null
    if mv -f "$extract_dir/prometheus/prometheus.yml" prometheus/; then
      echo "  [OK] prometheus/prometheus.yml"
    else
      echo "  [WARN] prometheus/prometheus.yml (failed to move — check permissions)"
    fi
  fi

  # alertmanager/alertmanager.yml
  if [ -f "$extract_dir/alertmanager/alertmanager.yml" ]; then
    mkdir -p alertmanager
    # Remove if Docker auto-created it as a directory (common bind-mount gotcha)
    [ -d "alertmanager/alertmanager.yml" ] && rm -rf "alertmanager/alertmanager.yml"
    rm -f alertmanager/alertmanager.yml 2>/dev/null
    if mv -f "$extract_dir/alertmanager/alertmanager.yml" alertmanager/; then
      echo "  [OK] alertmanager/alertmanager.yml"
    else
      echo "  [WARN] alertmanager/alertmanager.yml (failed to move — check permissions)"
    fi
  fi

  # grafana dashboards and provisioning
  if [ -d "$extract_dir/grafana" ]; then
    mkdir -p grafana/dashboards grafana/provisioning/datasources grafana/provisioning/dashboards

    # Copy dashboards
    if [ -d "$extract_dir/grafana/dashboards" ]; then
      cp -r "$extract_dir/grafana/dashboards/"* grafana/dashboards/ 2>/dev/null && echo "  [OK] grafana/dashboards"
    fi

    # Copy provisioning
    if [ -d "$extract_dir/grafana/provisioning" ]; then
      cp -r "$extract_dir/grafana/provisioning/"* grafana/provisioning/ 2>/dev/null && echo "  [OK] grafana/provisioning"
    fi

    sanitize_grafana_assets grafana/dashboards grafana/provisioning
  fi

  # nats.conf
  if [ -f "$extract_dir/nats.conf" ]; then
    rm -f ./nats.conf 2>/dev/null
    if cp "$extract_dir/nats.conf" ./nats.conf; then
      echo "  [OK] nats.conf"
    else
      echo "  [WARN] nats.conf (failed to copy — check permissions)"
    fi
  fi

  # Caddyfile
  if [ -f "$extract_dir/Caddyfile" ]; then
    if [ -f "./Caddyfile" ]; then
      if ! diff -q "$extract_dir/Caddyfile" "./Caddyfile" >/dev/null 2>&1; then
        rm -f ./Caddyfile 2>/dev/null
        cp "$extract_dir/Caddyfile" ./Caddyfile
        echo "  [OK] Caddyfile (updated)"
      else
        echo "  [OK] Caddyfile (no changes)"
      fi
    else
      cp "$extract_dir/Caddyfile" ./Caddyfile
      echo "  [OK] Caddyfile (installed)"
    fi
  fi

  # seaweedfs-s3.json (required for JTAPI S3 storage)
  if [ -f "$extract_dir/seaweedfs-s3.json" ]; then
    rm -rf ./seaweedfs-s3.json 2>/dev/null
    if cp "$extract_dir/seaweedfs-s3.json" ./seaweedfs-s3.json; then
      echo "  [OK] seaweedfs-s3.json"
    else
      echo "  [WARN] seaweedfs-s3.json (failed to copy — check permissions)"
    fi
  fi

  # otel-collector config
  if [ -f "$extract_dir/otel-collector/otel-collector-config.yaml" ]; then
    mkdir -p ./otel-collector
    # Docker may have created config.yaml as a directory — remove it first
    if [ -d "./otel-collector/otel-collector-config.yaml" ]; then
      rm -rf "./otel-collector/otel-collector-config.yaml"
      echo "  [OK] otel-collector-config.yaml (removed Docker-created directory)"
    fi
    if cp "$extract_dir/otel-collector/otel-collector-config.yaml" ./otel-collector/otel-collector-config.yaml; then
      echo "  [OK] otel-collector-config.yaml"
    else
      echo "  [WARN] otel-collector-config.yaml (failed to copy — check permissions)"
    fi
  fi

  # Tempo config
  if [ -f "$extract_dir/tempo/tempo.yaml" ]; then
    mkdir -p ./tempo
    [ -d "./tempo/tempo.yaml" ] && rm -rf "./tempo/tempo.yaml" && echo "  [OK] tempo/tempo.yaml (removed Docker-created directory)"
    if cp "$extract_dir/tempo/tempo.yaml" ./tempo/tempo.yaml; then
      echo "  [OK] tempo/tempo.yaml"
    else
      echo "  [WARN] tempo/tempo.yaml (failed to copy — check permissions)"
    fi
  fi

  # Loki config
  if [ -f "$extract_dir/loki/loki.yaml" ]; then
    mkdir -p ./loki
    [ -d "./loki/loki.yaml" ] && rm -rf "./loki/loki.yaml" && echo "  [OK] loki/loki.yaml (removed Docker-created directory)"
    if cp "$extract_dir/loki/loki.yaml" ./loki/loki.yaml; then
      echo "  [OK] loki/loki.yaml"
    else
      echo "  [WARN] loki/loki.yaml (failed to copy — check permissions)"
    fi
  fi

  # Alloy config
  if [ -f "$extract_dir/alloy/config.alloy" ]; then
    mkdir -p ./alloy
    [ -d "./alloy/config.alloy" ] && rm -rf "./alloy/config.alloy" && echo "  [OK] alloy/config.alloy (removed Docker-created directory)"
    if cp "$extract_dir/alloy/config.alloy" ./alloy/config.alloy; then
      echo "  [OK] alloy/config.alloy"
    else
      echo "  [WARN] alloy/config.alloy (failed to copy — check permissions)"
    fi
  fi

  # Cleanup
  rm -f "$bundle_name"
  rm -rf "$extract_dir"

  echo "[OK] All config files extracted"
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
    echo "[WARN] Failed to download Prometheus configuration from $PROMETHEUS_CONFIG_URL"
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
      echo "[WARN] Failed to download Grafana asset: ${asset}"
      rm -f "$tmp_file"
    fi
  done

  sanitize_grafana_assets "$provisioning_mount" "$dashboards_mount"
  ensure_grafana_permissions "$provisioning_mount" "$dashboards_mount"
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
      echo "Enabling IPv6..."
      configure_ipv6 "$ORIGINAL_FILE" true
      echo ""
      fix_systemd_service_if_needed
      if ! restart_service "ipv6 enable"; then
        echo "[FAIL] Service restart failed after IPv6 enable."
        return 1
      fi
      echo ""
      wait_for_services
      ;;
    disable)
      echo "Disabling IPv6..."
      configure_ipv6 "$ORIGINAL_FILE" false
      echo ""
      fix_systemd_service_if_needed
      if ! restart_service "ipv6 disable"; then
        echo "[FAIL] Service restart failed after IPv6 disable."
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

# Function to update the docker-compose configuration
update() {
  # Note: cli.sh is updated via the config bundle download

  version=""
  force_upgrade=false
  skip_cleanup=false
  enable_ipv6=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-upgrade)
        force_upgrade=true
        shift
        ;;
      --no-cleanup)
        skip_cleanup=true
        shift
        ;;
      --ipv6)
        enable_ipv6=true
        shift
        ;;
      --stable)
        version="stable"
        shift
        ;;
      --latest)
        version="latest"
        shift
        ;;
      *)
        if [ -z "$version" ]; then
          version="$1"
        fi
        shift
        ;;
    esac
  done

  # Resolve version from GCS markers if needed
  # Default (no version) = stable, use --latest for bleeding edge
  if [ -z "$version" ] || [ "$version" = "stable" ]; then
    echo "Fetching latest stable version..."
    version=$(curl -sfL "${GCS_BASE_URL}/latest-stable.txt" 2>/dev/null)
    if [ -z "$version" ]; then
      echo "[FAIL] Failed to fetch latest stable version"
      echo ""
      echo "No stable release available yet."
      echo "Use 'cli.sh update --latest' for pre-release, or specify a version manually."
      return 1
    fi
    echo "Latest stable version: $version"
  elif [ "$version" = "latest" ]; then
    echo "Fetching latest version (including pre-releases)..."
    version=$(curl -sfL "${GCS_BASE_URL}/latest.txt" 2>/dev/null)
    if [ -z "$version" ]; then
      echo "[FAIL] Failed to fetch latest version"
      echo ""
      echo "Specify a version manually: cli.sh update <version>"
      return 1
    fi
    echo "Latest version: $version"
  fi

  # Get current version
  current_version=$(get_current_version)
  echo "Current version: $current_version"
  echo "Target version: $version"
  echo ""

  # Check RAM requirement for version 0.8.4 and higher unless --force-upgrade is specified
  if is_version_084_or_higher "$version"; then
    if [ "$force_upgrade" = false ]; then
      echo "Checking RAM requirements for version $version..."
      if ! check_ram; then
        echo ""
        echo "[FAIL] ERROR: Insufficient RAM for version 0.8.4 and higher"
        echo "   Version 0.8.4+ requires 8GB RAM (minimum 7GB detected)"
        echo ""
        echo "To proceed anyway, use: $0 update $version --force-upgrade"
        echo "WARNING: Proceeding with insufficient RAM may cause performance issues or failures"
        return 1
      fi
      echo "[OK] RAM requirement met (8GB recommended for optimal performance)"
      echo ""
    else
      echo "[WARN] WARNING: Skipping RAM check (--force-upgrade flag used)"
      echo "   Version 0.8.4+ requires 8GB RAM - proceeding with insufficient RAM may cause issues"
      echo ""
    fi
  fi

  # Check disk space unless --force-upgrade is specified
  if [ "$force_upgrade" = false ]; then
    echo "Checking disk space..."
    df -h / | head -2

    if ! check_disk_space; then
      available_percent=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
      free_percent=$((100 - ${available_percent%\%}))
      echo ""
      echo "[FAIL] ERROR: Insufficient disk space for upgrade"
      echo "   Available: ${free_percent}% free"
      echo "   Required: 10% free minimum"
      echo ""
      echo "To proceed anyway, use: $0 update $version --force-upgrade"
      echo "WARNING: Proceeding with low disk space may cause upgrade failures"
      return 1
    fi
    echo "[OK] Sufficient disk space available"
    echo ""
  else
    echo "[WARN] WARNING: Skipping disk space check (--force-upgrade flag used)"
    echo ""
  fi

  # Check for CentOS Stream 8 and display warning
  if [ -f /etc/os-release ]; then
    if grep -qi "centos.*stream.*8\|CentOS.*Stream.*8\|CENTOS.*STREAM.*8" /etc/os-release; then
      echo "[WARN] WARNING: This appliance is running CentOS 8 Stream, and the OS has reached end of life in the Red Hat ecosystem. Please download a new appliance from calltelemetry.com, and copy the postgres and certificate folder over to the new appliance. If you continue, older Docker versions may not work with new builds in 0.8.4 releases. Sleeping for 5 seconds. Press CTRL-C to cancel."
      sleep 5
    fi
  fi

  # Check Docker version and update if needed
  echo "Checking Docker version..."
  docker_version=$(docker --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -1 | cut -d. -f1)

  if [ -z "$docker_version" ]; then
    echo "[WARN] WARNING: Docker not found or not responding"
  elif [ "$docker_version" -lt 26 ]; then
    echo "[WARN] WARNING: Docker version $docker_version detected - Docker 26+ is required"
    echo "Docker is outdated, updating Docker packages..."
    echo "Running Docker package updates..."
    sudo dnf update -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo "Docker package update completed."
    echo ""

    # Verify Docker version after update
    echo "Verifying Docker version after update..."
    updated_docker_version=$(docker --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -1 | cut -d. -f1)

    if [ -z "$updated_docker_version" ]; then
      echo "[FAIL] ERROR: Docker update failed - Docker is not responding"
      echo "   Docker 26+ is required to continue"
      echo "   Please manually update Docker and try again"
      return 1
    elif [ "$updated_docker_version" -lt 26 ]; then
      echo "[FAIL] ERROR: Docker update failed - Docker is still on version $updated_docker_version"
      echo "   Docker 26+ is required to continue"
      echo "   Current version: $updated_docker_version"
      echo "   Required version: 26 or higher"
      echo ""
      echo "   Please manually update Docker to version 26+ and try again"
      echo "   You may need to check your repository configuration or available packages"
      return 1
    else
      echo "[OK] Docker successfully updated to version $updated_docker_version"
      echo ""
    fi
  else
    echo "[OK] Docker version $docker_version is supported"
  fi

  timestamp=$(date "+%Y-%m-%d-%H-%M-%S")
  timestamped_backup_file="$BACKUP_DIR/docker-compose-$timestamp.yml"

  if [ -f "$ORIGINAL_FILE" ]; then
    cp "$ORIGINAL_FILE" "$timestamped_backup_file"
    echo "Existing docker-compose.yml backed up to $timestamped_backup_file"
  fi

  # Download config bundle from GCS (includes docker-compose, prometheus, grafana, cli.sh)
  echo ""
  if ! download_bundle "$version"; then
    echo "[FAIL] Failed to download config bundle"
    echo ""
    echo "Check available versions at: https://github.com/calltelemetry/calltelemetry/releases"
    return 1
  fi
  echo ""

  # Check image availability before proceeding unless --force-upgrade is specified
  if [ "$force_upgrade" = false ]; then
    if ! check_image_availability "$TEMP_FILE"; then
      echo ""
      echo "[FAIL] Cannot proceed with upgrade - some images are not available"
      echo "Please ensure all images are built and pushed to the registry"
      echo ""
      echo "To proceed anyway, use: $0 update $version --force-upgrade"
      echo "WARNING: Proceeding without verifying image availability may cause upgrade failures"
      rm -f "$TEMP_FILE"
      return 1
    fi
  else
    echo "[WARN] WARNING: Skipping image availability check (--force-upgrade flag used)"
    echo ""
  fi

  echo ""
  # Authenticate to Docker Hub if credentials are available (avoids unauthenticated pull rate limits)
  if [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
    echo "Logging in to Docker Hub as ${DOCKERHUB_USERNAME}..."
    echo "${DOCKERHUB_TOKEN}" | sudo docker login -u "${DOCKERHUB_USERNAME}" --password-stdin
  fi
  # Smart pull — only download images that aren't already present locally.
  # Saves bandwidth and time on re-runs or minor version bumps where most
  # images haven't changed.
  echo "Checking which images need updating..."
  local pull_needed=false
  local skipped=0
  local pulled=0

  # Core services
  while IFS= read -r img; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      echo "  ✓ $img (already present)"
      skipped=$((skipped + 1))
    else
      echo "  ↓ $img (pulling...)"
      if docker pull "$img"; then
        pulled=$((pulled + 1))
      else
        echo "  [FAIL] Failed to pull $img"
        rm -f "$TEMP_FILE"
        return 1
      fi
    fi
  done < <(extract_images "$TEMP_FILE")

  # JTAPI profile images (if enabled)
  if is_jtapi_enabled; then
    for svc in jtapi-sidecar ct-media seaweedfs; do
      local img=$($DOCKER_COMPOSE_CMD -f "$TEMP_FILE" --profile jtapi config 2>/dev/null | grep -A1 "^  ${svc}:" | grep "image:" | awk '{print $2}' | tr -d '"')
      if [ -n "$img" ]; then
        if docker image inspect "$img" >/dev/null 2>&1; then
          echo "  ✓ $img (already present)"
          skipped=$((skipped + 1))
        else
          echo "  ↓ $img (pulling...)"
          docker pull "$img" || echo "  [WARN] $img not available yet"
          pulled=$((pulled + 1))
        fi
      fi
    done
  fi

  echo "[OK] Images ready ($pulled pulled, $skipped already present)"

  # Pull any remaining images not covered above (e.g. calltelemetry/postgres,
  # infrastructure images with non-versioned tags). Uses the new compose file
  # so it pulls the correct versions for the upgrade target.
  echo "Pulling remaining infrastructure images..."
  $DOCKER_COMPOSE_CMD -f "$TEMP_FILE" pull --quiet 2>/dev/null || true

  # Extract and display the image versions
  echo ""
  echo "Image versions to be deployed:"
  extract_images "$TEMP_FILE" | while read image; do
    echo "  - $image"
  done

  echo ""
  echo "[WARN] You are about to upgrade from $current_version to $version"
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

  # Check if running in interactive mode (has proper stdin)
  if [[ -t 0 ]]; then
    echo "Press any key within 5 seconds to abort, or wait to continue..."

    # Read with timeout of 5 seconds
    if read -t 5 -n 1 -s; then
      echo ""
      echo "Upgrade cancelled by user"
      rm -f "$TEMP_FILE"
      return 0
    fi
    echo ""
    echo "No input received - proceeding with upgrade"
  else
    echo "Running in non-interactive mode - proceeding automatically"
    sleep 2
  fi

  echo "Proceeding with upgrade..."

  # Config files (nats.conf, Caddyfile, prometheus, grafana) already extracted by download_bundle()
  if [ -f "$TEMP_FILE" ]; then
    # NOTE: PostgreSQL version guard removed — no longer auto-downloads
    # docker-compose.override.yml during upgrades. Users who need a specific
    # PG version can run: cli.sh postgres set <version>

    mv "$TEMP_FILE" "$ORIGINAL_FILE"
    echo "New docker-compose.yml moved to production."

    # Configure IPv6 settings based on --ipv6 flag
    configure_ipv6 "$ORIGINAL_FILE" "$enable_ipv6"

    # Pre-flight: repair Docker-created directories for config bind mounts.
    # When upgrading from versions that didn't have Loki/Alloy/Tempo, Docker
    # creates the mount target as a directory instead of a file. Fix it now.
    # Actual config files are deployed via the release bundle (bundle-manifest.yml).
    for config_pair in "loki/loki.yaml" "alloy/config.alloy" "tempo/tempo.yaml" "otel-collector/otel-collector-config.yaml"; do
      config_path="${INSTALL_DIR}/${config_pair}"
      if [ -d "$config_path" ]; then
        echo "  Fixing Docker-created directory: $config_path"
        rm -rf "$config_path"
      fi
    done

    fix_systemd_service_if_needed
    fix_systemd_compose_files

    # Check swap compliance: 8GB total, or 50% of RAM if RAM > 16GB
    local SWAPFILE="/swapfile"
    local total_ram_gb target_swap_gb non_file_swap_gb swapfile_target_gb current_swapfile_gb
    total_ram_gb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
    if [ "$total_ram_gb" -gt 16 ]; then
      target_swap_gb=$(( total_ram_gb / 2 ))
    else
      target_swap_gb=8
    fi
    non_file_swap_gb=$(( $(swapon --show=NAME,SIZE --noheadings --bytes 2>/dev/null | grep -v "^${SWAPFILE}" | awk '{sum+=$2} END{printf "%d", sum/1024/1024/1024}') ))
    swapfile_target_gb=$(( target_swap_gb - non_file_swap_gb ))
    [ "$swapfile_target_gb" -lt 0 ] && swapfile_target_gb=0
    if [ -f "$SWAPFILE" ]; then
      current_swapfile_gb=$(( $(stat -c%s "$SWAPFILE") / 1024 / 1024 / 1024 ))
    else
      current_swapfile_gb=0
    fi
    if [ "$current_swapfile_gb" -eq "$swapfile_target_gb" ]; then
      echo "[OK] Swap is $(( $(free | awk '/^Swap:/{print $2}') / 1024 / 1024 ))GB (target: ${target_swap_gb}GB)"
    else
      # Only stop services when a swap change is actually needed
      echo "Swap needs resize (current swapfile: ${current_swapfile_gb}GB, target: ${swapfile_target_gb}GB) — stopping services..."
      systemctl stop docker-compose-app.service 2>/dev/null || true
      local current_total_gb
      current_total_gb=$(( $(free | awk '/^Swap:/{print $2}') / 1024 / 1024 ))
      echo "Resizing swap: ${current_total_gb}GB → ${target_swap_gb}GB total (RAM: ${total_ram_gb}GB, swapfile: ${swapfile_target_gb}GB)..."
      if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^${SWAPFILE}$"; then
        sudo swapoff "$SWAPFILE"
      fi
      if [ "$swapfile_target_gb" -gt 0 ]; then
        sudo rm -f "$SWAPFILE"
        sudo fallocate -l "${swapfile_target_gb}G" "$SWAPFILE" 2>/dev/null || \
          sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(( swapfile_target_gb * 1024 )) status=none
        sudo chmod 600 "$SWAPFILE"
        sudo mkswap "$SWAPFILE" > /dev/null
        sudo swapon "$SWAPFILE"
        if ! grep -q "^${SWAPFILE}" /etc/fstab; then
          echo "${SWAPFILE} none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
        fi
      else
        sudo rm -f "$SWAPFILE"
        sudo sed -i "\|^${SWAPFILE}|d" /etc/fstab
      fi
      echo "[OK] Swap set to $(( $(free | awk '/^Swap:/{print $2}') / 1024 / 1024 ))GB"
    fi

    if ! restart_service "upgrade"; then
      echo ""
      echo "[FAIL] Update FAILED — Docker Compose service could not be restarted."
      echo "   The new docker-compose.yml is in place but services are not running."
      echo "   To retry:  systemctl restart docker-compose-app.service"
      echo "   To revert: cli.sh rollback"
      rm -f "$caddyfile_tmp"
      rm -f "${INSTALL_DIR}/.ssh/authorized_keys"
      return 1
    fi

    if [ "$skip_cleanup" = false ]; then
      echo "Cleaning up unused Docker resources..."
      purge_docker
    else
      echo "Skipping Docker cleanup (--no-cleanup flag used)..."
    fi

    echo "Monitoring service startup..."
    wait_for_services
    services_ok=$?

    # Reinstate TimescaleDB extension if it was previously dropped.
    # A prior cli.sh version ran DROP EXTENSION timescaledb CASCADE during upgrades.
    # This restores it so catalog queries don't crash. Idempotent — no-op if already present.
    if ! $DOCKER_COMPOSE_CMD exec -T db psql -U calltelemetry -d calltelemetry_prod -tAc \
        "SELECT 1 FROM pg_extension WHERE extname='timescaledb'" 2>/dev/null | grep -q 1; then
      echo "Reinstating TimescaleDB extension (previously removed by older cli.sh)..."
      if $DOCKER_COMPOSE_CMD exec -T db psql -U calltelemetry -d calltelemetry_prod \
          -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE" 2>/dev/null; then
        echo "[OK] TimescaleDB extension restored"
      else
        echo "[WARN] TimescaleDB extension restore failed (non-critical)"
      fi
    fi

    # Platform migration: Node.js 22 (one-time, skip if already done)
    REQUIRED_NODE_MAJOR=22
    CURRENT_NODE_MAJOR=$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo "0")

    if [ "$CURRENT_NODE_MAJOR" -ge "$REQUIRED_NODE_MAJOR" ] 2>/dev/null; then
      echo "[OK] Node.js $(node --version) (meets requirement)"
    else
      echo "Migrating Node.js to v${REQUIRED_NODE_MAJOR} (current: v${CURRENT_NODE_MAJOR:-none})..."
      # Remove old Node packages
      sudo rpm -e --nodeps npm nodejs-full-i18n 2>/dev/null || true
      sudo rpm -e --nodeps nodejs 2>/dev/null || true
      # Enable Node 22 module stream (AlmaLinux AppStream default is v16)
      sudo dnf module reset nodejs -y &>/dev/null || true
      sudo dnf module enable nodejs:22 -y &>/dev/null || true
      sudo dnf install -y nodejs --allowerasing &>/dev/null
      NEW_NODE=$(node --version 2>/dev/null || echo "none")
      NEW_MAJOR=$(echo "$NEW_NODE" | sed 's/v\([0-9]*\).*/\1/' || echo "0")
      if [ "$NEW_MAJOR" -ge "$REQUIRED_NODE_MAJOR" ] 2>/dev/null; then
        echo "[OK] Node.js ${NEW_NODE} installed"
      else
        echo "[WARN] Node.js migration failed (got ${NEW_NODE}, need v${REQUIRED_NODE_MAJOR}+) — ct CLI may not work"
      fi
    fi

    # Update ct CLI (skip if node migration failed)
    if command -v node &>/dev/null && command -v npm &>/dev/null; then
      [ -f /usr/local/bin/ct ] && sudo rm -f /usr/local/bin/ct
      echo "Updating @calltelemetry/cli..."
      sudo npm install -g @calltelemetry/cli &>/dev/null && \
        CT_CLI_VER=$(npm list -g --depth=0 @calltelemetry/cli 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) && \
        echo "[OK] ct CLI updated to ${CT_CLI_VER:-unknown}" || echo "[WARN] ct CLI update failed (non-critical)"
    fi

    # Apply console loglevel fix for existing VMs
    # nft_compat / ip_set are loaded by Docker/firewalld and emit KERN_WARNING (level 4).
    # loglevel=3 on the kernel cmdline is reset by systemd; sysctl.d persists it.
    if [ ! -f /etc/sysctl.d/99-console-loglevel.conf ]; then
      echo "Applying console loglevel fix (suppresses nft_compat/ip_set warnings)..."
      echo "kernel.printk = 3 4 1 3" | sudo tee /etc/sysctl.d/99-console-loglevel.conf > /dev/null
      sudo sysctl -p /etc/sysctl.d/99-console-loglevel.conf > /dev/null
      echo "[OK] Console loglevel fix applied"
    fi

    # Migrate legacy ifcfg network configs to NetworkManager keyfile format
    # RHEL 9 / AlmaLinux 9 deprecated network-scripts ifcfg files; NM logs deprecation
    # warnings for any connection still using the ifcfg backend.
    if command -v nmcli &>/dev/null; then
      ifcfg_count=$(nmcli -t -f FILENAME connection show 2>/dev/null | grep -c 'ifcfg' || true)
      if [ "${ifcfg_count:-0}" -gt 0 ]; then
        echo "Migrating $ifcfg_count legacy ifcfg network config(s) to keyfile format..."
        sudo nmcli connection migrate &>/dev/null && echo "[OK] Network configs migrated to keyfile" || echo "[WARN] nmcli migrate failed (non-critical)"
      fi
    fi

    # Generate GRAFANA_PASSWORD if missing (required for dashboard provisioning)
    # Both web and grafana containers read this from .env as basic auth credential.
    if ! grep -q '^GRAFANA_PASSWORD=' "$ENV_FILE" 2>/dev/null; then
      local gf_pw
      gf_pw=$(openssl rand -hex 16)
      env_set "GRAFANA_PASSWORD" "$gf_pw"
      echo "[OK] Generated GRAFANA_PASSWORD"

      # Remove stale GRAFANA_TOKEN (replaced by GRAFANA_PASSWORD)
      env_remove "GRAFANA_TOKEN"

      # Reset Grafana admin password for existing volumes
      if $DOCKER_COMPOSE_CMD exec -T grafana grafana-cli admin reset-admin-password "$gf_pw" &>/dev/null; then
        echo "[OK] Grafana admin password synced"
      else
        echo "  ℹ️  Grafana container not running yet — password will apply on next start"
      fi
    fi

    # Cap Docker daemon at 90% RAM — reserve 10% for OS (kernel, systemd, sshd)
    DOCKER_DROPIN_DIR="/etc/systemd/system/docker.service.d"
    DOCKER_DROPIN_FILE="${DOCKER_DROPIN_DIR}/memory-limit.conf"
    if [ ! -f "$DOCKER_DROPIN_FILE" ] || grep -q 'MemoryMax=80%' "$DOCKER_DROPIN_FILE" 2>/dev/null; then
      echo "Applying Docker memory limit (90% of RAM)..."
      sudo mkdir -p "$DOCKER_DROPIN_DIR"
      printf '[Service]\nMemoryMax=90%%\n' | sudo tee "$DOCKER_DROPIN_FILE" > /dev/null
      sudo systemctl daemon-reload
      echo "[OK] Docker memory limit applied (90% of RAM)"
    fi

    # Mark partition drain as complete for ct-cli compatibility.
    # The actual drain runs automatically in onprem-start.sh (container entrypoint)
    # BEFORE the app starts — zero lock contention. It's a no-op if nothing to drain.
    if ! ct_migration_done "014_partition_drain" && [ "$(printf '%s\n' "0.8.6-rc166" "$version" | sort -V | head -n1)" = "0.8.6-rc166" ]; then
      ct_migration_mark "014_partition_drain" "applied"
      echo "[OK] Partition data migration handled by container startup (check docker logs for progress)"
    fi

    if [ $services_ok -eq 0 ]; then
      echo "[OK] Update complete! All services are running and ready."
    else
      echo "[WARN] Update applied, but startup checks failed (see errors above)."
      echo "  Run 'cli.sh status' to check current state."
    fi

  else
    echo "Failed to download new docker-compose.yml or other required files. No changes made."
  fi

  rm -f "$caddyfile_tmp"
  rm -f "${INSTALL_DIR}/.ssh/authorized_keys"
}

# Function to perform rollback to the old configuration
rollback() {
  BACKUP_FILE=$(ls -t $BACKUP_DIR/docker-compose-*.yml | head -n 1)

  if [ -f "$BACKUP_FILE" ];then
    cp "$BACKUP_FILE" "$ORIGINAL_FILE"
    echo "Rolled back to the previous docker-compose configuration from $BACKUP_FILE."
    fix_systemd_service_if_needed
    if ! restart_service "rollback"; then
      echo "[FAIL] Service restart failed after rollback."
      echo "   The rollback configuration is in place but services may not be running."
      echo "   Retry with: systemctl restart docker-compose-app.service"
      return 1
    fi
  else
    echo "No backup file found to rollback."
  fi
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
  if sudo $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -d calltelemetry_prod -U calltelemetry -c 'VACUUM FULL;'; then
    echo "[OK] Database vacuum completed successfully."
  else
    echo "[FAIL] Database vacuum failed."
    return 1
  fi

  echo "System compaction complete."
}

# Function to wait for services to be ready
# Flow: 1) Wait for containers 2) Wait for DB 3) Wait for migrations 4) Health check
# Returns 0 on full success, 1 if any phase failed or timed out
wait_for_services() {
  local max_wait=3600
  local poll_interval=5
  local wait_time=0
  local release_bin=$(get_release_binary)
  local services=("db" "web" "caddy" "vue-web" "traceroute" "nats")
  if is_jtapi_enabled; then
    services+=("jtapi-sidecar" "ct-media" "seaweedfs")
  fi

  # Track failures across phases
  local phase_failures=0
  local failed_phases=""

  echo ""
  echo "Starting services..."
  echo ""

  # Phase 1: Wait for containers to be running
  echo "Phase 1: Waiting for containers..."
  local containers_ok=false
  while [ $wait_time -lt 120 ]; do
    local all_running=true
    local status_line=""

    for service in "${services[@]}"; do
      local container=$($DOCKER_COMPOSE_CMD ps -q $service 2>/dev/null)
      if [ -n "$container" ]; then
        local status=$(docker inspect --format='{{.State.Status}}' $container 2>/dev/null)
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

    printf "\r  Containers:%s" "$status_line"

    if [ "$all_running" = true ]; then
      echo ""
      echo "  ✓ All containers running"
      containers_ok=true
      break
    fi

    sleep 3
    wait_time=$((wait_time + 3))
  done

  if [ "$containers_ok" != true ]; then
    echo ""
    echo "  [FAIL] Container startup timed out after 120s"
    echo "  Not running:%s" "$(echo "$status_line" | grep -oE '(✗|[WAIT])[^ ]+' | tr '\n' ' ')"
    phase_failures=$((phase_failures + 1))
    failed_phases="$failed_phases containers"
  fi
  echo ""

  # Phase 2: Wait for database to accept connections
  echo "Phase 2: Waiting for database..."
  local db_ok=false
  wait_time=0
  while [ $wait_time -lt 120 ]; do
    if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
      echo "  ✓ Database accepting connections"
      db_ok=true
      break
    fi
    printf "\r  Database: connecting... (%ds)" "$wait_time"
    sleep 3
    wait_time=$((wait_time + 3))
  done

  if [ "$db_ok" != true ]; then
    echo ""
    echo "  [FAIL] Database connection timed out after 120s"
    phase_failures=$((phase_failures + 1))
    failed_phases="$failed_phases database"
  fi
  echo ""

  # Phase 3: Wait for migrations to complete
  echo "Phase 3: Waiting for migrations..."
  wait_time=0
  local last_migration=""
  local migrations_complete=false
  local stable_total_count=""
  local release_total_count=""

  while [ $wait_time -lt $max_wait ]; do
    if [ -z "$release_total_count" ]; then
      release_total_count=$(get_release_migration_count "$release_bin")
      if ! [[ "$release_total_count" =~ ^[0-9]+$ ]] || [ "$release_total_count" -le 0 ]; then
        release_total_count=""
      fi
    fi

    # Try RPC first for accurate count
    local migration_raw=$(run_migration_status_rpc "$release_bin" 2>/dev/null)
    local pending_count=$(printf '%s\n' "$migration_raw" | awk -F= '/::pending_count=/{print $2; exit}')

    # Parse "Applied migrations: X/Y (Z%)" - use awk for portability
    local applied_count=$(printf '%s\n' "$migration_raw" | awk '/Applied migrations:/ {split($3, a, "/"); print a[1]}')
    local total_count=$(printf '%s\n' "$migration_raw" | awk '/Applied migrations:/ {split($3, a, "/"); print a[2]}')
    # Parse "Next pending: VERSION - NAME" for display
    local next_migration=$(printf '%s\n' "$migration_raw" | awk '/Next pending:/ {sub(/^.*Next pending: /, ""); print; exit}')

    if [[ "$total_count" =~ ^[0-9]+$ ]]; then
      stable_total_count="$total_count"
    fi

    # If RPC fails or returns no data, fall back to SQL
    if [ -z "$pending_count" ] || [ "$pending_count" = "error" ] || [ -z "$applied_count" ]; then
      # Get counts from database directly
      applied_count=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
        "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null | tr -d ' ')
      last_migration=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
        "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;" 2>/dev/null | tr -d ' ')

      if [ -n "$stable_total_count" ]; then
        total_count="$stable_total_count"
      elif [ -n "$release_total_count" ]; then
        total_count="$release_total_count"
      fi

      # Try to get the current running migration from logs
      local log_tail
      log_tail=$($DOCKER_COMPOSE_CMD logs --tail 100 web 2>&1 | normalize_container_log_lines)

      # Extract the currently running migration filename from Ecto's "== Running VERSION Name" log
      local running_migration
      running_migration=$(printf '%s\n' "$log_tail" | grep '== Running' | tail -1 | sed 's/.*== Running [0-9]* //' | sed 's/\.change\/0.*//' 2>/dev/null || echo "")

      # Also check the last "[Release]   - VERSION filename" entry for the pending list
      if [ -z "$running_migration" ]; then
        running_migration=$(printf '%s\n' "$log_tail" | grep '\[Release\]   - ' | tail -1 | sed 's/.*\[Release\]   - [0-9]* //' 2>/dev/null || echo "")
      fi
      running_migration=$(printf '%s' "$running_migration" | tr -d '\r' | sed 's/[[:space:]]*$//')

      # Check logs for migration completion
      if printf '%s\n' "$log_tail" | grep -q "All migrations completed successfully"; then
        migrations_complete=true
        pending_count=0
        total_count="${stable_total_count:-${release_total_count:-$applied_count}}"
      else
        # Check if app is still starting
        if printf '%s\n' "$log_tail" | grep -qE "Running migrations|Pending migrations"; then
          pending_count="running"
        else
          pending_count="checking"
        fi
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
      stable_total_count="$total_count"
    elif [ -n "$stable_total_count" ]; then
      total_count="$stable_total_count"
    elif [ -n "$release_total_count" ]; then
      total_count="$release_total_count"
    fi

    # Display status
    if [[ "$pending_count" =~ ^[0-9]+$ ]]; then
      if [ "$pending_count" -eq 0 ]; then
        # When Ecto reports 0 pending, applied_count IS the total — don't
        # let the file-count (release_total_count) create a false X/Y mismatch.
        local display_total="$applied_count"
        echo ""
        echo "  ✓ Migrations complete ($applied_count/$display_total)"
        migrations_complete=true
        break
      else
        if [ -n "$next_migration" ]; then
          printf "\r  Migrations: %s/%s applied, %s pending — running: %s    " "$applied_count" "$total_count" "$pending_count" "$next_migration"
        else
          printf "\r  Migrations: %s/%s applied, %s pending...    " "$applied_count" "$total_count" "$pending_count"
        fi
      fi
    elif [ "$pending_count" = "running" ]; then
      local display_total="${total_count:-?}"
      local display_name=""
      if [ -n "$running_migration" ]; then
        display_name=" — running: ${running_migration}"
      elif [ -n "$last_migration" ]; then
        display_name=" — latest applied: ${last_migration}"
      fi
      printf "\r  Migrations: %s/%s applied, running...%s    " "${applied_count:-?}" "$display_total" "$display_name"
    else
      local display_total="${total_count:-?}"
      printf "\r  Migrations: %s/%s applied, waiting for status...    " "${applied_count:-?}" "$display_total"
    fi

    sleep $poll_interval
    wait_time=$((wait_time + poll_interval))
  done

  if [ "$migrations_complete" != true ]; then
    echo ""
    echo "  [FAIL] Migration status unclear after ${max_wait}s"
    echo "  Check logs: $DOCKER_COMPOSE_CMD logs -f web"
    phase_failures=$((phase_failures + 1))
    failed_phases="$failed_phases migrations"
  fi
  echo ""

  # Phase 4: Health checks (only after migrations complete)
  echo "Phase 4: Health checks..."

  # Check web endpoint
  local web_healthy=false
  for i in {1..10}; do
    if $DOCKER_COMPOSE_CMD exec -T web curl -sf http://127.0.0.1:4080/healthz >/dev/null 2>&1; then
      web_healthy=true
      break
    fi
    sleep 2
  done

  if [ "$web_healthy" = true ]; then
    echo "  ✓ Web application healthy"
  else
    echo "  [FAIL] Web health check failed after 20s"
    phase_failures=$((phase_failures + 1))
    failed_phases="$failed_phases health-check"
  fi

  # Check for startup issues in logs
  local scheduler_errors=$($DOCKER_COMPOSE_CMD logs --tail 100 web 2>&1 | grep -c "not started: invalid task function" 2>/dev/null | tail -1 || echo "0")
  scheduler_errors=${scheduler_errors:-0}
  if [ "$scheduler_errors" -gt 0 ] 2>/dev/null; then
    echo "  [WARN] $scheduler_errors scheduler jobs failed (non-fatal)"
  fi

  # RPC check
  local rpc_ok=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts("ok")' 2>&1)
  if [[ "$rpc_ok" == *"ok"* ]]; then
    echo "  ✓ Application RPC responding"
  else
    echo "  [FAIL] Application RPC not responding"
    phase_failures=$((phase_failures + 1))
    failed_phases="$failed_phases rpc"
  fi

  echo ""
  show_system_activity
  echo ""

  if [ $phase_failures -eq 0 ]; then
    echo "[OK] Startup complete!"
    return 0
  else
    echo "[FAIL] Startup failed — $phase_failures phase(s) had errors:$failed_phases"
    echo ""
    echo "  Troubleshoot:"
    echo "    cli.sh status              Service health summary"
    echo "    cli.sh logs web --tail 50  Recent web logs"
    echo "    cli.sh logs db --tail 50   Recent database logs"
    return 1
  fi
}

# Function to purge unused Docker resources
purge_docker() {
  echo "Starting Docker cleanup..."

  echo -n "Removing stopped containers... "
  containers_removed=$(docker container prune -f 2>/dev/null | grep "Total reclaimed space" | awk '{print $4 $5}' || echo "0B")
  echo "done (${containers_removed})"

  echo -n "Removing unused networks... "
  networks_removed=$(docker network prune -f 2>/dev/null | wc -l)
  echo "done (${networks_removed} networks)"

  echo -n "Removing unused volumes... "
  volumes_output=$(docker volume prune -f 2>/dev/null)
  volumes_space=$(echo "$volumes_output" | grep "Total reclaimed space" | awk '{print $4 $5}' || echo "0B")
  echo "done (${volumes_space})"

  # Remove old calltelemetry images not in the active docker-compose.yml.
  # Suppress per-layer deletion output — just show count and space saved.
  echo -n "Removing old calltelemetry images... "
  local active_images=""
  if [ -f "$ORIGINAL_FILE" ]; then
    active_images=$(extract_images "$ORIGINAL_FILE" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
  fi

  local old_removed=0
  if [ -n "$active_images" ]; then
    docker images --format '{{.Repository}}:{{.Tag}}' | grep "calltelemetry/" | while read -r img; do
      if ! echo "$img" | grep -qE "$active_images"; then
        docker rmi "$img" >/dev/null 2>&1 && old_removed=$((old_removed + 1))
      fi
    done
  fi
  echo "done (${old_removed} old images removed)"

  echo -n "Removing dangling images... "
  docker image prune -f >/dev/null 2>&1
  echo "done"

  echo "Docker cleanup complete."
}

# Function to create a backup and retain only the last 5 backups
backup() {
  backup_folder_path=$BACKUP_FOLDER_PATH
  file_name="dump-"`date "+%Y-%m-%d-%H-%M-%S"`".sql"
  mkdir -p ${backup_folder_path}

  dbname=calltelemetry_prod
  username=calltelemetry

  backup_file=${backup_folder_path}/${file_name}

  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db pg_dump -U ${username} -d ${dbname} > ${backup_file}

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
      echo "  [OK] Seed job $job_id completed!"
      break
    fi
    if [ -n "$job_id" ] && [ "$oban_state" = " job=$job_id:discarded" ]; then
      echo ""
      echo "  [FAIL] Seed job $job_id failed (discarded). Check logs above."
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
      $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
        "SELECT pg_size_pretty(pg_database_size('calltelemetry_prod')) AS database_size;"
      ;;
    ""|status)
      echo "=== Database Status ==="
      if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
        echo "✓ Database: accepting connections"
      else
        echo "✗ Database: not accepting connections"
        return 1
      fi
      echo ""
      echo "=== Database Size ==="
      $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
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

get_release_migration_count() {
  local release_bin="${1:-$(get_release_binary)}"
  local release_root="${release_bin%/bin/*}"

  $DOCKER_COMPOSE_CMD exec -T web sh -lc "
    count=\$(find \"$release_root/lib\" -path '*/priv/repo/migrations/*.exs' -type f 2>/dev/null | wc -l)
    if [ \"\${count:-0}\" -eq 0 ]; then
      count=\$(find /app/lib -path '*/priv/repo/migrations/*.exs' -type f 2>/dev/null | wc -l)
    fi
    printf '%s' \"\$count\"
  " 2>/dev/null | tr -d '[:space:]'
}

print_sql_migration_snapshot() {
  local title="${1:-Database Migration Status}"

  echo "=== ${title} (SQL) ==="
  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "SELECT COUNT(*) AS total_migrations FROM schema_migrations;" 2>/dev/null || \
      echo "Unable to fetch total migrations via SQL."
  echo ""
  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
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
    echo "    [WARN] $service ports: container not found"
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
      echo "    [WARN] $service:$port not published to host; skipping port probe"
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
    echo "    [WARN] $service: container not found"
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
      echo "    [WARN] $service healthcheck: unhealthy"
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
      echo "    [WARN] $service healthcheck: $health"
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
    echo "✓ Migrations completed successfully (from logs)"
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
    echo "[WARN] Note: $scheduler_warnings scheduler jobs have invalid task functions (non-fatal)"
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

  $DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc '
    alias Cdrcisco.Repo
    import Ecto.Query

    try do
      migrations = Ecto.Migrator.migrations(Repo)
      ordered = Enum.sort_by(migrations, fn {_, version, _} -> version end)

      {applied, pending} =
        Enum.split_with(ordered, fn {status, _, _} -> status == :up end)

      total = length(ordered)
      applied_count = length(applied)
      pending_count = length(pending)

      percent =
        if total == 0 do
          100.0
        else
          Float.round(applied_count / total * 100, 1)
        end

      format_dt = fn
        %NaiveDateTime{} = dt ->
          dt
          |> NaiveDateTime.truncate(:second)
          |> NaiveDateTime.to_string()

        %DateTime{} = dt ->
          dt
          |> DateTime.truncate(:second)
          |> DateTime.to_string()

        other ->
          inspect(other)
      end

      latest =
        Repo.one(
          from sm in "schema_migrations",
            order_by: [desc: sm.version],
            limit: 1,
            select: %{version: sm.version, inserted_at: sm.inserted_at}
        )

      IO.puts("=== Migration Progress ===")

      if total == 0 do
        IO.puts("No migrations found!")
      else
        IO.puts("Applied migrations: #{applied_count}/#{total} (#{percent}%)")
        IO.puts("Pending migrations: #{pending_count}")

        case latest do
          %{version: version, inserted_at: timestamp} ->
            IO.puts("Latest applied: #{version} @ #{format_dt.(timestamp)}")

          _ ->
            IO.puts("Latest applied: none recorded")
        end

        IO.puts("")

        if pending_count > 0 do
          ordered_pending = pending
          {_, next_version, next_name} = hd(ordered_pending)
          IO.puts("Next pending: #{next_version} - #{next_name}")
          IO.puts("")
          IO.puts("=== Pending Queue ===")

          Enum.with_index(ordered_pending, 1)
          |> Enum.each(fn {{_, version, name}, idx} ->
            IO.puts("[#{idx}/#{pending_count}] #{version} - #{name}")
          end)

          IO.puts("")
        else
          IO.puts("All migrations are up to date!")
          IO.puts("")
        end

        applied_recent =
          applied
          |> Enum.reverse()
          |> Enum.take(5)
          |> Enum.reverse()

        if applied_recent == [] do
          IO.puts("=== Recent Applied ===")
          IO.puts("None applied yet.")
        else
          IO.puts("=== Recent Applied (Last #{length(applied_recent)}) ===")

          Enum.each(applied_recent, fn {_, version, name} ->
            IO.puts("UP   #{version} #{name}")
          end)
        end
      end

      IO.puts("::pending_count=#{pending_count}")
    rescue
      e ->
        IO.puts("Error checking migrations: #{inspect(e)}")
        IO.puts("::pending_count=error")
    end
  ' 2>&1
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
  rpc_test=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts("RPC connection successful")' 2>&1)
  if [[ "$rpc_test" == *"noconnection"* ]]; then
    echo "Error: Cannot connect to running application via RPC"
    echo "The application may still be starting up. Please wait and try again."
    echo "You can check logs with: $DOCKER_COMPOSE_CMD logs web"
    return 1
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
    raw_output=$(run_migration_status_rpc "$release_bin")
    local rpc_status=$?

    local pending_count
    pending_count=$(printf '%s\n' "$raw_output" | awk -F= '/::pending_count=/{print $2; exit}')
    if [ -z "$pending_count" ]; then
      pending_count="unknown"
    fi

    local display_output
    display_output=$(printf '%s\n' "$raw_output" | sed '/::pending_count=/d')

    if [ $rpc_status -ne 0 ] && [ "$pending_count" = "unknown" ]; then
      printf '%s\n' "$display_output"
      echo "Error: Failed to retrieve migration status (exit code $rpc_status)."
      return 1
    fi

    if [ "$watch_mode" = true ]; then
      echo "[$timestamp]"
    fi

    printf '%s\n' "$display_output"

    cat > "$report_file" <<EOF
Call Telemetry Database Migration Status Report
Generated: $timestamp
Release binary: $release_bin
==========================================

$display_output

EOF

    if [ "$watch_mode" = true ]; then
      echo "Last updated: $timestamp (report: $report_file)"
    else
      echo ""
      echo "[OK] Migration status check completed"
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
  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "SELECT version, inserted_at FROM schema_migrations ORDER BY version DESC LIMIT 10;"

  echo ""
  echo "=== Migration Count ==="
  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
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
    $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c "
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
    $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c "
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
  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
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
  table_exists=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table_name');" | tr -d ' ')

  if [ "$table_exists" != "t" ]; then
    echo "Error: Table '$table_name' does not exist in the database"
    return 1
  fi

  # Check if table has inserted_at column
  echo "Checking for 'inserted_at' column..."
  column_exists=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$table_name' AND column_name = 'inserted_at');" | tr -d ' ')

  if [ "$column_exists" != "t" ]; then
    echo "Error: Table '$table_name' does not have an 'inserted_at' column"
    echo "This command requires the table to have a timestamp column named 'inserted_at'"
    return 1
  fi

  # Get count of records to be deleted
  echo ""
  echo "Counting records to be deleted..."
  records_to_delete=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT COUNT(*) FROM $table_name WHERE inserted_at < NOW() - INTERVAL '$days days';" | tr -d ' ')

  if [ -z "$records_to_delete" ] || [ "$records_to_delete" = "0" ]; then
    echo "No records found older than $days days. Nothing to purge."
    return 0
  fi

  echo "Found $records_to_delete records to delete (older than $days days)"
  echo ""

  # Show date cutoff
  cutoff_date=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
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

  delete_result=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "DELETE FROM $table_name WHERE inserted_at < NOW() - INTERVAL '$days days';" 2>&1)

  end_time=$(date +%s)
  duration=$((end_time - start_time))

  echo "$delete_result"
  echo ""
  echo "[OK] Purge completed in ${duration} seconds"
  echo ""

  # Show updated table size
  echo "=== Updated Table Size ==="
  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c "
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
    echo "[OK] Migration run completed successfully"
  else
    echo ""
    echo "[FAIL] Migration run failed"
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
    echo "[OK] Partition drain completed — application restarting"
  else
    echo "[FAIL] Partition drain failed (exit code $drain_exit)"
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
    echo "[OK] Migration rollback completed successfully"
  else
    echo ""
    echo "[FAIL] Migration rollback failed"
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

# Function to show comprehensive application status and diagnostics
app_status() {
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
    echo "✓ JTAPI: enabled"
    echo ""
  fi

  # Check if web container is running
  web_container=$($DOCKER_COMPOSE_CMD $(get_compose_files) ps -q web 2>/dev/null)
  if [ -z "$web_container" ]; then
    echo "[FAIL] Web container not running"
    return 1
  fi

  container_status=$(docker inspect --format='{{.State.Status}}' "$web_container" 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    echo "[FAIL] Web container status: $container_status"
    return 1
  fi

  # Database connectivity
  echo "=== Database Status ==="
  if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "✓ Database: accepting connections"

    # Get applied migration count from DB
    migration_count=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
      "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null | tr -d ' ')

    # Get total expected migrations from release
    total_migrations=$(get_release_migration_count "$release_bin")
    total_migrations=${total_migrations:-"?"}

    echo "✓ Migrations in database: $migration_count / $total_migrations"

    # Get latest migration
    latest=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
      "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;" 2>/dev/null | tr -d ' ')
    echo "✓ Latest migration: $latest"
  else
    echo "[FAIL] Database: not accepting connections"
  fi
  echo ""

  # RPC status check
  echo "=== Application RPC Status ==="
  release_bin=$(get_release_binary)
  rpc_test=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts("ok")' 2>&1)
  if [[ "$rpc_test" == *"ok"* ]]; then
    echo "✓ RPC connection: working"

    # Get app-side migration status
    echo ""
    echo "=== Migration Status (from application) ==="
    $DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc '
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
    ' 2>&1
  else
    echo "[FAIL] RPC connection: failed"
    echo "   Application may still be starting up"
    echo "   Error: $rpc_test"
  fi
  echo ""

  # Host-facing service ports
  echo "=== Service Ports ==="
  local port_ok=true

  # CURRI HTTP (Caddy port 80)
  if probe_host_port 80 2; then
    echo "✓ CURRI HTTP (port 80): reachable"
  else
    echo "✗ CURRI HTTP (port 80): not reachable"
    port_ok=false
  fi

  # Admin HTTPS (Caddy port 443)
  if probe_host_port 443 2; then
    echo "✓ Admin HTTPS (port 443): reachable"
  else
    echo "✗ Admin HTTPS (port 443): not reachable"
    port_ok=false
  fi

  # SFTP (port 22)
  if probe_host_port 22 2; then
    echo "✓ SFTP (port 22): reachable"
  else
    echo "✗ SFTP (port 22): not reachable"
    port_ok=false
  fi

  if $port_ok; then
    echo ""
    echo "✓ All service ports healthy"
  fi
  echo ""

  # Check for scheduler/startup errors
  echo "=== Recent Startup Messages ==="
  $DOCKER_COMPOSE_CMD logs --tail 50 web 2>&1 | grep -E "(Migration|completed|scheduler|not started|error|Error|started)" | tail -15
  echo ""

  # Check for specific issues
  echo "=== Issue Detection ==="
  recent_logs=$($DOCKER_COMPOSE_CMD logs --tail 100 web 2>&1)

  # Check for migration completion
  if echo "$recent_logs" | grep -q "All migrations completed successfully"; then
    echo "✓ Migrations: completed successfully"
  elif echo "$recent_logs" | grep -q "Pending migrations"; then
    echo "Migrations: still running"
  else
    echo "? Migrations: status unknown from logs"
  fi

  # Check for scheduler errors
  scheduler_errors=$(echo "$recent_logs" | grep "not started: invalid task function" | wc -l)
  if [ "$scheduler_errors" -gt 0 ]; then
    echo "[WARN] Scheduler: $scheduler_errors jobs failed to start (invalid task function)"
    echo "   This may indicate version mismatch or missing modules"
    echo "$recent_logs" | grep "not started: invalid task function" | head -5 | sed 's/^/   /'
  else
    echo "✓ Scheduler: no startup errors detected"
  fi

  # Check for NATS connectivity
  if echo "$recent_logs" | grep -q "WorkflowNatsSupervisor"; then
    echo "✓ NATS: supervisor initialized"
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
        echo "[FAIL] Service restart failed after logging level change."
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
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" -subj "/CN=appliance.calltelemetry.internal"
    echo "Self-signed certificates generated."
  else
    echo "Certificates already exist and are valid. Skipping generation."
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
    echo "✗ Certificate directory not found: $cert_dir"
    return 1
  fi

  echo "Certificate directory: $cert_dir"
  echo ""

  # Check certificate file
  if [ -f "$cert_file" ]; then
    echo "✓ Certificate file: $cert_file"

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
    echo "✗ Certificate file not found: $cert_file"
  fi

  echo ""

  # Check key file
  if [ -f "$key_file" ]; then
    echo "✓ Private key: $key_file"

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
    echo "✗ Private key not found: $key_file"
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
sync_prefs_to_env_otel

# Main script logic
case "$1" in
  --help|-h|help)
    show_help
    ;;
  update)
    shift
    ensure_ip_forward
    nm_heal_connections
    generate_self_signed_certificates
    update "$@"
    ;;
  rollback)
    rollback
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
        echo "  cli.sh postgres profile <small|medium|large|show>  Set memory sizing profile"
        ;;
      profile)
        subaction="${3:-show}"
        case "$subaction" in
          show)
            current=$(env_get "PG_PROFILE")
            echo "Current PostgreSQL profile: ${current:-small (default)}"
            echo ""
            echo "  small  — 512MB shared_buffers,  8MB work_mem,  DB limit 3GB   (8GB RAM,  <40GB DB)"
            echo "  medium —   2GB shared_buffers, 32MB work_mem,  DB limit 8GB   (16GB RAM, 40-100GB DB)"
            echo "  large  —   8GB shared_buffers, 64MB work_mem,  DB limit 20GB  (32GB RAM, 100GB+ DB)"
            echo ""
            echo "Current values:"
            echo "  shared_buffers:        $(env_get PG_SHARED_BUFFERS || echo '512MB (default)')"
            echo "  effective_cache_size:  $(env_get PG_EFFECTIVE_CACHE_SIZE || echo '1536MB (default)')"
            echo "  work_mem:              $(env_get PG_WORK_MEM || echo '8MB (default)')"
            echo "  maintenance_work_mem:  $(env_get PG_MAINTENANCE_WORK_MEM || echo '256MB (default)')"
            echo "  wal_buffers:           $(env_get PG_WAL_BUFFERS || echo '64MB (default)')"
            echo "  parallel_workers:      $(env_get PG_PARALLEL_WORKERS || echo '2 (default)')/$(env_get PG_MAX_PARALLEL_WORKERS || echo '4 (default)')"
            echo "  autovacuum_workers:    $(env_get PG_AUTOVACUUM_WORKERS || echo '5 (default)')"
            echo "  db_cpu_limit:          $(env_get DB_CPU_LIMIT || echo '2.0 (default)')"
            echo "  db_mem_limit:          $(env_get DB_MEM_LIMIT || echo '2g (default — WARNING: too low for medium/large)')"
            echo "  web_mem_limit:         $(env_get WEB_MEM_LIMIT || echo '4g (default)')"
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
        db_size_kb=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db \
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
        if ! $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db \
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
          $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db \
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
              echo "[OK] Backup file deleted."
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
      *)
        echo "Unknown postgres command: $2"
        echo "Usage: cli.sh postgres [status|set <version>|upgrade <version>|profile <small|medium|large|show>]"
        exit 1
        ;;
    esac
    ;;

  jtapi)
    jtapi_cmd "$2"
    ;;

  storage)
    storage_cmd "$2"
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

      if command -v wget >/dev/null 2>&1; then
        if ! wget -q --show-progress "$bundle_url" -O "$config_bundle" 2>&1; then
          echo ""
          echo "[FAIL] ERROR: Failed to download config bundle for version $version"
          echo "URL: $bundle_url"
          echo ""
          echo "Make sure this version exists. Check:"
          echo "  https://github.com/calltelemetry/calltelemetry/releases"
          rm -f "$config_bundle"
          return 1
        fi
      elif command -v curl >/dev/null 2>&1; then
        if ! curl -fL --progress-bar "$bundle_url" -o "$config_bundle"; then
          echo ""
          echo "[FAIL] ERROR: Failed to download config bundle for version $version"
          rm -f "$config_bundle"
          return 1
        fi
      else
        echo "Error: Neither wget nor curl is available"
        return 1
      fi
      echo "[OK] Config bundle downloaded"
      echo ""

      # Step 2: Extract config bundle
      echo "Step 2: Extracting config bundle..."
      rm -rf "$bundle_dir"
      mkdir -p "$bundle_dir"
      tar -xzf "$config_bundle" -C "$bundle_dir" --strip-components=1
      sanitize_metadata_artifacts "$bundle_dir"
      rm -f "$config_bundle"
      echo "[OK] Config bundle extracted"
      echo ""

      # Step 3: Extract image list and pull images
      echo "Step 3: Pulling Docker images..."
      cd "$bundle_dir" || return 1

      if [ ! -f "docker-compose.yml" ]; then
        echo "[FAIL] ERROR: docker-compose.yml not found in bundle"
        cd "$start_dir"
        rm -rf "$bundle_dir"
        return 1
      fi

      local images=$(grep -E '^\s*image:' docker-compose.yml | sed 's/.*image:[[:space:]]*["'\'']*\([^"'\'']*\)["'\'']*[[:space:]]*$/\1/' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sort -u)

      echo "Images to download:"
      echo "$images" | while read img; do [ -n "$img" ] && echo "  - $img"; done
      echo ""

      local pull_failed=false
      local image_count=0
      local total_images=$(echo "$images" | wc -l | tr -d ' ')

      for img in $images; do
        [ -z "$img" ] && continue
        image_count=$((image_count + 1))
        echo "[$image_count/$total_images] Pulling: $img"
        if ! docker pull "$img"; then
          echo "[WARN] Warning: Failed to pull $img"
          pull_failed=true
        fi
      done

      if [ "$pull_failed" = true ]; then
        echo ""
        echo "[WARN] Warning: Some images failed to pull. Bundle may be incomplete."
      fi

      # Step 4: Save Docker images to tar
      echo ""
      echo "Step 4: Saving Docker images to images.tar..."
      # shellcheck disable=SC2086
      if docker save $images -o images.tar; then
        echo "[OK] Images saved: $(du -h images.tar | cut -f1)"
      else
        echo "[FAIL] ERROR: Failed to save Docker images"
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

      echo "=== Applying Offline Bundle ==="
      echo "Bundle: $bundle_file"
      echo ""

      # Create temp extraction directory
      local extract_dir="offline-extract-$$"
      mkdir -p "$extract_dir"

      echo "Extracting bundle..."
      tar -xzf "$bundle_file" -C "$extract_dir"
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
        [ -f "$inner_dir/grafana/dashboards/calltelemetry-overview.json" ] && cp "$inner_dir/grafana/dashboards/calltelemetry-overview.json" ./grafana/dashboards/
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
        echo "[FAIL] Service restart failed after offline bundle apply."
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
          echo "[FAIL] ERROR: Failed to download bundle for version $version"
          echo ""
          echo "The version may not exist or network error occurred."
          echo "Check available versions at: https://github.com/calltelemetry/calltelemetry/releases"
          rm -f "$bundle_file"
          return 1
        fi
      elif command -v curl >/dev/null 2>&1; then
        if ! curl -fL --progress-bar "$bundle_url" -o "$bundle_file"; then
          echo ""
          echo "[FAIL] ERROR: Failed to download bundle for version $version"
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
            echo "[OK] Checksum verified"
          else
            echo "[WARN] Checksum mismatch - file may be corrupted"
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
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state, wait_event_type, wait_event FROM pg_stat_activity WHERE state <> 'idle' AND query NOT ILIKE '%pg_stat_activity%' ORDER BY duration DESC LIMIT 20;"
        echo ""

        echo "--- 3. All Connections & Long-Running Queries ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT pid, usename, application_name, client_addr, now() - query_start AS duration, state, LEFT(query, 100) as query_preview FROM pg_stat_activity WHERE query_start IS NOT NULL ORDER BY query_start ASC LIMIT 20;"
        echo ""

        echo "--- 4. Blocked Queries (lock contention) ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT blocked_locks.pid AS blocked_pid, blocked_activity.usename AS blocked_user, blocking_locks.pid AS blocking_pid, blocking_activity.usename AS blocking_user, LEFT(blocked_activity.query,50) AS blocked_stmt, LEFT(blocking_activity.query,50) AS blocking_stmt FROM pg_catalog.pg_locks blocked_locks JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid JOIN pg_catalog.pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation AND blocking_locks.pid <> blocked_locks.pid JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid WHERE NOT blocked_locks.granted;"
        echo ""

        echo "--- 5. Tables with High Sequential Scans (missing indexes) ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT relname, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch, n_tup_ins, n_tup_upd, n_tup_del FROM pg_stat_user_tables ORDER BY seq_scan DESC LIMIT 15;"
        echo ""

        echo "--- 6. Connection Count by State ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT count(*) as total_connections, state, usename FROM pg_stat_activity GROUP BY state, usename ORDER BY count(*) DESC;"
        echo ""

        echo "--- 7. Dead Tuples (needs vacuum) ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT schemaname, relname, n_dead_tup, n_live_tup, last_vacuum, last_autovacuum FROM pg_stat_user_tables WHERE n_dead_tup > 1000 ORDER BY n_dead_tup DESC LIMIT 10;"
        echo ""

        echo "--- 8. Active MV Refreshes, Index Builds, Vacuum, Analyze ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT pid, now() - query_start AS duration, state, wait_event_type, LEFT(query, 80) as operation FROM pg_stat_activity WHERE query ILIKE '%REFRESH MATERIALIZED%' OR query ILIKE '%CREATE INDEX%' OR query ILIKE '%REINDEX%' OR query ILIKE '%VACUUM%' OR query ILIKE '%ANALYZE%';"
        echo ""

        echo "--- 9. Index Creation Progress ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT p.pid, p.datname, p.command, p.phase, p.blocks_total, p.blocks_done, ROUND(100.0 * p.blocks_done / NULLIF(p.blocks_total, 0), 2) AS pct_done, LEFT(a.query, 60) as query FROM pg_stat_progress_create_index p JOIN pg_stat_activity a ON p.pid = a.pid;"
        echo ""

        echo "--- 10. Vacuum Progress ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT p.pid, p.datname, p.relid::regclass AS table_name, p.phase, p.heap_blks_total, p.heap_blks_scanned, ROUND(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 2) AS pct_done FROM pg_stat_progress_vacuum p;"
        echo ""

        echo "--- 11. List All Materialized Views ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT matviewname, hasindexes, ispopulated FROM pg_matviews ORDER BY matviewname;"
        echo ""

        echo "--- 12. Autovacuum Workers Active ---"
        docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -c "SELECT pid, datname, relid::regclass AS table_name, phase, heap_blks_total, heap_blks_scanned, index_vacuum_count FROM pg_stat_progress_vacuum WHERE datname IS NOT NULL;"
        echo ""

        echo "=== Database Diagnostics Complete ==="
        ;;
      db-watch|dbwatch)
        echo "=== Live Database Activity Monitor ==="
        echo "Refreshing every 2 seconds. Press Ctrl+C to stop."
        echo ""
        watch -n 2 -d -- docker exec calltelemetry-db-1 env PGPASSWORD=postgres psql -U calltelemetry -d calltelemetry_prod -xc \
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
                    echo "  [WARN] Corporate proxy detected! The firewall is doing SSL inspection."
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
    echo "[OK] Services stopped."
    ;;
  start)
    echo "Starting Call Telemetry services..."
    ensure_bind_mount_files
    systemctl start docker-compose-app.service
    echo "[OK] Services started."
    ;;

  # Advanced commands
  build-appliance)
    ensure_ip_forward
    build_appliance
    ;;
  prep-cluster-node)
    prep_cluster_node
    ;;

  "")
    show_help
    ;;
  *)
    echo "Unknown command: $1"
    echo "Run 'cli.sh --help' for usage information."
    ;;
esac
