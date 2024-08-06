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
mkdir -p "$BACKUP_DIR" -p
mkdir -p "$BACKUP_FOLDER_PATH" -p
sudo chown -R calltelemetry "$BACKUP_DIR"
sudo chown -R calltelemetry "$BACKUP_FOLDER_PATH"

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
  echo "  backup              Create a database backup and retain only the last 5 backups."
  echo "  restore             Restore the database from a specified backup file."
  echo "  set_logging level   Set the logging level (debug, info, warning, error)."
  echo "  cli_update          Update the CLI script to the latest version from the repository."
  echo "  build-appliance     Download and execute the prep script to build the appliance."
  echo "  prep-cluster-node   Prepare the cluster node with necessary tools."
}

# Function to update the CLI script
cli_update() {
  echo "Checking for script updates..."
  tmp_file=$(mktemp)
  wget -q "$SCRIPT_URL" -O "$tmp_file"

  if [ $? -eq 0 ]; then
    if ! diff "$tmp_file" "$CURRENT_SCRIPT_PATH" > /dev/null; then
      echo "Update available for the CLI script. Updating now..."
      cp "$tmp_file" "$CURRENT_SCRIPT_PATH"
      chmod +x "$CURRENT_SCRIPT_PATH"
      echo "CLI script updated. Please run the command again."
      rm -f "$tmp_file"
      exit 0
    else
      echo "CLI script is up-to-date."
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

  if [ -f "$TEMP_FILE" ]; then
    if docker-compose -f "$TEMP_FILE" pull; then
      mv "$TEMP_FILE" "$ORIGINAL_FILE"
      echo "New docker-compose.yml moved to production."
      echo "Restarting Docker Compose service..."
      systemctl restart docker-compose-app.service
      echo "Docker Compose service restarted."
    else
      echo "Docker image pull failed. Rolling back to previous configuration."
      rollback
      rm "$TEMP_FILE"
    fi
  else
    echo "Failed to download new docker-compose.yml. No changes made."
  fi

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
  echo "Pruning Docker system..."
  docker system prune --all -f

  echo "Starting Docker Compose database service..."
  sudo docker-compose up -d db

  echo "Waiting for the database service to be fully operational..."
  sleep 10

  echo "Compacting PostgreSQL database..."
  sudo docker-compose exec -e PGPASSWORD=postgres db psql -d calltelemetry_prod -U calltelemetry -c 'VACUUM FULL;'

  echo "System compaction complete."
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
  if [ $? -eq 0 ]; then
    chmod +x /tmp/prep.sh
    /tmp/prep.sh
    echo "Appliance build complete. You MUST reboot to apply changes. You will then be ready to install the Call Telemetry Docker Application."
    echo "*** IMPORTANT - After reboot, you MUST access the appliance on port 2222 - NOT PORT 22. ***"
    echo "When ready, run sudo reboot -n to restart the appliance."
    echo "After the reboot, continue the installation instructions on https://docs.calletlemetry.com/deployment/docker to continue"
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

# Main script logic
case "$1" in
  --help)
    show_help
    ;;
  update)
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
  *)
    echo "Invalid option: $1"
    echo "Use --help to see the list of available commands."
    ;;
esac
