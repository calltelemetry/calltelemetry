#! /bin/bash

# Directory for storing backups and other directories to be cleared
BACKUP_DIR="/home/calltelemetry/backups"
BACKUP_FOLDER_PATH="/home/calltelemetry/db_dumps"
SFTP_DIR="sftp/*"
POSTGRES_DATA_DIR="postgres-data"
# Original and backup docker-compose files
ORIGINAL_FILE="docker-compose.yml"
BACKUP_FILE="$BACKUP_DIR/old-docker-compose.yml"
TEMP_FILE="temp-docker-compose.yml"

# Ensure necessary directories exist and have correct permissions
mkdir -p "$BACKUP_DIR"
mkdir -p "$BACKUP_FOLDER_PATH"
sudo chown -R calltelemetry "$BACKUP_DIR"
sudo chown -R calltelemetry "$BACKUP_FOLDER_PATH"

# Function to display help
show_help() {
  echo "Usage: script_name.sh [option]"
  echo
  echo "Options:"
  echo "  --help            Show this help message and exit."
  echo "  update            Update the docker-compose configuration and restart the service."
  echo "  rollback          Roll back to the previous docker-compose configuration."
  echo "  reset             Stop the application, remove data, and restart the application."
  echo "  compact           Prune Docker system and compact the PostgreSQL database."
  echo "  backup            Create a database backup and retain only the last 5 backups."
}

# Function to perform rollback to the old configuration
rollback() {
  if [ -f "$BACKUP_FILE" ]; then
    cp "$BACKUP_FILE" "$ORIGINAL_FILE"
    echo "Rolled back to the previous docker-compose configuration."
    systemctl restart docker-compose-app.service
  else
    echo "No backup file found to rollback."
  fi
}

# Function to update the docker-compose configuration
update() {
  # Timestamped backup of the existing Docker Compose file
  timestamp=$(date "+%Y-%m-%d-%H-%M-%S")
  timestamped_backup_file="$BACKUP_DIR/docker-compose-$timestamp.yml"

  if [ -f "$ORIGINAL_FILE" ]; then
    cp "$ORIGINAL_FILE" "$timestamped_backup_file"
    echo "Existing docker-compose.yml backed up to $timestamped_backup_file"
  fi

  # Download the new Docker Compose file to a temporary location
  wget https://raw.githubusercontent.com/calltelemetry/calltelemetry/master/docker-compose.yml -O "$TEMP_FILE"

  # Check if the Docker Compose file was downloaded successfully
  if [ -f "$TEMP_FILE" ]; then
    # Attempt to pull the new image using the temporary Docker Compose file
    if docker-compose -f "$TEMP_FILE" pull; then
      # If pull is successful, replace the old Docker Compose file
      mv "$TEMP_FILE" "$ORIGINAL_FILE"
      echo "New docker-compose.yml moved to production."
      # Restart the Docker Compose application
      systemctl restart docker-compose-app.service
    else
      # If pull fails, keep the old configuration and remove the temporary file
      echo "Docker image pull failed. Rolling back to previous configuration."
      rollback
      rm "$TEMP_FILE"
    fi
  else
    echo "Failed to download new docker-compose.yml. No changes made."
  fi

  # Remove SSH authorized keys file, if necessary
  # Ensure this action is intentional, as it will remove SSH access
  rm -f /home/calltelemetry/.ssh/authorized_keys
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

  echo "Compacting PostgreSQL database..."
  sudo docker-compose exec -e PGPASSWORD=postgres db psql -d calltelemetry_prod -U calltelemetry -c 'VACUUM FULL;'

  echo "System compaction complete."
}

# Function to create a backup and retain only the last 5 backups
backup() {
  # Location where you want to keep your db dump
  backup_folder_path=$BACKUP_FOLDER_PATH

  # File name i.e: dump-2020-06-24.sql
  file_name="dump-"`date "+%Y-%m-%d-%H-%M-%S"`".sql"

  # Ensure the location exists
  mkdir -p ${backup_folder_path}

  # Change database name, username, and docker container name
  dbname=calltelemetry_prod
  username=calltelemetry
  container=calltelemetry-db-1

  backup_file=${backup_folder_path}/${file_name}

  docker exec -e PGPASSWORD=postgres -it ${container} pg_dump -U ${username} -d ${dbname} > ${backup_file}

  echo "Dump successful: ${backup_file}"

  # Delete all but 5 recent files in backup folder
  find ${backup_folder_path} -maxdepth 1 -name "*.sql" -type f | xargs ls -t | awk 'NR>5' | xargs -L1 rm

  echo "Old backups removed, keeping only the most recent 5."
}

# Main script logic
case "$1" in
  --help)
    show_help
    ;;
  update)
    update
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
  *)
    echo "Invalid option: $1"
    echo "Use --help to see the list of available commands."
    ;;
esac
