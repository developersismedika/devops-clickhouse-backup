# Changelog

## 1.1.1
- Release version aligned across `VERSION` and `SCRIPT_VERSION`.
- Includes the current installer, backup backend, migration, and progress improvements.

## 1.2.0
- Real multi-database backup support with `BACKUP_SCOPE=databases`.
- `BACKUP_DATABASES` supports a space-separated list such as `bronze primaya`.
- Preflight validates each selected database separately.
- Old `BACKUP_DATABASE="bronze primaya"` configs are auto-normalized to multi-database mode.
- Default installation path is `/opt/sismedika-clickhouse-backup`.
- Existing `/var/lib/sismedika-clickhouse-backup` can be migrated to `/opt`.


## 1.4.0
- GitHub Actions CI for POSIX lint, shell portability, smoke tests, installer dry-run, and package build.
- Tag-based CD workflow creates checksums, ZIP artifact, and GitHub Release.
- CI artifact upload for every successful branch/PR build.

## 1.3.0
- Estimated verbose progress using `system.parts` + `system.backups`.
- Verbose output includes files, written bytes, source estimate, estimated percent, throughput, elapsed time, and ETA.
- `BACKUP_TIMEOUT_SEC=0` means unlimited; systemd uses `TimeoutStartSec=infinity`.
- Interactive S3 or rsync/SSH backend selection.
- Local staging + rsync backend.
- Backend-aware preflight/status.

## 1.2.0
- Bootstrap installer patterned after Sismedika Host Monitor.
- Dedicated `logsend-clickhouse-backup` binary.
- Local ZIP and remote install modes.
- Idempotent config creation.
- SigNoz lifecycle logging.
- systemd/cron service installation.
- Full weekly + incremental daily backup with full fallback.

## 1.1.0
- SigNoz lifecycle logging via logsend.

## 1.0.0
- Initial native ClickHouse S3 backup agent.
