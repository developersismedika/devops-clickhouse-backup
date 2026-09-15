#!/bin/sh
set -eu
ROOT=$(CDPATH=''; export CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
grep -q 'BACKUP_SCOPE=databases' "$ROOT/CHANGELOG.md"
grep -q 'BACKUP_DATABASES' "$ROOT/clickhouse-backup.sh"
grep -q 'build_database_object_list' "$ROOT/clickhouse-backup.sh"
grep -q 'check_selected_databases' "$ROOT/clickhouse-backup.sh"
echo "multidb: OK"
