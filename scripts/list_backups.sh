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

resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$ROOT_DIR/$path"
  fi
}

SSH_KEY="$(resolve_path "$BACKUP_SSH_KEY")"

if [[ ! -f "$SSH_KEY" ]]; then
  echo "Missing SSH key: $SSH_KEY"
  exit 1
fi

ssh -i "$SSH_KEY" \
  -p "$BACKUP_REMOTE_PORT" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" \
  "find '$BACKUP_REMOTE_DIR' -maxdepth 1 -type f -name '*.dump' -printf '%f\n' | sort -r"
