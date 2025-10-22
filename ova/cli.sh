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
CURRENT_SCRIPT_PATH="$0"
PREP_SCRIPT_URL="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/prep.sh"

# Ensure necessary directories exist and have correct permissions
mkdir -p "$BACKUP_DIR"
mkdir -p "$BACKUP_FOLDER_PATH"

# Function to display help
show_help() {
  echo "Usage: script_name.sh [option] [parameter]"
  echo
  echo "Options:"
  echo "  --help              Show this help message and exit."
  echo "  update [version] [--force-upgrade]"
  echo "                      Update the docker-compose configuration to the specified version and restart the service."
  echo "                      If no version is specified, the default latest version will be used."
  echo "                      --force-upgrade bypasses the 10% disk space requirement check."
  echo "  rollback            Roll back to the previous docker-compose configuration."
  echo "  reset               Stop the application, remove data, and restart the application."
  echo "  compact             Prune Docker system and compact the PostgreSQL database."
  echo "  purge               Remove unused Docker images, containers, networks, and volumes."
  echo "  backup              Create a database backup and retain only the last 5 backups."
  echo "  restore             Restore the database from a specified backup file."
  echo "  migration_status    Check migration status and generate report."
  echo "  sql_migration_status Show the last 10 migrations directly from the database."
  echo "  sql_table_size [table1,table2,...] Show table sizes with row counts and disk usage."
  echo "                      If no tables specified, shows all tables."
  echo "  sql_purge_table <table> <days> Purge records older than X days from a table."
  echo "                      Requires table to have an 'inserted_at' timestamp column."
  echo "  migration_run       Execute pending database migrations."
  echo "  migration_rollback [steps]  Rollback database migrations (default: 1 step)."
  echo "  set_logging level   Set the logging level (debug, info, warning, error)."
  echo "  cli_update          Update the CLI script to the latest version from the repository."
  echo "  build-appliance     Download and execute the prep script to build the appliance."
  echo "  prep-cluster-node   Prepare the cluster node with necessary tools."
  echo "  reset_certs         Delete all files in the certs folder and generate new self-signed certificates."
}

