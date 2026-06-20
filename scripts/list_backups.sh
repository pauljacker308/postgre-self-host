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

SSHPASS="$BACKUP_REMOTE_PASSWORD" sshpass -e ssh \
  -p "$BACKUP_REMOTE_PORT" \
  -o StrictHostKeyChecking=accept-new \
  "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" \
  "find '$BACKUP_REMOTE_DIR' -maxdepth 1 -type f -name '*.dump' -printf '%f\n' | sort -r"
