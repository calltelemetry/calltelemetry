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

# Ensure necessary directories exist and have correct permissions
mkdir -p "$BACKUP_DIR"
mkdir -p "$BACKUP_FOLDER_PATH"
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
  echo "  self_update         Update the CLI script to the latest version from the repository."
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
  *)
    echo "Invalid option: $1"
    echo "Use --help to see the list of available commands."
    ;;
esac
