#!/bin/sh
set -eu

ROOT=$(CDPATH=''; export CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)

"$ROOT/install.sh" --help >/dev/null
"$ROOT/install.sh" --dry-run --non-interactive --skip-logsend >/tmp/cb-install-dryrun.$$
grep -q 'Sismedika ClickHouse Backup' /tmp/cb-install-dryrun.$$
rm -f /tmp/cb-install-dryrun.$$

echo "installer: OK"
