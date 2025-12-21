#!/bin/bash

# ASCII Art Logo
cat << "EOF"

   ______      ____   ______     __                    __
  / ____/___ _/ / /  /_  __/__  / /__  ____ ___  ___  / /________  __
 / /   / __ `/ / /    / / / _ \/ / _ \/ __ `__ \/ _ \/ __/ ___/ / / /
/ /___/ /_/ / / /    / / /  __/ /  __/ / / / / /  __/ /_/ /  / /_/ /
\____/\__,_/_/_/    /_/  \___/_/\___/_/ /_/ /_/\___/\__/_/   \__, /
                                                            /____/

https://calltelemetry.com
EOF

# Directory for storing backups and other directories to be cleared
BACKUP_DIR="/home/calltelemetry/backups"
BACKUP_FOLDER_PATH="/home/calltelemetry/db_dumps"
SFTP_DIR="sftp/*"
POSTGRES_DATA_DIR="postgres-data"
# Original and backup docker-compose files
ORIGINAL_FILE="docker-compose.yml"
TEMP_FILE="temp-docker-compose.yml"
SCRIPT_URL="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/cli.sh"
CLI_INSTALL_PATH="/home/calltelemetry/cli.sh"
# Detect if running from a pipe (curl ... | sh) vs local file
if [ -f "$0" ] && [ "$0" != "sh" ] && [ "$0" != "bash" ] && [ "$0" != "-bash" ]; then
  CURRENT_SCRIPT_PATH="$0"
else
  CURRENT_SCRIPT_PATH="$CLI_INSTALL_PATH"
fi
PREP_SCRIPT_URL="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/prep.sh"
PROMETHEUS_CONFIG_URL="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/versions/prometheus/prometheus.yml"
GRAFANA_ASSETS_BASE_URL="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/versions"
GRAFANA_ASSET_PATHS=(
  "grafana/provisioning/datasources/calltelemetry.yml"
  "grafana/provisioning/dashboards/calltelemetry.yaml"
  "grafana/dashboards/calltelemetry-overview.json"
  "grafana/dashboards/curri-observability.json"
  "grafana/dashboards/caddy-overview.json"
)

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
      echo "⚠️  Unable to adjust permissions for $dir automatically."
      echo "   Please run: sudo chown -R 472:472 '$dir' && sudo chmod -R u+rwX,go+rX '$dir'"
    fi
  done
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

# Auto-fix systemd service file to match detected docker compose command
# This ensures the service uses the same command syntax as the CLI
fix_systemd_service_if_needed() {
  local SERVICE_FILE="/etc/systemd/system/docker-compose-app.service"

  [ -f "$SERVICE_FILE" ] || return 0

  local needs_update=false
  local current_cmd=""
  local target_cmd=""

  # Detect what the service file currently uses
  if grep -q "/usr/bin/docker-compose" "$SERVICE_FILE"; then
    current_cmd="docker-compose"
  elif grep -q "/usr/bin/docker compose" "$SERVICE_FILE"; then
    current_cmd="docker compose"
  else
    return 0  # Unknown format, don't touch
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
    sudo cp "$SERVICE_FILE" "${SERVICE_FILE}.backup" 2>/dev/null

    if [ "$target_cmd" = "docker compose" ]; then
      sudo sed -i 's|/usr/bin/docker-compose|/usr/bin/docker compose|g' "$SERVICE_FILE"
    else
      sudo sed -i 's|/usr/bin/docker compose|/usr/bin/docker-compose|g' "$SERVICE_FILE"
    fi

    sudo systemctl daemon-reload
    echo "Systemd service updated to use '$target_cmd'."
  fi
}

