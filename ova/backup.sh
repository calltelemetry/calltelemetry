# Detect installation directory from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
backup_folder_path="${SCRIPT_DIR}/backups"


# File name i.e: dump-2020-06-24.sql
file_name="dump-"`date "+%Y-%m-%d-%H-%M-%S"`".sql"


# ensure the location exists
mkdir -p ${backup_folder_path}


#change database name, username and docker container name
dbname=calltelemetry_prod
username=calltelemetry
container=calltelemetry-db-1


backup_file=${backup_folder_path}/${file_name}

docker exec -e PGPASSWORD=postgres -it ${container} pg_dump -U ${username} -d ${dbname} > ${backup_file}

echo "Dump successful"

# delete all but 5 recent file in backup folder
find ${backup_folder_path} -maxdepth 1 -name "*.sql" -type f | xargs ls -t | awk 'NR>5' | xargs -L1 rm
