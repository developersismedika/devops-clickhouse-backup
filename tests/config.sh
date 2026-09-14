#!/bin/sh
set -eu

ROOT=$(CDPATH=''; export CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)

tmp="${TMPDIR:-/tmp}/clickhouse-backup-config.$$"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/etc" "$tmp/var" "$tmp/bin"

cat > "$tmp/etc/backup.env" <<EOF
CLICKHOUSE_MODE="native"
CLICKHOUSE_HOST="127.0.0.1"
CLICKHOUSE_PORT="9000"
CLICKHOUSE_USER="default"
CLICKHOUSE_PASSWORD=""
BACKUP_SCOPE="database"
BACKUP_DATABASE="his_transformer"
BACKUP_BACKEND="rsync"
LOCAL_BACKUP_ROOT="$tmp/var/data"
RSYNC_REMOTE_HOST="backup.internal"
RSYNC_REMOTE_USER="backup"
RSYNC_REMOTE_PORT="22"
RSYNC_REMOTE_PATH="/backup/clickhouse"
RSYNC_SSH_KEY="$tmp/key"
OTLP_ENABLED="false"
LOG_DIR="$tmp/var"
EOF
chmod 600 "$tmp/etc/backup.env"
: > "$tmp/key"
chmod 600 "$tmp/key"

# Syntax-level assertions: both backend code paths must be present.
grep -q 'BACKUP_BACKEND.*s3' "$ROOT/clickhouse-backup.sh"
grep -q 'sync_rsync_backend' "$ROOT/clickhouse-backup.sh"
grep -q 'base_backup' "$ROOT/clickhouse-backup.sh"
grep -q 'backup_fallback_started' "$ROOT/clickhouse-backup.sh"

echo "config: OK"
