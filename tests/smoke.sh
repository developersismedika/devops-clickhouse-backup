#!/bin/sh
set -eu

ROOT=$(CDPATH=''; export CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)

sh -n "$ROOT/clickhouse-backup.sh"
sh -n "$ROOT/install.sh"

out=$("$ROOT/clickhouse-backup.sh" version)
expected="clickhouse-backup v$(cat "$ROOT/VERSION")"
case "$out" in
  "$expected") : ;;
  *) echo "unexpected version: $out" >&2; exit 1 ;;
esac

"$ROOT/install.sh" --help >/dev/null

echo "smoke: OK"