# Function to update the CLI script
cli_update() {
  echo "Checking for script updates..."
  tmp_file=$(mktemp)
  wget -q "$SCRIPT_URL" -O "$tmp_file"

  if [ $? -eq 0 ]; then
    if [ -f "$CURRENT_SCRIPT_PATH" ]; then
      if ! diff "$tmp_file" "$CURRENT_SCRIPT_PATH" > /dev/null; then
        echo "Update available for the CLI script. Updating now..."
        cp "$tmp_file" "$CURRENT_SCRIPT_PATH"
        chmod +x "$CURRENT_SCRIPT_PATH"
        echo "CLI script updated."
      else
        echo "CLI script is up-to-date."
      fi
    else
      echo "Current script path not found: $CURRENT_SCRIPT_PATH. Installing new script..."
      cp "$tmp_file" "$CURRENT_SCRIPT_PATH"
      chmod +x "$CURRENT_SCRIPT_PATH"
      echo "CLI script installed."
    fi
  else
    echo "Failed to check for updates. Please check your internet connection."
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

# Function to check RAM availability
check_ram() {
  local required_ram_mb=8192  # 8GB in MB

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

  echo "Detected RAM: ${total_ram_mb}MB ($(awk "BEGIN {printf \"%.1f\", $total_ram_mb/1024}")GB)"

  if [ "$total_ram_mb" -lt "$required_ram_mb" ]; then
    echo "Required RAM: ${required_ram_mb}MB (8GB)"
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

  version=${1:-"latest"}
  force_upgrade=false

  # Check for --force-upgrade flag in any position
  if [[ "$*" == *"--force-upgrade"* ]]; then
    force_upgrade=true
    # Remove --force-upgrade from arguments
    set -- "${@/--force-upgrade/}"
    version=${1:-"latest"}
  fi

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
        echo "   Version 0.8.4+ requires a minimum of 8GB RAM"
        echo ""
        echo "To proceed anyway, use: $0 update $version --force-upgrade"
        echo "WARNING: Proceeding with insufficient RAM may cause performance issues or failures"
        return 1
      fi
      echo "✅ RAM requirement met"
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
    echo "Docker package update completed. Continuing with upgrade..."
    echo ""
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

  # Check image availability before proceeding
  if ! check_image_availability "$TEMP_FILE"; then
    echo ""
    echo "❌ Cannot proceed with upgrade - some images are not available"
    echo "Please ensure all images are built and pushed to the registry"
    rm -f "$TEMP_FILE"
    return 1
  fi

  echo ""
  echo "Pulling Docker images..."
  if ! docker-compose -f "$TEMP_FILE" pull; then
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
  echo "  - Run automatic cleanup"
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
  CADDYFILE_URL="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/Caddyfile"
  caddyfile_tmp=$(mktemp)
  wget -q "$CADDYFILE_URL" -O "$caddyfile_tmp"

  if [ -f "$TEMP_FILE" ] && [ -f "$nats_conf_file" ] && [ -f "$caddyfile_tmp" ]; then
    mv "$TEMP_FILE" "$ORIGINAL_FILE"
    echo "New docker-compose.yml moved to production."
    echo "NATS configuration file downloaded."
    echo "Caddyfile downloaded."

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

    echo "Restarting Docker Compose service..."
    systemctl restart docker-compose-app.service
    echo "Docker Compose service restarted."

    echo "Cleaning up unused Docker resources..."
    purge_docker

    echo "Monitoring service startup..."
    wait_for_services

    if [ $? -eq 0 ]; then
      echo "✅ Update complete! All services are running and ready."
    else
      echo "⚠️  Update complete, but some services may still be initializing."
      echo "This is normal during major upgrades with SQL index rebuilds."
      echo "Monitor progress with: docker-compose logs -f"
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
  sudo docker-compose up -d db

  echo "Waiting for the database service to be fully operational..."
  sleep 15

  echo "Verifying database connectivity..."
  if ! sudo docker-compose exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "Error: Database is not ready. Cannot perform vacuum."
    return 1
  fi

  echo "Compacting PostgreSQL database (this may take several minutes)..."
  if sudo docker-compose exec -e PGPASSWORD=postgres -T db psql -d calltelemetry_prod -U calltelemetry -c 'VACUUM FULL;'; then
    echo "✅ Database vacuum completed successfully."
  else
    echo "❌ Database vacuum failed."
    return 1
  fi

  echo "System compaction complete."
}

