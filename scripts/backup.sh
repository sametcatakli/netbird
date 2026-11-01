#!/usr/bin/env bash
# Creates a consistent backup of the NetBird data volume, configuration and secrets.
# Usage: backup.sh [destination-directory]   (default: $INSTALL_DIR/backups)
set -Eeuo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/netbird}
readonly DATA_VOLUME=netbird_netbird_data
readonly BACKUP_DIR=${1:-$INSTALL_DIR/backups}
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
readonly TIMESTAMP
readonly ARCHIVE=$BACKUP_DIR/netbird-$TIMESTAMP.tar.gz

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

compose() { docker compose --project-directory "$INSTALL_DIR" "$@"; }

data_dir=$(docker volume inspect --format '{{.Mountpoint}}' "$DATA_VOLUME")
install -d -m 0700 "$BACKUP_DIR"

# The SQLite store is only consistent while the server is stopped.
compose stop netbird-server
trap 'compose start netbird-server' EXIT

umask 077
# Archive layout: _data/ (database volume) and <install-dir-name>/ (config and secrets).
install_name=$(basename "$INSTALL_DIR")
tar -czf "$ARCHIVE" \
  -C "$(dirname "$data_dir")" _data \
  -C "$(dirname "$INSTALL_DIR")" --exclude="$install_name/backups" "$install_name"

echo "Backup written to $ARCHIVE"
