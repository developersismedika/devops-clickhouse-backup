#!/bin/sh
set -eu
ROOT=$(CDPATH=''; export CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
grep -q 'CLICKHOUSE_RECEIVE_TIMEOUT.*3600' "$ROOT/clickhouse-backup.sh"
grep -q 'CLICKHOUSE_SEND_TIMEOUT.*3600' "$ROOT/clickhouse-backup.sh"
grep -q 'BACKUP_ASYNC.*true' "$ROOT/clickhouse-backup.sh"
grep -q -- '--receive_timeout' "$ROOT/clickhouse-backup.sh"
grep -q -- '--send_timeout' "$ROOT/clickhouse-backup.sh"
echo "timeout: OK"