# Function to wait for services to be ready
wait_for_services() {
  echo "Waiting for services to start up..."

  # Define expected services
  services=("caddy" "vue-web" "traceroute" "db" "web" "nats")
  max_wait=300  # 5 minutes
  wait_time=0
  db_ready=false
  check_counter=0

  while [ $wait_time -lt $max_wait ]; do
    all_ready=true

    echo "Checking service status (${wait_time}s elapsed)..."

    for service in "${services[@]}"; do
      container=$(docker-compose ps -q $service 2>/dev/null)
      if [ -n "$container" ]; then
        status=$(docker inspect --format='{{.State.Status}}' $container 2>/dev/null)

        if [ "$status" = "running" ]; then
          echo "  ✓ $service: running"
        else
          echo "  ✗ $service: $status"
          all_ready=false
        fi
      else
        echo "  ✗ $service: container not found"
        all_ready=false
      fi
    done

    # Service-specific readiness checks
    echo "Checking service readiness..."

    # Database connectivity check
    if docker-compose exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
      echo "  ✓ Database: accepting connections"
      db_ready=true

      # Show migration status every 5 seconds (on multiples of 5)
      if [ $((wait_time % 5)) -eq 0 ]; then
        echo ""
        echo "=== Database Migration Status ==="
        migration_result=$(docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
          "SELECT COUNT(*) FROM schema_migrations;" 2>/dev/null | tr -d ' ')

        if [ -n "$migration_result" ]; then
          echo "Total migrations applied: $migration_result"
          echo ""
          echo "Last 5 migrations:"
          docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
            "SELECT version, inserted_at FROM schema_migrations ORDER BY version DESC LIMIT 5;" 2>/dev/null || echo "Unable to fetch migration details"
        else
          echo "Unable to query migration status (migrations may still be running)"
        fi
        echo "================================"
        echo ""
      fi
    else
      echo "  ⏳ Database: not ready (may be rebuilding indexes or running migrations)"
      all_ready=false
      db_ready=false
    fi

    # Simple process check for web service - just verify it's running
    # No need to check internal ports since they're not externally accessible
    echo "  ✓ Services: containers running (internal connectivity not validated)"

    if [ "$all_ready" = true ]; then
      echo ""
      echo "✅ All services are running and ready!"

      # Show final migration status
      if [ "$db_ready" = true ]; then
        echo ""
        echo "=== Final Migration Status ==="
        docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
          "SELECT COUNT(*) as total_migrations FROM schema_migrations;"
        echo ""
        docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
          "SELECT version, inserted_at FROM schema_migrations ORDER BY version DESC LIMIT 5;"
        echo "=============================="
      fi

      return 0
    fi

    sleep 5
    wait_time=$((wait_time + 5))
  done

  echo "⚠️  Some services may still be starting up after ${max_wait}s"
  echo "This is normal for database index rebuilds during major upgrades."
  echo "Monitor progress with: docker-compose logs -f"
  return 1
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

  docker-compose exec -e PGPASSWORD=postgres -T db pg_dump -U ${username} -d ${dbname} > ${backup_file}

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

# Function to get the release binary path
get_release_binary() {
  echo "/home/app/onprem/bin/onprem"
}

# Function to check migration status using Elixir release
migration_status() {
  echo "Checking database migration status..."
  
  report_file="migrations-report.txt"
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  
  # Initialize report file
  cat > "$report_file" << EOF
Call Telemetry Database Migration Status Report
Generated: $timestamp
==========================================

EOF

  # Check if web container is running
  web_container=$(docker-compose ps -q web 2>/dev/null)
  if [ -z "$web_container" ]; then
    echo "Error: Web container not found or not running."
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    echo "ERROR: Web container not found at $timestamp" >> "$report_file"
    return 1
  fi

  # Check if the web container is actually running (not just exists)
  container_status=$(docker inspect --format='{{.State.Status}}' $web_container 2>/dev/null)
  if [ "$container_status" != "running" ]; then
    echo "Error: Web container is not running (status: $container_status)"
    echo "Please start the services with: sudo systemctl start docker-compose-app.service"
    echo "ERROR: Web container not running at $timestamp" >> "$report_file"
    return 1
  fi

  # Test RPC connection
  echo "Testing RPC connection..."
  rpc_test=$(docker-compose exec -T web "$release_bin" rpc 'IO.puts("RPC connection successful")' 2>&1)
  if [[ "$rpc_test" == *"noconnection"* ]]; then
    echo "Error: Cannot connect to running application via RPC"
    echo "The application may still be starting up. Please wait and try again."
    echo "You can check logs with: docker-compose logs web"
    echo "ERROR: RPC connection failed at $timestamp" >> "$report_file"
    return 1
  fi

  echo "Web container found: $web_container" >> "$report_file"
  echo "Finding release binary..." >> "$report_file"

  echo "Using release binary: $release_bin" >> "$report_file"
  echo "" >> "$report_file"

  # Execute migration status check using Elixir
  echo "Executing migration status check..."
  migration_output=$(docker-compose exec -T web "$release_bin" rpc '
    IO.puts("=== Migration Status ===")
    
    try do
      migrations = Ecto.Migrator.migrations(Cdrcisco.Repo)
      
      if migrations == [] do
        IO.puts("No migrations found!")
      else
        IO.puts("Status\tVersion\t\tName")
        IO.puts("------\t-------\t\t----")
        
        # Force full output without truncation
        Process.put(:iex_width, :infinity)
        
        Enum.each(migrations, fn {status, version, name} ->
          status_str = case status do
            :up -> "UP   "
            :down -> "DOWN "
          end
          IO.puts("#{status_str}\t#{version}\t#{name}")
          # Force flush to ensure no truncation
          :io.format("~n", [])
        end)
        
        pending = Enum.filter(migrations, fn {status, _, _} -> status == :down end)
        applied = Enum.filter(migrations, fn {status, _, _} -> status == :up end)
        
        IO.puts("")
        IO.puts("=== Summary ===")
        IO.puts("Total migrations: #{length(migrations)}")
        IO.puts("Applied migrations: #{length(applied)}")
        IO.puts("Pending migrations: #{length(pending)}")
        
        if length(pending) > 0 do
          IO.puts("")
          IO.puts("WARNING: There are pending migrations!")
          IO.puts("Run: ./ova/cli.sh migration_run")
        else
          IO.puts("")
          IO.puts("All migrations are up to date!")
        end
        
        # Show last 5 and first 5 for verification
        IO.puts("")
        IO.puts("=== Recent Migrations (Last 5) ===")
        migrations |> Enum.take(-5) |> Enum.each(fn {status, version, name} ->
          status_str = if status == :up, do: "UP", else: "DOWN"
          IO.puts("#{status_str}\t#{version}\t#{name}")
        end)
      end
    rescue
      e -> 
        IO.puts("Error checking migrations: #{inspect(e)}")
    end
  ' 2>&1)

  # Save output to report
  echo "Migration Status Output:" >> "$report_file"
  echo "$migration_output" >> "$report_file"
  echo "" >> "$report_file"
  echo "Migration status check completed at: $(date)" >> "$report_file"

  # Display output to console
  echo "$migration_output"
  echo ""
  echo "✅ Migration status check completed"
  echo "Report saved to: $report_file"
}

# Function to show SQL migration status directly from database
sql_migration_status() {
  echo "Fetching migration status from database..."
  echo ""

  # Check if db container is running
  db_container=$(docker-compose ps -q db 2>/dev/null)
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
  if ! docker-compose exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "Error: Database is not ready to accept connections"
    return 1
  fi

  echo "=== Last 10 Applied Migrations ==="
  echo ""
  docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "SELECT version, inserted_at FROM schema_migrations ORDER BY version DESC LIMIT 10;"

  echo ""
  echo "=== Migration Count ==="
  docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "SELECT COUNT(*) as total_migrations FROM schema_migrations;"
}

# Function to show table sizes
sql_table_size() {
  echo "Fetching table size information from database..."
  echo ""

  # Check if db container is running
  db_container=$(docker-compose ps -q db 2>/dev/null)
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
  if ! docker-compose exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "Error: Database is not ready to accept connections"
    return 1
  fi

  # Parse table list if provided
  tables="$1"

  if [ -z "$tables" ]; then
    # Show all tables
    echo "=== All Table Sizes ==="
    echo ""
    docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c "
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
    docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c "
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
  docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
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
  db_container=$(docker-compose ps -q db 2>/dev/null)
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
  if ! docker-compose exec -T db pg_isready -U calltelemetry -d calltelemetry_prod >/dev/null 2>&1; then
    echo "Error: Database is not ready to accept connections"
    return 1
  fi

  # Check if table exists
  echo "Checking if table exists..."
  table_exists=$(docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table_name');" | tr -d ' ')

  if [ "$table_exists" != "t" ]; then
    echo "Error: Table '$table_name' does not exist in the database"
    return 1
  fi

  # Check if table has inserted_at column
  echo "Checking for 'inserted_at' column..."
  column_exists=$(docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$table_name' AND column_name = 'inserted_at');" | tr -d ' ')

  if [ "$column_exists" != "t" ]; then
    echo "Error: Table '$table_name' does not have an 'inserted_at' column"
    echo "This command requires the table to have a timestamp column named 'inserted_at'"
    return 1
  fi

  # Get count of records to be deleted
  echo ""
  echo "Counting records to be deleted..."
  records_to_delete=$(docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
    "SELECT COUNT(*) FROM $table_name WHERE inserted_at < NOW() - INTERVAL '$days days';" | tr -d ' ')

  if [ -z "$records_to_delete" ] || [ "$records_to_delete" = "0" ]; then
    echo "No records found older than $days days. Nothing to purge."
    return 0
  fi

  echo "Found $records_to_delete records to delete (older than $days days)"
  echo ""

  # Show date cutoff
  cutoff_date=$(docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -t -c \
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

  delete_result=$(docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c \
    "DELETE FROM $table_name WHERE inserted_at < NOW() - INTERVAL '$days days';" 2>&1)

  end_time=$(date +%s)
  duration=$((end_time - start_time))

  echo "$delete_result"
  echo ""
  echo "✅ Purge completed in ${duration} seconds"
  echo ""

  # Show updated table size
  echo "=== Updated Table Size ==="
  docker-compose exec -e PGPASSWORD=postgres -T db psql -U calltelemetry -d calltelemetry_prod -c "
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
  echo "   Use: docker-compose exec -T db psql -U calltelemetry -d calltelemetry_prod -c 'VACUUM FULL $table_name;'"
}

# Function to run pending migrations using Elixir release
migration_run() {
  echo "Running pending database migrations..."
  
  # Check if web container is running and application is ready
  web_container=$(docker-compose ps -q web 2>/dev/null)
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
  rpc_test=$(docker-compose exec -T web "$release_bin" rpc 'IO.puts("RPC connection successful")' 2>&1)
  if [[ "$rpc_test" == *"noconnection"* ]]; then
    echo "Error: Cannot connect to running application via RPC"
    echo "The application may still be starting up. Please wait and try again."
    return 1
  fi

  echo "Using release binary: $release_bin"
  
  # Execute migrations
  echo "Executing migrations..."
  migration_output=$(docker-compose exec -T web "$release_bin" rpc '
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
  web_container=$(docker-compose ps -q web 2>/dev/null)
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
  rpc_test=$(docker-compose exec -T web "$release_bin" rpc 'IO.puts("RPC connection successful")' 2>&1)
  if [[ "$rpc_test" == *"noconnection"* ]]; then
    echo "Error: Cannot connect to running application via RPC"
    echo "The application may still be starting up. Please wait and try again."
    return 1
  fi

  echo "Using release binary: $release_bin"
  
  # Execute rollback
  echo "Executing rollback..."
  rollback_output=$(docker-compose exec -T web "$release_bin" rpc "
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

# Function to set the logging level in docker-compose.yml
set_logging() {
  if [[ -z "$1" || ! "$1" =~ ^(debug|info|warning|error)$ ]]; then
    echo "Error: Invalid logging level. Please use 'debug', 'info', 'warning', or 'error'."
    return 1
  fi

  new_level=$1
  sed -i -E "s/^(.*LOGGING_LEVEL=).*$/\1$new_level/" "$ORIGINAL_FILE"
  echo "Logging level set to $new_level in $ORIGINAL_FILE."

  echo "Restarting Docker Compose service..."
  systemctl restart docker-compose-app.service
  echo "Docker Compose service restarted."
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

# Main script logic
case "$1" in
  --help)
    show_help
    ;;
  update)
    generate_self_signed_certificates  # Ensure certificates are generated before update
    update "$2"
    ;;
  rollback)
    rollback
    ;;
  reset)
    reset_app
    ;;
  compact)
    compact_system
    ;;
  purge)
    purge_docker
    ;;
  backup)
    backup
    ;;
  restore)
    restore "$2"
    ;;
  migration_status)
    migration_status
    ;;
  sql_migration_status)
    sql_migration_status
    ;;
  sql_table_size)
    sql_table_size "$2"
    ;;
  sql_purge_table)
    sql_purge_table "$2" "$3"
    ;;
  migration_run)
    migration_run
    ;;
  migration_rollback)
    migration_rollback "$2"
    ;;
  set_logging)
    set_logging "$2"
    ;;
  cli_update)
    cli_update
    ;;
  build-appliance)
    build_appliance
    ;;
  prep-cluster-node)
    prep_cluster_node
    ;;
  reset_certs)
    reset_certs
    ;;
  *)
    echo "Invalid option: $1"
    echo "Use --help to see the list of available commands."
    ;;
esac
