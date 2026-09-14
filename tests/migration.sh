#!/bin/sh
set -eu

ROOT=$(CDPATH=''; export CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)

TMP="${TMPDIR:-/tmp}/cb-migration.$$"
OLD="$TMP/legacy"
NEW="$TMP/new"
OUT="$TMP/out"
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$OLD/bin" "$OLD/etc" "$OLD/var/data"
printf '#!/bin/sh\nexit 0\n' > "$OLD/bin/clickhouse-backup.sh"
chmod +x "$OLD/bin/clickhouse-backup.sh"

cat > "$OLD/etc/backup.env" <<EOF
LOG_DIR="$OLD/var"
LOCAL_BACKUP_ROOT="$OLD/var/data"
LOGSEND_PATH="$OLD/bin/logsend-clickhouse-backup"
EOF
chmod 600 "$OLD/etc/backup.env"

DEFAULT_PREFIX="$NEW" \
LEGACY_PREFIX="$OLD" \
sh "$ROOT/install.sh" --dry-run --non-interactive --skip-logsend >"$OUT"

grep -q 'Migrasi existing installation ke /opt' "$OUT"
grep -q "mv $OLD -> $NEW" "$OUT"
grep -q "symlink $OLD -> $NEW" "$OUT"

echo "migration: OK"