# Function to display help
show_help() {
  echo "Usage: cli.sh <command> [options]"
  echo
  echo "Application Commands:"
  echo "  status              Show application status and diagnostics"
  echo "  update [version]    Update to specified version (default: latest)"
  echo "                      Options: --force-upgrade, --no-cleanup, --ipv6"
  echo "  rollback            Roll back to previous docker-compose configuration"
  echo "  reset               Stop application, remove data, and restart"
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
  echo "  db version          Show PostgreSQL version"
  echo
  echo "Database Upgrade Commands:"
  echo "  db upgrade [ver]    Upgrade PostgreSQL to version (default: 17)"
  echo "                      Options: --force, --backup, --method=dump-restore"
  echo "  db upgrade-check    Run pre-flight checks before upgrading"
  echo "  db upgrade-status   Show upgrade status and history"
  echo
  echo "Migration Commands:"
  echo "  migrate             Show migration status (default)"
  echo "  migrate run         Run pending migrations"
  echo "  migrate rollback [n] Rollback n migrations (default: 1)"
  echo "  migrate history     Show last 10 migrations from database"
  echo "  migrate watch       Watch migration progress continuously"
  echo
  echo "Configuration Commands:"
  echo "  logging [level]     Show or set logging level (debug/info/warning/error)"
  echo "  ipv6 [enable|disable] Show or toggle IPv6 support"
  echo "  certs               Show certificate status and expiry"
  echo "  certs reset         Delete and regenerate self-signed certificates"
  echo
  echo "Maintenance Commands:"
  echo "  selfupdate          Update CLI script to latest version"
  echo "  fix-service         Update systemd service to use modern docker compose"
  echo "  docker              Show Docker status (containers, images, networks)"
  echo "  docker network      Show detailed network configuration"
  echo "  docker prune        Remove unused Docker resources"
  echo
  echo "Offline/Air-Gap Commands:"
  echo "  offline download [version]  Download images & configs for air-gapped install"
  echo "  offline apply <bundle.tar>  Apply an offline bundle to this system"
  echo "  offline list                List images in current docker-compose.yml"
  echo
  echo "Diagnostic Commands:"
  echo "  diag tesla <ipv4|ipv6> <url>    Test TCP + HTTP connectivity"
  echo "  diag raw_tcp <ipv4|ipv6> <url>  Test raw TCP socket only"
  echo "  diag capture <secs> [filter] [file]  Capture packets with tcpdump"
  echo "  diag database               Run comprehensive database diagnostics"
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
extract_images() {
  local compose_file="$1"
  grep -E "image.*calltelemetry" "$compose_file" | sed 's/.*image: *"//' | sed 's/".*//' | grep -v "^$"
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
    if docker manifest inspect "$image" >/dev/null 2>&1; then
      echo "✓ Available"
    else
      echo "✗ Not available"
      all_available=false
      unavailable_images="$unavailable_images$image\n"
    fi
  done
  
  if [ "$all_available" = true ]; then
    echo "✅ All images are available online"
    return 0
  else
    echo "❌ Some images are not available:"
    echo -e "$unavailable_images"
    return 1
  fi
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
    echo "⚠️  Failed to download Prometheus configuration from $PROMETHEUS_CONFIG_URL"
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
      echo "⚠️  Failed to download Grafana asset: ${asset}"
      rm -f "$tmp_file"
    fi
  done

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

# Function to get current version from docker-compose.yml
get_current_version() {
  if [ -f "$ORIGINAL_FILE" ]; then
    # Extract version from vue-web image tag
    current_image=$(grep -E "calltelemetry/vue:" "$ORIGINAL_FILE" | head -1 | sed 's/.*calltelemetry\/vue://' | sed 's/".*//')
    if [ -n "$current_image" ]; then
      echo "$current_image"
    else
      echo "unknown"
    fi
  else
    echo "not installed"
  fi
}

# =============================================================================
# PostgreSQL Version Management & Upgrade Functions
# =============================================================================

# Metadata: Application version -> Required PostgreSQL version
# Format: "app_version:pg_version" (pg_version 0 means any version is acceptable)
POSTGRES_VERSION_REQUIREMENTS=(
  "0.8.6:17"   # Version 0.8.6+ requires PostgreSQL 17
  "0.9.0:17"   # Future versions will also require 17+
)

# Directory for storing PostgreSQL upgrade state
PG_UPGRADE_STATE_DIR="/home/calltelemetry/.pg_upgrade"

# Get the current PostgreSQL major version from the running database container
get_postgres_version() {
  local version=""

  # Try to get version from running database
  version=$($DOCKER_COMPOSE_CMD exec -T db psql -U calltelemetry -d calltelemetry_prod -t -c "SHOW server_version;" 2>/dev/null | tr -d '[:space:]' | cut -d'.' -f1)

  if [ -n "$version" ] && [ "$version" -gt 0 ] 2>/dev/null; then
    echo "$version"
    return 0
  fi

  # Fallback: try to get from docker image tag
  if [ -f "$ORIGINAL_FILE" ]; then
    local image_tag=$(grep -E "postgresql:" "$ORIGINAL_FILE" | head -1 | sed 's/.*postgresql://' | sed 's/".*//' | cut -d'-' -f1)
    if [ -n "$image_tag" ] && [ "$image_tag" -gt 0 ] 2>/dev/null; then
      echo "$image_tag"
      return 0
    fi
  fi

  # Fallback: check PG_VERSION file in data directory
  if [ -f "./postgres-data/data/PG_VERSION" ]; then
    cat "./postgres-data/data/PG_VERSION" 2>/dev/null
    return 0
  fi

  # For bitnami layout
  if [ -f "./postgres-data/postgresql/data/PG_VERSION" ]; then
    cat "./postgres-data/postgresql/data/PG_VERSION" 2>/dev/null
    return 0
  fi

  echo "unknown"
  return 1
}

# Get the PostgreSQL data directory version (from PG_VERSION file)
get_postgres_data_version() {
  local version=""

  # Check standard location
  if [ -f "./postgres-data/data/PG_VERSION" ]; then
    version=$(cat "./postgres-data/data/PG_VERSION" 2>/dev/null)
  # Check bitnami layout
  elif [ -f "./postgres-data/postgresql/data/PG_VERSION" ]; then
    version=$(cat "./postgres-data/postgresql/data/PG_VERSION" 2>/dev/null)
  fi

  if [ -n "$version" ]; then
    echo "$version"
    return 0
  fi

  echo "unknown"
  return 1
}

# Get required PostgreSQL version for a given application version
get_required_postgres_version() {
  local app_version="$1"

  # Handle "latest" as requiring the newest PostgreSQL
  if [ "$app_version" = "latest" ]; then
    echo "17"
    return 0
  fi

  # Extract major.minor.patch from version string
  if [[ "$app_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"

    # Check version requirements (from highest to lowest)
    # 0.9.0+ requires PG 17
    if [ "$major" -gt 0 ] || ([ "$major" -eq 0 ] && [ "$minor" -ge 9 ]); then
      echo "17"
      return 0
    fi

    # 0.8.6+ requires PG 17
    if [ "$major" -eq 0 ] && [ "$minor" -eq 8 ] && [ "$patch" -ge 6 ]; then
      echo "17"
      return 0
    fi
  fi

  # Older versions work with PG 14
  echo "14"
  return 0
}

# Check if PostgreSQL upgrade is needed for a target application version
check_postgres_upgrade_needed() {
  local target_app_version="$1"
  local current_pg_version=$(get_postgres_version)
  local required_pg_version=$(get_required_postgres_version "$target_app_version")

  if [ "$current_pg_version" = "unknown" ]; then
    echo "unknown"
    return 2
  fi

  if [ "$current_pg_version" -lt "$required_pg_version" ] 2>/dev/null; then
    echo "required"
    return 0
  fi

  echo "not_required"
  return 1
}

# Pre-flight checks for PostgreSQL upgrade
pg_upgrade_precheck() {
  local target_pg_version="$1"
  local current_pg_version=$(get_postgres_version)
  local errors=0

  echo "=== PostgreSQL Upgrade Pre-flight Checks ==="
  echo ""
  echo "Current PostgreSQL Version: $current_pg_version"
  echo "Target PostgreSQL Version:  $target_pg_version"
  echo ""

  # Check 1: Current version is valid
  echo -n "Checking current PostgreSQL version... "
  if [ "$current_pg_version" = "unknown" ]; then
    echo "✗ FAILED"
    echo "  Unable to detect current PostgreSQL version."
    echo "  Ensure the database container is running."
    errors=$((errors + 1))
  elif [ "$current_pg_version" -ge "$target_pg_version" ] 2>/dev/null; then
    echo "✗ NOT NEEDED"
    echo "  Current version ($current_pg_version) >= target version ($target_pg_version)"
    echo "  No upgrade required."
    return 2
  else
    echo "✓ OK (version $current_pg_version -> $target_pg_version)"
  fi

  # Check 2: Database is accessible and healthy
  echo -n "Checking database connectivity... "
  if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "✓ OK"
  else
    echo "✗ FAILED"
    echo "  Database is not accepting connections."
    errors=$((errors + 1))
  fi

  # Check 3: Check for active connections (warn only)
  echo -n "Checking active connections... "
  local conn_count=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT count(*) FROM pg_stat_activity WHERE datname = 'calltelemetry_prod' AND state != 'idle';" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$conn_count" ] && [ "$conn_count" -gt 1 ]; then
    echo "⚠ WARNING"
    echo "  $conn_count active connections detected."
    echo "  Consider stopping the application before upgrading."
  else
    echo "✓ OK"
  fi

  # Check 4: Disk space
  # pg_upgrade with --link uses hard links (minimal extra space needed)
  # We need space for: WAL files, temp files, and some catalog data (~500MB-1GB typically)
  # Plus space if user wants a SQL backup before upgrade
  echo -n "Checking disk space... "
  local db_size_bytes=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT pg_database_size('calltelemetry_prod');" 2>/dev/null | tr -d '[:space:]')

  if [ -z "$db_size_bytes" ] || [ "$db_size_bytes" = "" ]; then
    db_size_bytes=0
  fi

  local db_size_gb=$(echo "scale=2; $db_size_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
  # pg_upgrade with --link needs minimal space (just catalogs/WAL), estimate 1GB + 10% of DB
  local required_bytes=$((1073741824 + db_size_bytes / 10))
  local required_gb=$(echo "scale=2; $required_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "1")
  local available_bytes=$(df --block-size=1 . 2>/dev/null | awk 'NR==2 {print $4}')
  local available_gb=$(echo "scale=2; $available_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")

  if [ -z "$available_bytes" ] || [ "$available_bytes" -lt "$required_bytes" ] 2>/dev/null; then
    echo "✗ FAILED"
    echo "  Required: ~${required_gb}GB (for pg_upgrade catalogs and WAL)"
    echo "  Available: ${available_gb}GB"
    errors=$((errors + 1))
  else
    echo "✓ OK (${available_gb}GB available)"
    echo "  Database size: ${db_size_gb}GB"
    echo "  Note: pg_upgrade uses hard links, so minimal extra space needed."
    echo "  Optional backup (--backup flag) would need additional ${db_size_gb}GB."
  fi

  # Check 5: Data directory integrity
  echo -n "Checking data directory... "
  local data_version=$(get_postgres_data_version)
  if [ "$data_version" = "unknown" ]; then
    echo "✗ FAILED"
    echo "  Cannot find PostgreSQL data directory or PG_VERSION file."
    errors=$((errors + 1))
  elif [ "$data_version" != "$current_pg_version" ]; then
    echo "✗ FAILED"
    echo "  Data directory version ($data_version) doesn't match running version ($current_pg_version)"
    errors=$((errors + 1))
  else
    echo "✓ OK (version $data_version)"
  fi

  # Check 6: Check for unsupported extensions or features
  echo -n "Checking for upgrade blockers... "
  local blockers=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT count(*) FROM pg_extension WHERE extname IN ('pglogical', 'postgis');" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$blockers" ] && [ "$blockers" -gt 0 ]; then
    echo "⚠ WARNING"
    echo "  Some extensions may require special handling during upgrade."
  else
    echo "✓ OK"
  fi

  # Check 7: Ensure pg_upgrade state directory exists
  echo -n "Checking upgrade state directory... "
  if mkdir -p "$PG_UPGRADE_STATE_DIR" 2>/dev/null; then
    echo "✓ OK"
  else
    echo "⚠ WARNING (could not create $PG_UPGRADE_STATE_DIR)"
  fi

  echo ""
  echo "=== Pre-flight Check Summary ==="
  if [ $errors -eq 0 ]; then
    echo "✓ All checks passed. Ready to upgrade."
    return 0
  else
    echo "✗ $errors check(s) failed. Please resolve issues before upgrading."
    return 1
  fi
}

# Main PostgreSQL upgrade function using pg_upgrade
db_upgrade() {
  local target_version="${1:-17}"
  local force_upgrade="${2:-false}"
  local create_backup="${3:-false}"
  local current_version=$(get_postgres_version)

  echo "=== PostgreSQL Database Upgrade ==="
  echo ""
  echo "This will upgrade your PostgreSQL database from version $current_version to $target_version."
  echo "The upgrade uses pg_upgrade with --link for an efficient in-place upgrade."
  echo ""
  echo "Note: pg_upgrade uses hard links, so your original data files remain intact"
  echo "until the upgrade is verified. This is your safety net for recovery."
  echo ""

  # Validate target version
  if ! [[ "$target_version" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid target version. Please specify a major version number (e.g., 17)"
    return 1
  fi

  if [ "$target_version" -lt 14 ] || [ "$target_version" -gt 18 ]; then
    echo "Error: Target version must be between 14 and 18"
    return 1
  fi

  # Run pre-flight checks
  if ! pg_upgrade_precheck "$target_version"; then
    local precheck_result=$?
    if [ $precheck_result -eq 2 ]; then
      echo ""
      echo "No upgrade needed. Database is already at version $current_version."
      return 0
    fi
    if [ "$force_upgrade" != "true" ]; then
      echo ""
      echo "Pre-flight checks failed. Use 'db upgrade $target_version --force' to proceed anyway."
      return 1
    fi
    echo ""
    echo "⚠️  Proceeding despite failed pre-flight checks (--force specified)"
  fi

  echo ""
  echo "=== Starting PostgreSQL Upgrade ==="
  echo ""

  # Step 1: Optional backup
  if [ "$create_backup" = "true" ]; then
    echo "Step 1: Creating database backup (--backup flag specified)..."
    backup
    echo ""
  else
    echo "Step 1: Skipping SQL backup (use --backup flag if you want one)"
    echo "  Note: Your original data directory will be preserved as a backup."
    echo ""
  fi

  # Step 2: Record upgrade state
  echo "Step 2: Recording upgrade state..."
  mkdir -p "$PG_UPGRADE_STATE_DIR"
  cat > "$PG_UPGRADE_STATE_DIR/upgrade.state" << EOF
UPGRADE_STARTED=$(date -Iseconds)
SOURCE_VERSION=$current_version
TARGET_VERSION=$target_version
STATUS=in_progress
EOF
  echo "Upgrade state saved to $PG_UPGRADE_STATE_DIR/upgrade.state"
  echo ""

  # Step 3: Stop the application services (keep only db for now)
  echo "Step 3: Stopping application services..."
  $DOCKER_COMPOSE_CMD stop web vue-web traceroute nats caddy 2>/dev/null || true
  echo "Application services stopped."
  echo ""

  # Step 4: Stop the database
  echo "Step 4: Stopping database container..."
  $DOCKER_COMPOSE_CMD stop db
  echo "Database stopped."
  echo ""

  # Step 5: Determine data directory layout
  echo "Step 5: Analyzing data directory structure..."
  local data_dir=""
  local bitnami_layout=false

  if [ -f "./postgres-data/postgresql/data/PG_VERSION" ]; then
    data_dir="./postgres-data/postgresql/data"
    bitnami_layout=true
    echo "Detected Bitnami PostgreSQL layout"
  elif [ -f "./postgres-data/data/PG_VERSION" ]; then
    data_dir="./postgres-data/data"
    echo "Detected standard PostgreSQL layout"
  elif [ -f "./postgres-data/PG_VERSION" ]; then
    data_dir="./postgres-data"
    echo "Detected simple PostgreSQL layout"
  else
    echo "Error: Could not find PostgreSQL data directory"
    # Restore upgrade state
    echo "STATUS=failed" >> "$PG_UPGRADE_STATE_DIR/upgrade.state"
    echo "ERROR=data_directory_not_found" >> "$PG_UPGRADE_STATE_DIR/upgrade.state"
    return 1
  fi
  echo "Data directory: $data_dir"
  echo ""

  # Step 6: Create new data directory for target version
  echo "Step 6: Preparing new data directory..."
  local new_data_parent="./postgres-data-pg${target_version}"
  local new_data_dir=""

  if [ "$bitnami_layout" = true ]; then
    new_data_dir="${new_data_parent}/postgresql/data"
  else
    new_data_dir="${new_data_parent}/data"
  fi

  mkdir -p "$(dirname "$new_data_dir")"
  echo "New data directory will be: $new_data_dir"
  echo ""

  # Step 7: Run pg_upgrade in a container
  echo "Step 7: Running pg_upgrade..."
  echo "This may take several minutes depending on database size."
  echo ""

  # Create pg_upgrade script
  local upgrade_script="$PG_UPGRADE_STATE_DIR/run_upgrade.sh"
  cat > "$upgrade_script" << 'UPGRADE_SCRIPT'
#!/bin/bash
set -e

OLD_VERSION=$1
NEW_VERSION=$2
OLD_DATADIR=$3
NEW_DATADIR=$4

echo "Initializing new data directory..."
/usr/lib/postgresql/${NEW_VERSION}/bin/initdb -D ${NEW_DATADIR} -U calltelemetry --encoding=UTF8 --locale=C

echo "Running pg_upgrade..."
cd /tmp
/usr/lib/postgresql/${NEW_VERSION}/bin/pg_upgrade \
  --old-datadir=${OLD_DATADIR} \
  --new-datadir=${NEW_DATADIR} \
  --old-bindir=/usr/lib/postgresql/${OLD_VERSION}/bin \
  --new-bindir=/usr/lib/postgresql/${NEW_VERSION}/bin \
  --username=calltelemetry \
  --jobs=$(nproc) \
  --link

echo "pg_upgrade completed successfully!"
UPGRADE_SCRIPT
  chmod +x "$upgrade_script"

  # Determine the absolute paths for mounting
  local abs_old_data=$(cd "$(dirname "$data_dir")" && pwd)/$(basename "$data_dir")
  local abs_new_data_parent=$(mkdir -p "$new_data_parent" && cd "$new_data_parent" && pwd)
  local abs_upgrade_state=$(cd "$PG_UPGRADE_STATE_DIR" && pwd)

  # Log file for capturing upgrade output
  local upgrade_log="$PG_UPGRADE_STATE_DIR/upgrade-$(date +%Y%m%d-%H%M%S).log"

  # Run the upgrade container with both PostgreSQL versions
  # Using tianon/docker-pg-upgrade which has multiple PG versions
  echo "Pulling pg_upgrade container image..."
  echo ""

  local upgrade_result=0

  # Try the dedicated upgrade image first
  if docker pull tianon/postgres-upgrade:${current_version}-to-${target_version} 2>/dev/null; then
    echo "Using tianon/postgres-upgrade:${current_version}-to-${target_version}"
    echo ""
    echo "Running pg_upgrade (output logged to $upgrade_log)..."
    echo ""

    docker run --rm \
      -v "${abs_old_data}:/var/lib/postgresql/${current_version}/data:rw" \
      -v "${abs_new_data_parent}:/var/lib/postgresql/${target_version}:rw" \
      -e POSTGRES_USER=calltelemetry \
      -e POSTGRES_PASSWORD=postgres \
      -e PGUSER=calltelemetry \
      tianon/postgres-upgrade:${current_version}-to-${target_version} 2>&1 | tee "$upgrade_log"

    upgrade_result=${PIPESTATUS[0]}
  else
    echo "Dedicated upgrade image not available."
    echo "Using postgres:${target_version} with pg_upgrade..."
    echo ""

    docker pull postgres:${target_version}

    # Run upgrade using the official postgres container
    docker run --rm \
      -v "${abs_old_data}:/var/lib/postgresql/${current_version}/data:rw" \
      -v "${abs_new_data_parent}:/var/lib/postgresql/${target_version}:rw" \
      -v "${abs_upgrade_state}:/upgrade:rw" \
      -e POSTGRES_USER=calltelemetry \
      -e POSTGRES_PASSWORD=postgres \
      -e PGUSER=calltelemetry \
      postgres:${target_version} \
      bash -c "
        set -e

        echo '=== Installing PostgreSQL ${current_version} binaries ==='
        apt-get update
        apt-get install -y postgresql-${current_version}

        NEW_DATADIR=/var/lib/postgresql/${target_version}/data

        echo ''
        echo '=== Initializing new data directory ==='
        mkdir -p \$NEW_DATADIR
        chown postgres:postgres \$NEW_DATADIR
        chmod 700 \$NEW_DATADIR
        su postgres -c \"/usr/lib/postgresql/${target_version}/bin/initdb -D \$NEW_DATADIR -U calltelemetry --encoding=UTF8\"

        echo ''
        echo '=== Running pg_upgrade ==='
        cd /tmp
        su postgres -c \"/usr/lib/postgresql/${target_version}/bin/pg_upgrade \\
          --old-datadir=/var/lib/postgresql/${current_version}/data \\
          --new-datadir=\$NEW_DATADIR \\
          --old-bindir=/usr/lib/postgresql/${current_version}/bin \\
          --new-bindir=/usr/lib/postgresql/${target_version}/bin \\
          --username=calltelemetry \\
          --link \\
          --verbose\"

        echo ''
        echo '=== pg_upgrade completed successfully! ==='
      " 2>&1 | tee "$upgrade_log"

    upgrade_result=${PIPESTATUS[0]}
  fi

  # Check result and show appropriate message
  if [ $upgrade_result -ne 0 ]; then
    echo ""
    echo "============================================================"
    echo "✗ pg_upgrade FAILED (exit code: $upgrade_result)"
    echo "============================================================"
    echo ""
    echo "Full log saved to: $upgrade_log"
    echo ""
    echo "--- Last 30 lines of output ---"
    tail -30 "$upgrade_log"
    echo "--- End of log excerpt ---"
    echo ""
    echo "YOUR DATA IS SAFE:"
    echo "  Original data directory is intact: $data_dir"
    echo "  Full log available at: $upgrade_log"
    echo ""
    echo "ALTERNATIVE - Dump/Restore Method:"
    echo "  You can try the dump/restore method instead:"
    echo ""
    echo "    cli.sh db upgrade ${target_version} --method=dump-restore"
    echo ""
    echo "  This creates a SQL dump of your database and restores it"
    echo "  into a fresh PostgreSQL ${target_version} instance."
    echo "============================================================"

    echo "STATUS=failed" >> "$PG_UPGRADE_STATE_DIR/upgrade.state"
    echo "ERROR=pg_upgrade_failed" >> "$PG_UPGRADE_STATE_DIR/upgrade.state"
    echo "EXIT_CODE=$upgrade_result" >> "$PG_UPGRADE_STATE_DIR/upgrade.state"
    echo "LOG_FILE=$upgrade_log" >> "$PG_UPGRADE_STATE_DIR/upgrade.state"

    # Restart services since we stopped them
    echo ""
    echo "Restarting services with original database..."
    $DOCKER_COMPOSE_CMD up -d
    return 1
  fi

  echo ""
  echo "✓ pg_upgrade completed successfully!"
  echo ""

  # Step 8: Update docker-compose.yml to use new PostgreSQL version
  echo "Step 8: Updating docker-compose.yml..."

  # Backup current compose file
  cp "$ORIGINAL_FILE" "$BACKUP_DIR/docker-compose-pre-pg-upgrade-$(date +%Y%m%d-%H%M%S).yml"

  # Update the PostgreSQL image
  sed -i "s|bitnamilegacy/postgresql:${current_version}|postgres:${target_version}|g" "$ORIGINAL_FILE"
  sed -i "s|postgres:${current_version}|postgres:${target_version}|g" "$ORIGINAL_FILE"

  # Update volume mount for official postgres (different layout than bitnami)
  if [ "$bitnami_layout" = true ]; then
    # Change from bitnami layout to official postgres layout
    sed -i 's|./postgres-data:/bitnami/postgresql|./postgres-data:/var/lib/postgresql/data|g' "$ORIGINAL_FILE"
  fi

  echo "docker-compose.yml updated to use postgres:${target_version}"
  echo ""

  # Step 9: Swap data directories
  echo "Step 9: Swapping data directories..."
  local old_data_backup="./postgres-data-pg${current_version}-backup-$(date +%Y%m%d-%H%M%S)"

  # For bitnami layout, we need to restructure
  if [ "$bitnami_layout" = true ]; then
    # Move old data to backup
    mv "./postgres-data" "$old_data_backup"

    # Create new structure for official postgres
    mkdir -p "./postgres-data"
    mv "${abs_new_data_parent}/data" "./postgres-data/" 2>/dev/null || \
    mv "${abs_new_data_parent}/postgresql/data" "./postgres-data/data" 2>/dev/null || \
    mv "${abs_new_data_parent}" "./postgres-data/data"

    # Ensure proper permissions
    sudo chown -R 999:999 "./postgres-data" 2>/dev/null || true
  else
    mv "./postgres-data" "$old_data_backup"
    mv "$new_data_parent" "./postgres-data"
    sudo chown -R 999:999 "./postgres-data" 2>/dev/null || true
  fi

  echo "Data directories swapped."
  echo "Old data backed up to: $old_data_backup"
  echo ""

  # Step 10: Start the new database
  echo "Step 10: Starting upgraded database..."
  $DOCKER_COMPOSE_CMD up -d db

  # Wait for database to be ready
  echo "Waiting for database to start..."
  local max_wait=60
  local waited=0
  while [ $waited -lt $max_wait ]; do
    if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
      echo "✓ Database is ready!"
      break
    fi
    sleep 2
    waited=$((waited + 2))
    echo "  Waiting... ($waited/$max_wait seconds)"
  done

  if [ $waited -ge $max_wait ]; then
    echo "⚠ Database did not start within $max_wait seconds."
    echo "  Check logs with: $DOCKER_COMPOSE_CMD logs db"
    return 1
  fi

  # Verify the new version
  local new_version=$(get_postgres_version)
  echo ""
  echo "Verifying upgrade..."
  echo "  Running PostgreSQL version: $new_version"

  if [ "$new_version" != "$target_version" ]; then
    echo "⚠ Warning: Expected version $target_version but got $new_version"
  fi
  echo ""

  # Step 11: Run post-upgrade tasks
  echo "Step 11: Running post-upgrade optimization..."
  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c "ANALYZE;" 2>/dev/null || true
  echo "Database statistics updated."
  echo ""

  # Step 12: Start remaining services
  echo "Step 12: Starting application services..."
  $DOCKER_COMPOSE_CMD up -d
  echo ""

  # Update upgrade state
  cat >> "$PG_UPGRADE_STATE_DIR/upgrade.state" << EOF
UPGRADE_COMPLETED=$(date -Iseconds)
STATUS=completed
NEW_VERSION=$new_version
OLD_DATA_BACKUP=$old_data_backup
EOF

  echo "=== PostgreSQL Upgrade Complete ==="
  echo ""
  echo "Summary:"
  echo "  Previous version: $current_version"
  echo "  Current version:  $new_version"
  echo "  Old data backup:  $old_data_backup"
  echo "  Upgrade log:      $PG_UPGRADE_STATE_DIR/upgrade.state"
  echo ""
  echo "The upgrade was successful! Your application should now be running."
  echo ""
  echo "If you encounter any issues:"
  echo "  1. Check logs: $DOCKER_COMPOSE_CMD logs"
  echo "  2. Restore from backup: cli.sh db restore <backup-file>"
  echo "  3. Rollback: cli.sh rollback"

  return 0
}

# Fallback upgrade method using dump/restore
db_upgrade_dump_restore() {
  local target_version="${1:-17}"
  local current_version=$(get_postgres_version)

  echo "=== PostgreSQL Upgrade via Dump/Restore ==="
  echo ""
  echo "This method creates a full SQL dump and restores it to a new PostgreSQL version."
  echo "It's slower but more reliable than pg_upgrade."
  echo ""

  # Step 1: Create a fresh backup
  echo "Step 1: Creating database dump..."
  local dump_file="$BACKUP_FOLDER_PATH/pg-upgrade-dump-$(date +%Y%m%d-%H%M%S).sql"

  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db pg_dumpall -U calltelemetry > "$dump_file"

  if [ ! -s "$dump_file" ]; then
    echo "Error: Database dump failed or is empty"
    return 1
  fi

  echo "Dump created: $dump_file ($(du -h "$dump_file" | cut -f1))"
  echo ""

  # Step 2: Stop all services
  echo "Step 2: Stopping all services..."
  $DOCKER_COMPOSE_CMD down
  echo ""

  # Step 3: Move old data directory
  echo "Step 3: Backing up old data directory..."
  local old_data_backup="./postgres-data-pg${current_version}-backup-$(date +%Y%m%d-%H%M%S)"
  mv "./postgres-data" "$old_data_backup"
  mkdir -p "./postgres-data"
  echo "Old data moved to: $old_data_backup"
  echo ""

  # Step 4: Update docker-compose.yml
  echo "Step 4: Updating docker-compose.yml..."
  cp "$ORIGINAL_FILE" "$BACKUP_DIR/docker-compose-pre-pg-upgrade-$(date +%Y%m%d-%H%M%S).yml"

  # Update PostgreSQL image to official postgres
  sed -i "s|bitnamilegacy/postgresql:${current_version}|postgres:${target_version}|g" "$ORIGINAL_FILE"
  sed -i "s|postgres:${current_version}|postgres:${target_version}|g" "$ORIGINAL_FILE"

  # Update volume mount for official postgres
  sed -i 's|./postgres-data:/bitnami/postgresql|./postgres-data:/var/lib/postgresql/data|g' "$ORIGINAL_FILE"

  # Update environment variables for official postgres
  sed -i 's/POSTGRESQL_MAX_CONNECTIONS/POSTGRES_MAX_CONNECTIONS/g' "$ORIGINAL_FILE"

  echo "docker-compose.yml updated."
  echo ""

  # Step 5: Start new database
  echo "Step 5: Starting new PostgreSQL ${target_version} database..."
  $DOCKER_COMPOSE_CMD up -d db

  # Wait for database initialization
  echo "Waiting for database to initialize..."
  sleep 10

  local max_wait=60
  local waited=0
  while [ $waited -lt $max_wait ]; do
    if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d postgres >/dev/null 2>&1; then
      echo "✓ Database is ready!"
      break
    fi
    sleep 2
    waited=$((waited + 2))
    echo "  Waiting... ($waited/$max_wait seconds)"
  done
  echo ""

  # Step 6: Restore the dump
  echo "Step 6: Restoring database from dump..."
  echo "This may take a while for large databases..."

  # Create the database if it doesn't exist
  $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d postgres -c \
    "CREATE DATABASE calltelemetry_prod WITH OWNER calltelemetry;" 2>/dev/null || true

  # Restore the dump
  cat "$dump_file" | $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d postgres

  echo "Database restored."
  echo ""

  # Step 7: Verify and start services
  echo "Step 7: Verifying and starting application..."
  local new_version=$(get_postgres_version)
  echo "Running PostgreSQL version: $new_version"

  $DOCKER_COMPOSE_CMD up -d
  echo ""

  # Update upgrade state
  cat >> "$PG_UPGRADE_STATE_DIR/upgrade.state" << EOF
UPGRADE_METHOD=dump_restore
UPGRADE_COMPLETED=$(date -Iseconds)
STATUS=completed
NEW_VERSION=$new_version
DUMP_FILE=$dump_file
OLD_DATA_BACKUP=$old_data_backup
EOF

  echo "=== PostgreSQL Upgrade Complete ==="
  echo ""
  echo "Summary:"
  echo "  Previous version: $current_version"
  echo "  Current version:  $new_version"
  echo "  Dump file:        $dump_file"
  echo "  Old data backup:  $old_data_backup"
  echo ""

  return 0
}

# Display PostgreSQL upgrade status and history
pg_upgrade_status() {
  echo "=== PostgreSQL Upgrade Status ==="
  echo ""

  local current_version=$(get_postgres_version)
  local data_version=$(get_postgres_data_version)

  echo "Current PostgreSQL Version: $current_version"
  echo "Data Directory Version:     $data_version"
  echo ""

  # Show docker-compose PostgreSQL configuration
  if [ -f "$ORIGINAL_FILE" ]; then
    echo "Docker Compose Configuration:"
    grep -E "postgresql:|postgres:" "$ORIGINAL_FILE" | head -1 | sed 's/^/  /'
  fi
  echo ""

  # Show upgrade state if exists
  if [ -f "$PG_UPGRADE_STATE_DIR/upgrade.state" ]; then
    echo "Last Upgrade State:"
    cat "$PG_UPGRADE_STATE_DIR/upgrade.state" | sed 's/^/  /'
  else
    echo "No previous upgrade state found."
  fi
  echo ""

  # Show what version would be required for latest app
  echo "Version Requirements:"
  echo "  Current app version: $(get_current_version)"
  echo "  For 'latest' app:    PostgreSQL $(get_required_postgres_version "latest") required"

  # Check if upgrade is needed
  local upgrade_check=$(check_postgres_upgrade_needed "latest")
  if [ "$upgrade_check" = "required" ]; then
    echo ""
    echo "⚠️  PostgreSQL upgrade will be required to update to latest version."
    echo "   Run 'cli.sh db upgrade' to upgrade PostgreSQL first."
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
      echo "Restarting Docker Compose service..."
      systemctl restart docker-compose-app.service
      echo "Docker Compose service restarted."
      echo ""
      wait_for_services
      ;;
    disable)
      echo "Disabling IPv6..."
      configure_ipv6 "$ORIGINAL_FILE" false
      echo ""
      fix_systemd_service_if_needed
      echo "Restarting Docker Compose service..."
      systemctl restart docker-compose-app.service
      echo "Docker Compose service restarted."
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
  cli_update  # Ensure the CLI script is up-to-date

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
      *)
        if [ -z "$version" ]; then
          version="$1"
        fi
        shift
        ;;
    esac
  done

  # Set default version if not specified
  version=${version:-"latest"}

  if [ "$version" == "latest" ]; then
    url="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/docker-compose.yml"
  else
    url="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/versions/$version.yaml"
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
        echo "❌ ERROR: Insufficient RAM for version 0.8.4 and higher"
        echo "   Version 0.8.4+ requires 8GB RAM (minimum 7GB detected)"
        echo ""
        echo "To proceed anyway, use: $0 update $version --force-upgrade"
        echo "WARNING: Proceeding with insufficient RAM may cause performance issues or failures"
        return 1
      fi
      echo "✅ RAM requirement met (8GB recommended for optimal performance)"
      echo ""
    else
      echo "⚠️  WARNING: Skipping RAM check (--force-upgrade flag used)"
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
      echo "❌ ERROR: Insufficient disk space for upgrade"
      echo "   Available: ${free_percent}% free"
      echo "   Required: 10% free minimum"
      echo ""
      echo "To proceed anyway, use: $0 update $version --force-upgrade"
      echo "WARNING: Proceeding with low disk space may cause upgrade failures"
      return 1
    fi
    echo "✅ Sufficient disk space available"
    echo ""
  else
    echo "⚠️  WARNING: Skipping disk space check (--force-upgrade flag used)"
    echo ""
  fi

  # Check for CentOS Stream 8 and display warning
  if [ -f /etc/os-release ]; then
    if grep -qi "centos.*stream.*8\|CentOS.*Stream.*8\|CENTOS.*STREAM.*8" /etc/os-release; then
      echo "⚠️  WARNING: This appliance is running CentOS 8 Stream, and the OS has reached end of life in the Red Hat ecosystem. Please download a new appliance from calltelemetry.com, and copy the postgres and certificate folder over to the new appliance. If you continue, older Docker versions may not work with new builds in 0.8.4 releases. Sleeping for 5 seconds. Press CTRL-C to cancel."
      sleep 5
    fi
  fi

  # Check PostgreSQL version requirements for target application version
  echo "Checking PostgreSQL requirements..."
  local current_pg_version=$(get_postgres_version)
  local required_pg_version=$(get_required_postgres_version "$version")
  local pg_upgrade_needed=$(check_postgres_upgrade_needed "$version")

  if [ "$current_pg_version" != "unknown" ]; then
    echo "  Current PostgreSQL: $current_pg_version"
    echo "  Required for $version: PostgreSQL $required_pg_version"

    if [ "$pg_upgrade_needed" = "required" ]; then
      echo ""
      echo "❌ ERROR: PostgreSQL upgrade required before updating to $version"
      echo ""
      echo "   Your database is running PostgreSQL $current_pg_version, but version $version"
      echo "   requires PostgreSQL $required_pg_version or higher."
      echo ""
      echo "   Please upgrade PostgreSQL first using:"
      echo "     cli.sh db upgrade $required_pg_version"
      echo ""
      echo "   To check upgrade requirements:"
      echo "     cli.sh db upgrade-check $required_pg_version"
      echo ""
      if [ "$force_upgrade" = false ]; then
        echo "   To proceed anyway (NOT RECOMMENDED), use:"
        echo "     $0 update $version --force-upgrade"
        echo ""
        echo "   WARNING: Proceeding without upgrading PostgreSQL will likely cause"
        echo "   the application to fail to start due to database incompatibility."
        return 1
      else
        echo "⚠️  WARNING: Proceeding with PostgreSQL version mismatch (--force-upgrade specified)"
        echo "   This may cause the application to fail!"
        echo ""
        sleep 3
      fi
    else
      echo "✅ PostgreSQL version is compatible"
    fi
  else
    echo "⚠️  Could not detect PostgreSQL version (database may not be running)"
    echo "   Will continue with update, but PostgreSQL compatibility should be verified."
  fi
  echo ""

  # Check Docker version and update if needed
  echo "Checking Docker version..."
  docker_version=$(docker --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -1 | cut -d. -f1)

  if [ -z "$docker_version" ]; then
    echo "⚠️  WARNING: Docker not found or not responding"
  elif [ "$docker_version" -lt 26 ]; then
    echo "⚠️  WARNING: Docker version $docker_version detected - Docker 26+ is required"
    echo "Docker is outdated, updating Docker packages..."
    echo "Running Docker package updates..."
    sudo dnf update -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo "Docker package update completed."
    echo ""

    # Verify Docker version after update
    echo "Verifying Docker version after update..."
    updated_docker_version=$(docker --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+' | head -1 | cut -d. -f1)

    if [ -z "$updated_docker_version" ]; then
      echo "❌ ERROR: Docker update failed - Docker is not responding"
      echo "   Docker 26+ is required to continue"
      echo "   Please manually update Docker and try again"
      return 1
    elif [ "$updated_docker_version" -lt 26 ]; then
      echo "❌ ERROR: Docker update failed - Docker is still on version $updated_docker_version"
      echo "   Docker 26+ is required to continue"
      echo "   Current version: $updated_docker_version"
      echo "   Required version: 26 or higher"
      echo ""
      echo "   Please manually update Docker to version 26+ and try again"
      echo "   You may need to check your repository configuration or available packages"
      return 1
    else
      echo "✅ Docker successfully updated to version $updated_docker_version"
      echo ""
    fi
  else
    echo "✅ Docker version $docker_version is supported"
  fi

  timestamp=$(date "+%Y-%m-%d-%H-%M-%S")
  timestamped_backup_file="$BACKUP_DIR/docker-compose-$timestamp.yml"

  if [ -f "$ORIGINAL_FILE" ]; then
    cp "$ORIGINAL_FILE" "$timestamped_backup_file"
    echo "Existing docker-compose.yml backed up to $timestamped_backup_file"
  fi

  echo "Downloading new configuration..."
  if ! wget "$url" -O "$TEMP_FILE" 2>/dev/null; then
    echo "❌ Failed to download configuration file from: $url"
    echo "Please verify that version $version exists"
    rm -f "$TEMP_FILE"
    return 1
  fi

  if ! download_prometheus_config "$TEMP_FILE"; then
    echo "⚠️  Prometheus configuration download failed; continuing with existing file if present."
  fi

  download_grafana_assets "$TEMP_FILE"

  # Check image availability before proceeding unless --force-upgrade is specified
  if [ "$force_upgrade" = false ]; then
    if ! check_image_availability "$TEMP_FILE"; then
      echo ""
      echo "❌ Cannot proceed with upgrade - some images are not available"
      echo "Please ensure all images are built and pushed to the registry"
      echo ""
      echo "To proceed anyway, use: $0 update $version --force-upgrade"
      echo "WARNING: Proceeding without verifying image availability may cause upgrade failures"
      rm -f "$TEMP_FILE"
      return 1
    fi
  else
    echo "⚠️  WARNING: Skipping image availability check (--force-upgrade flag used)"
    echo ""
  fi

  echo ""
  echo "Pulling Docker images..."
  if ! $DOCKER_COMPOSE_CMD -f "$TEMP_FILE" pull; then
    echo "❌ Failed to pull Docker images"
    rm -f "$TEMP_FILE"
    return 1
  fi
  echo "✅ All images pulled successfully"

  # Extract and display the image versions
  echo ""
  echo "Image versions to be deployed:"
  extract_images "$TEMP_FILE" | while read image; do
    echo "  - $image"
  done

  echo ""
  echo "⚠️  You are about to upgrade from $current_version to $version"
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

  # Download NATS configuration file
  nats_conf_url="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/nats.conf"
  nats_conf_file="nats.conf"
  wget "$nats_conf_url" -O "$nats_conf_file"

  # Download the Caddyfile
  CADDYFILE_URL="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/versions/caddy/Caddyfile"
  caddyfile_tmp=$(mktemp)
  wget -q "$CADDYFILE_URL" -O "$caddyfile_tmp"

  if [ -f "$TEMP_FILE" ] && [ -f "$nats_conf_file" ] && [ -f "$caddyfile_tmp" ]; then
    mv "$TEMP_FILE" "$ORIGINAL_FILE"
    echo "New docker-compose.yml moved to production."
    echo "NATS configuration file downloaded."
    echo "Caddyfile downloaded."

    # Configure IPv6 settings based on --ipv6 flag
    configure_ipv6 "$ORIGINAL_FILE" "$enable_ipv6"

    if [ -f "./Caddyfile" ]; then
      if ! diff "$caddyfile_tmp" "./Caddyfile" > /dev/null; then
        echo "Update available for the Caddyfile. Updating now..."
        cp "$caddyfile_tmp" "./Caddyfile"
        echo "Caddyfile updated."
      else
        echo "Caddyfile is up-to-date."
      fi
    else
      echo "Caddyfile not found. Installing new Caddyfile..."
      cp "$caddyfile_tmp" "./Caddyfile"
      echo "Caddyfile installed."
    fi

    fix_systemd_service_if_needed
    echo "Restarting Docker Compose service..."
    systemctl restart docker-compose-app.service
    echo "Docker Compose service restarted."

    if [ "$skip_cleanup" = false ]; then
      echo "Cleaning up unused Docker resources..."
      purge_docker
    else
      echo "Skipping Docker cleanup (--no-cleanup flag used)..."
    fi

    echo "Monitoring service startup..."
    wait_for_services

    if [ $? -eq 0 ]; then
      echo "✅ Update complete! All services are running and ready."
    else
      echo "⚠️  Update complete, but some services may still be initializing."
      echo "This is normal during major upgrades with SQL index rebuilds."
      echo "Monitor progress with: $DOCKER_COMPOSE_CMD logs -f"
      echo "Check CPU usage with: top (high postgresql CPU is normal during index rebuilds)"
    fi
  else
    echo "Failed to download new docker-compose.yml or other required files. No changes made."
  fi

  rm -f "$caddyfile_tmp"
  rm -f /home/calltelemetry/.ssh/authorized_keys
}

# Function to perform rollback to the old configuration
rollback() {
  BACKUP_FILE=$(ls -t $BACKUP_DIR/docker-compose-*.yml | head -n 1)

  if [ -f "$BACKUP_FILE" ];then
    cp "$BACKUP_FILE" "$ORIGINAL_FILE"
    echo "Rolled back to the previous docker-compose configuration from $BACKUP_FILE."
    fix_systemd_service_if_needed
    echo "Restarting Docker Compose service..."
    systemctl restart docker-compose-app.service
    echo "Docker Compose service restarted."
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
  sudo $DOCKER_COMPOSE_CMD up -d db

  echo "Waiting for the database service to be fully operational..."
  sleep 15

  echo "Verifying database connectivity..."
  if ! sudo $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "Error: Database is not ready. Cannot perform vacuum."
    return 1
  fi

  echo "Compacting PostgreSQL database (this may take several minutes)..."
  if sudo $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -d calltelemetry_prod -U calltelemetry -c 'VACUUM FULL;'; then
    echo "✅ Database vacuum completed successfully."
  else
    echo "❌ Database vacuum failed."
    return 1
  fi

  echo "System compaction complete."
}

# Function to wait for services to be ready
# Flow: 1) Wait for containers 2) Wait for DB 3) Wait for migrations 4) Health check
wait_for_services() {
  local max_wait=600
  local poll_interval=5
  local wait_time=0
  local release_bin=$(get_release_binary)
  local services=("db" "web" "caddy" "vue-web" "traceroute" "nats")

  echo ""
  echo "Starting services..."
  echo ""

  # Phase 1: Wait for containers to be running
  echo "Phase 1: Waiting for containers..."
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
          status_line="$status_line ⏳$service"
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
      break
    fi

    sleep 3
    wait_time=$((wait_time + 3))
  done
  echo ""

  # Phase 2: Wait for database to accept connections
  echo "Phase 2: Waiting for database..."
  wait_time=0
  while [ $wait_time -lt 120 ]; do
    if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
      echo "  ✓ Database accepting connections"
      break
    fi
    printf "\r  Database: connecting... (%ds)" "$wait_time"
    sleep 3
    wait_time=$((wait_time + 3))
  done
  echo ""

  # Phase 3: Wait for migrations to complete
  echo "Phase 3: Waiting for migrations..."
  wait_time=0
  local last_migration=""
  local migrations_complete=false

  while [ $wait_time -lt $max_wait ]; do
    # Try RPC first for accurate count
    local migration_raw=$(run_migration_status_rpc "$release_bin" 2>/dev/null)
    local pending_count=$(printf '%s\n' "$migration_raw" | awk -F= '/::pending_count=/{print $2; exit}')

    # Parse "Applied migrations: X/Y (Z%)" - use awk for portability
    local applied_count=$(printf '%s\n' "$migration_raw" | awk '/Applied migrations:/ {split($3, a, "/"); print a[1]}')
    local total_count=$(printf '%s\n' "$migration_raw" | awk '/Applied migrations:/ {split($3, a, "/"); print a[2]}')

    # If RPC fails or returns no data, fall back to SQL
    if [ -z "$pending_count" ] || [ "$pending_count" = "error" ] || [ -z "$applied_count" ]; then
      # Get counts from database directly
      applied_count=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
        "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null | tr -d ' ')
      last_migration=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
        "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;" 2>/dev/null | tr -d ' ')

      # Check logs for migration completion
      if $DOCKER_COMPOSE_CMD logs --tail 50 web 2>&1 | grep -q "All migrations completed successfully"; then
        migrations_complete=true
        pending_count=0
        total_count="$applied_count"
      else
        # Check if app is still starting
        if $DOCKER_COMPOSE_CMD logs --tail 20 web 2>&1 | grep -qE "Running migrations|Pending migrations"; then
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

    # Display status
    if [[ "$pending_count" =~ ^[0-9]+$ ]]; then
      if [ "$pending_count" -eq 0 ]; then
        # Use applied_count as total if total is missing
        local display_total="${total_count:-$applied_count}"
        echo ""
        echo "  ✓ Migrations complete ($applied_count/$display_total)"
        migrations_complete=true
        break
      else
        printf "\r  Migrations: %s/%s applied, %s pending...    " "$applied_count" "$total_count" "$pending_count"
      fi
    elif [ "$pending_count" = "running" ]; then
      printf "\r  Migrations: %s applied, running... (latest: %s)    " "${applied_count:-?}" "${last_migration:-?}"
    else
      printf "\r  Migrations: %s applied, waiting for status...    " "${applied_count:-?}"
    fi

    sleep $poll_interval
    wait_time=$((wait_time + poll_interval))
  done

  if [ "$migrations_complete" != true ]; then
    echo ""
    echo "  ⚠️  Migration status unclear after ${max_wait}s"
    echo "  Check logs: $DOCKER_COMPOSE_CMD logs -f web"
  fi
  echo ""

  # Phase 4: Health checks (only after migrations complete)
  echo "Phase 4: Health checks..."

  # Check web endpoint
  local web_healthy=false
  for i in {1..10}; do
    if $DOCKER_COMPOSE_CMD exec -T web wget -q --spider http://127.0.0.1:4080/healthz 2>/dev/null; then
      web_healthy=true
      break
    fi
    sleep 2
  done

  if [ "$web_healthy" = true ]; then
    echo "  ✓ Web application healthy"
  else
    echo "  ⚠️  Web health check pending"
  fi

  # Check for startup issues in logs
  local scheduler_errors=$($DOCKER_COMPOSE_CMD logs --tail 100 web 2>&1 | grep -c "not started: invalid task function" 2>/dev/null | tail -1 || echo "0")
  scheduler_errors=${scheduler_errors:-0}
  if [ "$scheduler_errors" -gt 0 ] 2>/dev/null; then
    echo "  ⚠️  $scheduler_errors scheduler jobs failed (non-fatal)"
  fi

  # RPC check
  local rpc_ok=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc 'IO.puts("ok")' 2>&1)
  if [[ "$rpc_ok" == *"ok"* ]]; then
    echo "  ✓ Application RPC responding"
  else
    echo "  ⚠️  Application RPC not ready"
  fi

  echo ""
  show_system_activity
  echo ""

  if [ "$migrations_complete" = true ] && [ "$web_healthy" = true ]; then
    echo "✅ Startup complete!"
    return 0
  else
    echo "⚠️  Startup complete with warnings. Run 'cli.sh app_status' for details."
    return 0
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
  
  echo -n "Removing unused images (keeping recent ones)... "
  images_output=$(docker image prune -a -f --filter "until=24h" 2>/dev/null)
  images_space=$(echo "$images_output" | grep "Total reclaimed space" | awk '{print $4 $5}' || echo "0B")
  echo "done (${images_space})"
  
  echo -n "Removing dangling images... "
  dangling_output=$(docker image prune -f 2>/dev/null)
  dangling_space=$(echo "$dangling_output" | grep "Total reclaimed space" | awk '{print $4 $5}' || echo "0B")
  echo "done (${dangling_space})"
  
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
    upgrade)
      # Parse upgrade arguments
      local target_version=""
      local force_flag="false"
      local backup_flag="false"
      local method=""

      while [ $# -gt 0 ]; do
        case "$1" in
          --force)
            force_flag="true"
            shift
            ;;
          --backup)
            backup_flag="true"
            shift
            ;;
          --method=*)
            method="${1#--method=}"
            shift
            ;;
          [0-9]*)
            target_version="$1"
            shift
            ;;
          *)
            shift
            ;;
        esac
      done

      # Default to PostgreSQL 17 if no version specified
      target_version="${target_version:-17}"

      if [ "$method" = "dump-restore" ]; then
        db_upgrade_dump_restore "$target_version"
      else
        db_upgrade "$target_version" "$force_flag" "$backup_flag"
      fi
      ;;
    upgrade-check)
      local target_version="${1:-17}"
      echo "Running pre-flight checks for PostgreSQL $target_version upgrade..."
      echo ""
      pg_upgrade_precheck "$target_version"
      ;;
    upgrade-status)
      pg_upgrade_status
      ;;
    version)
      local pg_version=$(get_postgres_version)
      local data_version=$(get_postgres_data_version)
      echo "PostgreSQL Version: $pg_version"
      echo "Data Directory Version: $data_version"
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
      # Show PostgreSQL version
      local pg_version=$(get_postgres_version)
      echo "PostgreSQL Version: $pg_version"
      echo ""
      echo "=== Database Size ==="
      $DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
        "SELECT pg_size_pretty(pg_database_size('calltelemetry_prod')) AS database_size;"
      echo ""
      list_backups
      echo ""
      # Check if upgrade is recommended
      local upgrade_check=$(check_postgres_upgrade_needed "latest")
      if [ "$upgrade_check" = "required" ]; then
        echo "⚠️  PostgreSQL upgrade recommended for latest app version."
        echo "   Run 'cli.sh db upgrade-check' for details."
        echo ""
      fi
      echo "Commands: cli.sh db <backup|restore|list|compact|tables|purge|size|upgrade|version>"
      ;;
    *)
      echo "Unknown db command: $action"
      echo ""
      echo "Usage: cli.sh db <command>"
      echo ""
      echo "Commands:"
      echo "  status              Show database status (default)"
      echo "  backup              Create a database backup"
      echo "  restore <file>      Restore from a backup file"
      echo "  list                List available backups"
      echo "  compact             Vacuum and compact the database"
      echo "  tables [name]       Show table sizes (optionally filter by name)"
      echo "  purge <t> <d>       Purge records older than <d> days from table <t>"
      echo "  size                Show database size"
      echo "  version             Show PostgreSQL version"
      echo ""
      echo "Upgrade Commands:"
      echo "  upgrade [version]   Upgrade PostgreSQL to specified version (default: 17)"
      echo "                      Options: --force, --backup, --method=dump-restore"
      echo "  upgrade-check [v]   Run pre-flight checks without upgrading"
      echo "  upgrade-status      Show upgrade status and history"
      echo ""
      echo "Upgrade Notes:"
      echo "  pg_upgrade uses hard links, so minimal extra disk space is needed."
      echo "  Your original data directory is preserved as a backup automatically."
      echo "  Use --backup to also create a SQL dump before upgrading."
      return 1
      ;;
  esac
}

