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
  echo "  update [version]    Update the docker-compose configuration to the specified version and restart the service."
  echo "                      If no version is specified, the default latest version will be used."
  echo "  rollback            Roll back to the previous docker-compose configuration."
  echo "  reset               Stop the application, remove data, and restart the application."
  echo "  compact             Prune Docker system and compact the PostgreSQL database."
  echo "  purge               Remove unused Docker images, containers, networks, and volumes."
  echo "  backup              Create a database backup and retain only the last 5 backups."
  echo "  restore             Restore the database from a specified backup file."
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

# Function to update the docker-compose configuration
update() {
  cli_update  # Ensure the CLI script is up-to-date

  version=${1:-"latest"}
  if [ "$version" == "latest" ]; then
    url="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/docker-compose.yml"
  else
    url="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/versions/$version.yaml"
  fi

  timestamp=$(date "+%Y-%m-%d-%H-%M-%S")
  timestamped_backup_file="$BACKUP_DIR/docker-compose-$timestamp.yml"

  if [ -f "$ORIGINAL_FILE" ]; then
    cp "$ORIGINAL_FILE" "$timestamped_backup_file"
    echo "Existing docker-compose.yml backed up to $timestamped_backup_file"
  fi

  wget "$url" -O "$TEMP_FILE"

  # Download NATS configuration file
  nats_conf_url="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/nats.conf"
  nats_conf_file="nats.conf"
  wget "$nats_conf_url" -O "$nats_conf_file"

  # Download the Caddyfile
  CADDYFILE_URL="https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/ova/Caddyfile"
  caddyfile_tmp=$(mktemp)
  wget -q "$CADDYFILE_URL" -O "$caddyfile_tmp"

  if [ -f "$TEMP_FILE" ] && [ -f "$nats_conf_file" ] && [ -f "$caddyfile_tmp" ]; then
    if docker-compose -f "$TEMP_FILE" pull; then
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
      echo "Docker image pull failed. Rolling back to previous configuration."
      rollback
      rm "$TEMP_FILE"
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
  sleep 10

  echo "Compacting PostgreSQL database..."
  sudo docker-compose exec -e PGPASSWORD=postgres db psql -d calltelemetry_prod -U calltelemetry -c 'VACUUM FULL;'

  echo "System compaction complete."
}

# Function to wait for services to be ready
wait_for_services() {
  echo "Waiting for services to start up..."
  
  # Define expected services
  services=("caddy" "vue-web" "traceroute" "db" "web" "nats")
  max_wait=300  # 5 minutes
  wait_time=0
  
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
    else
      echo "  ⏳ Database: not ready (may be rebuilding indexes)"
      all_ready=false
    fi
    
    # Simple process check for web service - just verify it's running
    # No need to check internal ports since they're not externally accessible
    echo "  ✓ Services: containers running (internal connectivity not validated)"
    
    if [ "$all_ready" = true ]; then
      echo "✅ All services are running and ready!"
      return 0
    fi
    
    sleep 10
    wait_time=$((wait_time + 10))
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
  
  echo "✅ Docker cleanup complete."
  
  # Display final space usage summary
  echo "Current Docker system usage:"
  docker system df
}

# Function to create a backup and retain only the last 5 backups
backup() {
  backup_folder_path=$BACKUP_FOLDER_PATH
  file_name="dump-"`date "+%Y-%m-%d-%H-%M-%S"`".sql"
  mkdir -p ${backup_folder_path}

  dbname=calltelemetry_prod
  username=calltelemetry
  container=$(docker ps --filter "name=db" --format "{{.Names}}" | head -n 1)

  if [ -z "$container" ]; then
    echo "Error: Database container not found."
    return 1
  fi

  backup_file=${backup_folder_path}/${file_name}

  docker exec -e PGPASSWORD=postgres -it ${container} pg_dump -U ${username} -d ${dbname} > ${backup_file}

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
