#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy .env.example to .env first."
  exit 1
fi

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
  BACKUP_FILENAME_PREFIX
  BACKUP_REMOTE_HOST
  BACKUP_REMOTE_PORT
  BACKUP_REMOTE_USER
  BACKUP_REMOTE_DIR
  BACKUP_SSH_KEY
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
SSH_KEY="$(resolve_path "$BACKUP_SSH_KEY")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BASE_NAME="${BACKUP_FILENAME_PREFIX}_${POSTGRES_DB}_${TIMESTAMP}"
DUMP_FILE="$LOCAL_DIR/${BASE_NAME}.dump"
GLOBALS_FILE="$LOCAL_DIR/${BASE_NAME}_globals.sql"
CHECKSUM_FILE="$LOCAL_DIR/${BASE_NAME}.sha256"

mkdir -p "$LOCAL_DIR"

if [[ ! -f "$SSH_KEY" ]]; then
  echo "Missing SSH key: $SSH_KEY"
  exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER_NAME" 2>/dev/null || true)" != "true" ]]; then
  echo "Container $POSTGRES_CONTAINER_NAME is not running."
  exit 1
fi

SSH_OPTS=(
  -i "$SSH_KEY"
  -p "$BACKUP_REMOTE_PORT"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
)

echo "Creating database dump: $DUMP_FILE"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc >"$DUMP_FILE"

echo "Creating global roles dump: $GLOBALS_FILE"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER_NAME" \
  pg_dumpall -U "$POSTGRES_USER" --globals-only >"$GLOBALS_FILE"

sha256sum "$DUMP_FILE" "$GLOBALS_FILE" >"$CHECKSUM_FILE"

echo "Uploading backup to remote server"
ssh "${SSH_OPTS[@]}" "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" \
  "mkdir -p '$BACKUP_REMOTE_DIR'"
rsync -az --progress \
  -e "ssh -i $SSH_KEY -p $BACKUP_REMOTE_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
  "$DUMP_FILE" "$GLOBALS_FILE" "$CHECKSUM_FILE" \
  "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}:${BACKUP_REMOTE_DIR}/"

echo "Cleaning local backups older than ${BACKUP_KEEP_LOCAL_DAYS:-2} day(s)"
find "$LOCAL_DIR" -type f -mtime "+${BACKUP_KEEP_LOCAL_DAYS:-2}" -delete

echo "Cleaning remote backups older than ${BACKUP_KEEP_REMOTE_DAYS:-14} day(s)"
ssh "${SSH_OPTS[@]}" "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" \
  "find '$BACKUP_REMOTE_DIR' -type f -mtime '+${BACKUP_KEEP_REMOTE_DAYS:-14}' -delete"

echo "Backup completed successfully."
