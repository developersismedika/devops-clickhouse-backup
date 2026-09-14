# Changelog

## 1.4.0
- GitHub Actions CI for POSIX lint, shell portability, smoke tests, installer dry-run, and package build.
- Tag-based CD workflow creates checksums, ZIP artifact, and GitHub Release.
- CI artifact upload for every successful branch/PR build.

## 1.3.0
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
