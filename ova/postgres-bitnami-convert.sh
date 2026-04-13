#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: postgres-bitnami-convert.sh [--dry-run] [--image IMAGE] [--data-dir PATH]

Repairs missing PostgreSQL config files in an existing data directory by
generating fresh defaults from the target PostgreSQL image and restoring only
the missing files.

Options:
  --dry-run         Show what would be repaired without writing files
  --image IMAGE     Docker image to use for generating canonical config files
  --data-dir PATH   PostgreSQL data directory (default: ./postgres-data/data)
  -h, --help        Show this help text
EOF
}

log() {
  printf '%s\n' "$*"
}

get_owner() {
  local path="$1"
  if stat -c '%u:%g' "$path" >/dev/null 2>&1; then
    stat -c '%u:%g' "$path"
  else
    stat -f '%u:%g' "$path"
  fi
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

dry_run=false
image="${POSTGRES_IMAGE:-calltelemetry/postgres:14}"
data_dir="${PWD}/postgres-data/data"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    --image)
      shift
      [ $# -gt 0 ] || fail "--image requires a value"
      image="$1"
      ;;
    --data-dir)
      shift
      [ $# -gt 0 ] || fail "--data-dir requires a value"
      data_dir="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
  shift
done

conf_file="${data_dir}/postgresql.conf"
hba_file="${data_dir}/pg_hba.conf"
ident_file="${data_dir}/pg_ident.conf"

if [ ! -d "$data_dir" ]; then
  log "[OK] No PostgreSQL data directory at ${data_dir}; nothing to repair."
  exit 0
fi

if [ ! -f "${data_dir}/PG_VERSION" ]; then
  log "[OK] ${data_dir} is not an initialized PostgreSQL cluster; nothing to repair."
  exit 0
fi

if [ ! -f "${data_dir}/global/pg_control" ]; then
  fail "${data_dir} contains PG_VERSION but is missing global/pg_control; refusing to guess."
fi

missing_files=""
for path in "$conf_file" "$hba_file" "$ident_file"; do
  if [ -d "$path" ]; then
    fail "${path} is a directory; refusing to overwrite it."
  fi
  if [ ! -f "$path" ]; then
    missing_files="${missing_files} ${path##*/}"
  fi
done

if [ -z "$missing_files" ]; then
  log "[OK] PostgreSQL config files already exist in ${data_dir}; nothing to repair."
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is required to generate canonical PostgreSQL config files."
fi

owner="$(get_owner "${data_dir}/PG_VERSION")"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

generated_tar="${tmpdir}/generated-configs.tar"

log "Generating canonical PostgreSQL config files from ${image}..."
docker run --rm --entrypoint sh "$image" -lc '
  set -eu
  tmp_pgdata="$(mktemp -d)"
  initdb_bin="$(find /usr/lib/postgresql -path "*/bin/initdb" | sort | head -1)"
  [ -n "$initdb_bin" ] || exit 1
  chown postgres:postgres "$tmp_pgdata"
  gosu postgres "$initdb_bin" -D "$tmp_pgdata" --auth-local=trust --auth-host=md5 >/dev/null
  tar -C "$tmp_pgdata" -cf - postgresql.conf pg_hba.conf pg_ident.conf
' > "$generated_tar"

tar -xf "$generated_tar" -C "$tmpdir"

restore_file() {
  local src="$1"
  local dst="$2"

  if [ -f "$dst" ]; then
    return 0
  fi

  if [ "$dry_run" = true ]; then
    log "[DRY-RUN] Would restore ${dst}"
    return 0
  fi

  cp "$src" "$dst"
  chown "$owner" "$dst"
  chmod 600 "$dst"
  log "[OK] Restored ${dst}"
}

restore_file "${tmpdir}/postgresql.conf" "$conf_file"
restore_file "${tmpdir}/pg_hba.conf" "$hba_file"
restore_file "${tmpdir}/pg_ident.conf" "$ident_file"

if [ "$dry_run" = true ]; then
  log "[OK] Dry run complete; missing files:${missing_files}"
else
  log "[OK] PostgreSQL compatibility repair complete for ${data_dir}"
fi
