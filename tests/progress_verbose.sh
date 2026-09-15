#!/bin/sh
set -eu
ROOT=$(CDPATH=''; export CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)

grep -q 'estimate_source_size' "$ROOT/clickhouse-backup.sh"
grep -q 'verbose_progress' "$ROOT/clickhouse-backup.sh"
grep -q 'system.parts' "$ROOT/clickhouse-backup.sh"
grep -q 'system.backups' "$ROOT/clickhouse-backup.sh"
grep -q 'progress≈' "$ROOT/clickhouse-backup.sh"
grep -q 'BACKUP_TIMEOUT_SEC.*:-0' "$ROOT/clickhouse-backup.sh"
grep -q 'TimeoutStartSec=infinity' "$ROOT/clickhouse-backup.sh"

echo "progress_verbose: OK"