# Function to get the release binary path
get_release_binary() {
  echo "/home/app/onprem/bin/onprem"
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
    echo "    ⚠️  $service ports: container not found"
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
      echo "    ⚠️  $service:$port not published to host; skipping port probe"
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
    echo "    ⚠️  $service: container not found"
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
      echo "    ⏳ $service healthcheck: starting"
      return 1
      ;;
    unhealthy)
      echo "    ⚠️  $service healthcheck: unhealthy"
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
      echo "    ⚠️  $service healthcheck: $health"
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
    echo "📋 Pending migrations detected from logs:"
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
    echo "⚠️  Note: $scheduler_warnings scheduler jobs have invalid task functions (non-fatal)"
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
      echo "✅ Migration status check completed"
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
  echo "✅ Purge completed in ${duration} seconds"
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
  echo "💡 Tip: Run 'VACUUM FULL $table_name' to reclaim disk space"
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
  
  # Execute migrations
  echo "Executing migrations..."
  migration_output=$($DOCKER_COMPOSE_CMD exec -T web "$release_bin" rpc '
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
  ' 2>&1)

  # Display output
  echo "$migration_output"
  
  if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Migration run completed successfully"
  else
    echo ""
    echo "❌ Migration run failed"
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
    echo "✅ Migration rollback completed successfully"
  else
    echo ""
    echo "❌ Migration rollback failed"
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
      echo "  run               Run pending migrations"
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
  $DOCKER_COMPOSE_CMD ps
  echo ""

  # Check if web container is running
  web_container=$($DOCKER_COMPOSE_CMD ps -q web 2>/dev/null)
  if [ -z "$web_container" ]; then
    echo "❌ Web container not running"
    return 1
  fi

  container_status=$(docker inspect --format='{{.State.Status}}' "$web_container" 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    echo "❌ Web container status: $container_status"
    return 1
  fi

  # Database connectivity
  echo "=== Database Status ==="
  if $DOCKER_COMPOSE_CMD exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "✓ Database: accepting connections"

    # Get migration count from DB
    migration_count=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
      "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null | tr -d ' ')
    echo "✓ Migrations in database: $migration_count"

    # Get latest migration
    latest=$($DOCKER_COMPOSE_CMD exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
      "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;" 2>/dev/null | tr -d ' ')
    echo "✓ Latest migration: $latest"
  else
    echo "❌ Database: not accepting connections"
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
    echo "❌ RPC connection: failed"
    echo "   Application may still be starting up"
    echo "   Error: $rpc_test"
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
    echo "⏳ Migrations: still running"
  else
    echo "? Migrations: status unknown from logs"
  fi

  # Check for scheduler errors
  scheduler_errors=$(echo "$recent_logs" | grep "not started: invalid task function" | wc -l)
  if [ "$scheduler_errors" -gt 0 ]; then
    echo "⚠️  Scheduler: $scheduler_errors jobs failed to start (invalid task function)"
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
      echo "Restarting Docker Compose service..."
      systemctl restart docker-compose-app.service
      echo "Docker Compose service restarted."
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
build_appliance() {
  echo "Downloading and executing the prep script to build the appliance..."
  wget -q "$PREP_SCRIPT_URL" -O /tmp/prep.sh
  echo "Script downloaded. Executing the script..."
  if [ $? -eq 0 ]; then
    chmod +x /tmp/prep.sh
    /tmp/prep.sh
    sudo chown -R calltelemetry "$BACKUP_DIR"
    sudo chown -R calltelemetry "$BACKUP_FOLDER_PATH"
  else
    echo "Failed to download the prep script. Please check your internet connection."
  fi
  rm -f /tmp/prep.sh
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
  wget https://github.com/derailed/k9s/releases/download/$K9S_LATEST_VERSION/k9s_Linux_x86_64.tar.gz
  tar -xzf k9s_Linux_x86_64.tar.gz
  sudo mv k9s /usr/local/bin
  mkdir -p ~/.k9s
  rm -rf k9s*

  # Install GIT
  sudo dnf install -y git
}

# Function to generate self-signed certificates if they do not exist
generate_self_signed_certificates() {
  cert_dir="./certs"
  cert_file="$cert_dir/appliance.crt"
  key_file="$cert_dir/appliance_key.pem"

  if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
    echo "Generating self-signed certificates..."
    mkdir -p "$cert_dir"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" -subj "/CN=appliance.calltelemetry.internal"
    echo "No certs found. Self-signed certificates generated."
  else
    echo "Certificates already exist. Skipping generation."
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
          echo "  Status:     ⚠️  Expiring soon (within 30 days)"
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

# Main script logic
case "$1" in
  --help|-h|help)
    show_help
    ;;
  update)
    shift
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
  certs)
    certs_cmd "$2"
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

  # Offline/Air-Gap commands for environments without internet access
  offline)
    offline_download() {
      local version="${1:-latest}"
      local bundle_dir="offline-bundle-$(date +%Y%m%d-%H%M%S)"
      local bundle_name="calltelemetry-offline-${version}-$(date +%Y%m%d).tar.gz"
      local OFFLINE_BASE_URL="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master"
      local start_dir="$(pwd)"

      # Use curl if wget not available
      download_file() {
        local url="$1"
        local output="$2"
        if command -v wget >/dev/null 2>&1; then
          wget -q "$url" -O "$output"
        elif command -v curl >/dev/null 2>&1; then
          curl -sfL "$url" -o "$output"
        else
          echo "Error: Neither wget nor curl is available"
          return 1
        fi
      }

      echo "=== Creating Offline Bundle ==="
      echo "Version: $version"
      echo "Output: $bundle_name"
      echo ""

      # Create temp directory
      mkdir -p "$bundle_dir"
      cd "$bundle_dir" || return 1

      # Download config files
      echo "Downloading configuration files..."
      if [ "$version" = "latest" ]; then
        download_file "$OFFLINE_BASE_URL/docker-compose.yml" "docker-compose.yml" || { echo "Failed to download docker-compose.yml"; cd "$start_dir"; rm -rf "$bundle_dir"; return 1; }
      else
        # Try versioned file first (e.g., ova/versions/0.8.4-rc181.yaml), then fall back to latest
        if ! download_file "$OFFLINE_BASE_URL/ova/versions/${version}.yaml" "docker-compose.yml" 2>/dev/null; then
          echo "Version-specific file not found, downloading latest and updating tags..."
          download_file "$OFFLINE_BASE_URL/docker-compose.yml" "docker-compose.yml" || { echo "Failed to download docker-compose.yml"; cd "$start_dir"; rm -rf "$bundle_dir"; return 1; }
          # Update calltelemetry image tags to specified version
          echo "Updating image tags to version: $version"
          sed -i.bak -E "s|(calltelemetry/web:)[^\"'[:space:]]+|\1$version|g" docker-compose.yml
          sed -i.bak -E "s|(calltelemetry/vue:)[^\"'[:space:]]+|\1$version|g" docker-compose.yml
          rm -f docker-compose.yml.bak
        fi
      fi

      download_file "$OFFLINE_BASE_URL/ova/Caddyfile" "Caddyfile" || echo "Warning: Could not download Caddyfile"
      download_file "$OFFLINE_BASE_URL/ova/cli.sh" "cli.sh" || echo "Warning: Could not download cli.sh"
      download_file "$OFFLINE_BASE_URL/ova/nats.conf" "nats.conf" 2>/dev/null || echo "Note: nats.conf not found (optional)"

      # Download prometheus config
      mkdir -p prometheus
      download_file "$OFFLINE_BASE_URL/ova/versions/prometheus/prometheus.yml" "prometheus/prometheus.yml" 2>/dev/null || echo "Note: prometheus.yml not found"

      # Download grafana configs
      mkdir -p grafana/provisioning/datasources grafana/provisioning/dashboards grafana/dashboards
      download_file "$OFFLINE_BASE_URL/ova/versions/grafana/provisioning/datasources/calltelemetry.yml" "grafana/provisioning/datasources/calltelemetry.yml" 2>/dev/null || true
      download_file "$OFFLINE_BASE_URL/ova/versions/grafana/provisioning/dashboards/calltelemetry.yaml" "grafana/provisioning/dashboards/calltelemetry.yaml" 2>/dev/null || true
      download_file "$OFFLINE_BASE_URL/ova/versions/grafana/dashboards/calltelemetry-overview.json" "grafana/dashboards/calltelemetry-overview.json" 2>/dev/null || true

      chmod +x cli.sh 2>/dev/null || true

      echo "Configuration files downloaded."
      echo ""

      # Extract and pull images
      echo "Extracting image list from docker-compose.yml..."
      local images=$(grep -E '^\s*image:' docker-compose.yml | sed 's/.*image:[[:space:]]*["'\'']*\([^"'\'']*\)["'\'']*[[:space:]]*$/\1/' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

      echo "Images to download:"
      echo "$images" | while read img; do [ -n "$img" ] && echo "  - $img"; done
      echo ""

      echo "Pulling Docker images (this may take a while)..."
      local pull_failed=false
      for img in $images; do
        [ -z "$img" ] && continue
        echo "Pulling: $img"
        if ! docker pull "$img"; then
          echo "Warning: Failed to pull $img"
          pull_failed=true
        fi
      done

      if [ "$pull_failed" = true ]; then
        echo ""
        echo "Warning: Some images failed to pull. Bundle may be incomplete."
      fi

      echo ""
      echo "Saving Docker images to tar file..."
      # shellcheck disable=SC2086
      docker save $images -o images.tar
      echo "Images saved to images.tar ($(du -h images.tar | cut -f1))"

      echo ""
      echo "Creating bundle archive..."
      cd "$start_dir"
      tar -czf "$bundle_name" "$bundle_dir"
      rm -rf "$bundle_dir"

      echo ""
      echo "=== Bundle Created Successfully ==="
      echo "File: $bundle_name"
      echo "Size: $(du -h "$bundle_name" | cut -f1)"
      echo ""
      echo "Transfer this file to your air-gapped system and run:"
      echo "  ./cli.sh offline apply $bundle_name"
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
        echo "  - grafana configs"
      fi

      # Cleanup extraction directory
      rm -rf "$extract_dir"

      echo ""
      echo "Restarting services..."
      fix_systemd_service_if_needed
      systemctl restart docker-compose-app.service

      echo ""
      echo "=== Offline Bundle Applied ==="
      echo "Verifying containers..."
      sleep 5
      $DOCKER_COMPOSE_CMD ps

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

    case "$2" in
      download)
        offline_download "$3"
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
        echo "  download [version]     Download all images and configs for offline install"
        echo "                         Creates a .tar.gz bundle with everything needed"
        echo "                         Default version: latest"
        echo ""
        echo "  apply <bundle.tar.gz>  Apply an offline bundle to this system"
        echo "                         Loads images and installs config files"
        echo ""
        echo "  list                   List images in current docker-compose.yml"
        echo "                         Shows which are downloaded locally"
        echo ""
        echo "Workflow:"
        echo "  1. On internet-connected machine:"
        echo "     ./cli.sh offline download 0.8.4-rc181"
        echo ""
        echo "  2. Transfer bundle to air-gapped system via USB/SFTP to /home/calltelemetry/"
        echo ""
        echo "  3. On air-gapped system (first time - extract cli.sh first):"
        echo "     cd /home/calltelemetry"
        echo "     tar -xzf calltelemetry-offline-*.tar.gz"
        echo "     cp offline-bundle-*/cli.sh ./cli.sh && chmod +x ./cli.sh"
        echo "     ./cli.sh offline apply calltelemetry-offline-*.tar.gz"
        echo ""
        echo "  4. Future updates (cli.sh already has offline command):"
        echo "     ./cli.sh offline apply calltelemetry-offline-*.tar.gz"
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
        $DOCKER_COMPOSE_CMD ps
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
        local ip_mode="$3"
        local url="$4"

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
        local host port
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
        local image_tag=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "calltelemetry/web" | head -1)
        if [ -z "$image_tag" ]; then
          image_tag="calltelemetry/web:latest"
        fi

        echo "Using image: $image_tag"
        echo ""

        # Build Elixir code based on mode
        local elixir_code="Application.ensure_all_started(:hackney)"

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
          local ipv6_tuple=$(echo "$host" | python3 -c "
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
        local ip_mode="$3"
        local url="$4"

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
        local host port
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
        local image_tag=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "calltelemetry/web" | head -1)
        if [ -z "$image_tag" ]; then
          image_tag="calltelemetry/web:latest"
        fi

        echo "Using image: $image_tag"
        echo ""

        local elixir_code=""

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
          local ipv6_tuple=$(echo "$host" | python3 -c "
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
        local duration="$3"
        local filter="$4"
        local output_file="$5"

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
        local tcpdump_cmd="sudo tcpdump -w '$output_file'"
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
          local file_size=$(ls -lh "$output_file" | awk '{print $5}')
          local packet_count=$(sudo tcpdump -r "$output_file" 2>/dev/null | wc -l)
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
      ""|help)
        echo "Usage: cli.sh diag <command>"
        echo ""
        echo "Diagnostic commands:"
        echo "  tesla <ipv4|ipv6> <url>    Test TCP + HTTP connectivity"
        echo "  raw_tcp <ipv4|ipv6> <url>  Test raw TCP socket only"
        echo "  capture <secs> [filter] [file]  Capture packets with tcpdump"
        echo "  database                   Run comprehensive database diagnostics"
        echo ""
        echo "Examples:"
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

  # Advanced commands
  build-appliance)
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
