#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy .env.example to .env first."
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backup-file.dump>"
  exit 1
fi

BACKUP_NAME="$1"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required_vars=(
  POSTGRES_CONTAINER_NAME
  POSTGRES_USER
  POSTGRES_PASSWORD
  POSTGRES_DB
  BACKUP_LOCAL_DIR
  BACKUP_REMOTE_HOST
  BACKUP_REMOTE_PORT
  BACKUP_REMOTE_USER
  BACKUP_REMOTE_PASSWORD
  BACKUP_REMOTE_DIR
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required variable: $var_name"
    exit 1
  fi
done

resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$ROOT_DIR/$path"
  fi
}

LOCAL_DIR="$(resolve_path "$BACKUP_LOCAL_DIR")"
DUMP_FILE="$LOCAL_DIR/$BACKUP_NAME"
GLOBALS_FILE="${DUMP_FILE%.dump}_globals.sql"
CHECKSUM_FILE="${DUMP_FILE%.dump}.sha256"

mkdir -p "$LOCAL_DIR"

if [[ "$(docker inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER_NAME" 2>/dev/null || true)" != "true" ]]; then
  echo "Container $POSTGRES_CONTAINER_NAME is not running."
  exit 1
fi

if [[ ! -f "$DUMP_FILE" || ! -f "$GLOBALS_FILE" || ! -f "$CHECKSUM_FILE" ]]; then
  echo "Downloading backup from remote server"
  SSHPASS="$BACKUP_REMOTE_PASSWORD" sshpass -e rsync -az \
    --rsh="ssh -p $BACKUP_REMOTE_PORT -o StrictHostKeyChecking=accept-new" \
    "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}:${BACKUP_REMOTE_DIR}/$BACKUP_NAME" \
    "$DUMP_FILE"

  SSHPASS="$BACKUP_REMOTE_PASSWORD" sshpass -e rsync -az \
    --rsh="ssh -p $BACKUP_REMOTE_PORT -o StrictHostKeyChecking=accept-new" \
    "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}:${BACKUP_REMOTE_DIR}/$(basename "$GLOBALS_FILE")" \
    "$GLOBALS_FILE"

  SSHPASS="$BACKUP_REMOTE_PASSWORD" sshpass -e rsync -az \
    --rsh="ssh -p $BACKUP_REMOTE_PORT -o StrictHostKeyChecking=accept-new" \
    "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}:${BACKUP_REMOTE_DIR}/$(basename "$CHECKSUM_FILE")" \
    "$CHECKSUM_FILE"
fi

echo "Verifying checksum"
(cd "$LOCAL_DIR" && sha256sum -c "$(basename "$CHECKSUM_FILE")")

echo "Restoring global roles if present"
if [[ -f "$GLOBALS_FILE" ]]; then
  echo "Existing roles may trigger harmless errors during globals restore."
  if ! cat "$GLOBALS_FILE" | docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
    psql -v ON_ERROR_STOP=0 -U "$POSTGRES_USER" -d postgres; then
    echo "Warning: globals restore could not be completed cleanly. Continuing with database restore."
  fi
fi

echo "Terminating active sessions"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
  psql -U "$POSTGRES_USER" -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$POSTGRES_DB' AND pid <> pg_backend_pid();"

echo "Recreating database $POSTGRES_DB"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
  dropdb -U "$POSTGRES_USER" --if-exists "$POSTGRES_DB"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
  createdb -U "$POSTGRES_USER" "$POSTGRES_DB"

echo "Restoring database dump"
docker cp "$DUMP_FILE" "$POSTGRES_CONTAINER_NAME:/tmp/restore.dump"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges --exit-on-error /tmp/restore.dump
docker exec "$POSTGRES_CONTAINER_NAME" rm -f /tmp/restore.dump

echo "Restore completed successfully."
