# Sismedika ClickHouse Backup

Installer-style ClickHouse native S3 backup agent, mengikuti pola deployment
`devops-host-monitor`.

## Fitur

- Full backup mingguan.
- Backend storage: **S3** atau **rsync/SSH**.
- Incremental backup harian berbasis `base_backup`.
- Incremental gagal -> full fallback ke destination baru.
- Native ClickHouse `BACKUP` / `RESTORE`.
- Docker atau native `clickhouse-client`.
- Atomic lock dan state file.
- systemd timer dengan fallback cron.
- Lifecycle event ke SigNoz melalui binary `logsend-clickhouse-backup`.
- Telemetry gagal tidak menggagalkan backup.
- `logsend` memiliki dead-letter spool.
- Self-update + SHA-256 + rollback.
- Installer idempotent: `backup.env` lama tidak ditimpa.

## Install dari ZIP / clone

```sh
unzip devops-clickhouse-backup-v1.1.2.zip
cd devops-clickhouse-backup
sudo sh install.sh
```

Installer akan:

1. Membuat `/opt/sismedika-clickhouse-backup`.
2. Memasang `clickhouse-backup.sh`.
3. Mengunduh dan memverifikasi `logsend`, lalu menyimpannya sebagai
   `bin/logsend-clickhouse-backup`.
4. Membuat `etc/backup.env` bila belum ada.
5. Menjalankan preflight.
6. Memasang systemd timer atau cron.

Interactive:

```sh
sudo sh install.sh --interactive
```

Non-interactive:

```sh
sudo \
  CLICKHOUSE_PASSWORD='...' \
  S3_BUCKET='my-clickhouse-backup' \
  S3_ACCESS_KEY_ID='...' \
  S3_SECRET_ACCESS_KEY='...' \
  OTLP_ENABLED=true \
  OTLP_KEY='...' \
  LOGSEND_ENDPOINT='http://10.0.0.10:4318' \
  sh install.sh --non-interactive
```

## Layout hasil instalasi

```text
/opt/sismedika-clickhouse-backup/
├── bin/
│   ├── clickhouse-backup.sh
│   ├── clickhouse-backup.sh.bak       # setelah update, bila ada
│   └── logsend-clickhouse-backup
├── etc/
│   └── backup.env
└── var/
    ├── backup.log
    ├── error.log
    ├── update.log
    ├── .state
    ├── .lock/
    └── spool/
```

## Perintah

```sh
/opt/sismedika-clickhouse-backup/bin/clickhouse-backup.sh check
/opt/sismedika-clickhouse-backup/bin/clickhouse-backup.sh status
/opt/sismedika-clickhouse-backup/bin/clickhouse-backup.sh list
/opt/sismedika-clickhouse-backup/bin/clickhouse-backup.sh backup
/opt/sismedika-clickhouse-backup/bin/clickhouse-backup.sh backup full
/opt/sismedika-clickhouse-backup/bin/clickhouse-backup.sh backup incremental
```

## Jadwal

Default:

```text
02:00 setiap hari
Sunday     -> FULL
Mon-Sat    -> INCREMENTAL
```

Incremental memakai backup sukses terakhir sebagai base. Bila incremental gagal,
agent mencoba FULL fallback ke S3 prefix baru.

## SigNoz

Events:

```text
backup_started
backup_succeeded
backup_failed
backup_fallback_started
backup_fallback_succeeded
```

Filter dasar:

```text
service.name = "clickhouse-backup"
```

Binary telemetry agent ini sengaja terpisah dari host-monitor:

```text
host-monitor:
  .../bin/logsend

clickhouse-backup:
  /opt/sismedika-clickhouse-backup/bin/logsend-clickhouse-backup
```

## Uninstall

Pertahankan runtime/log:

```sh
sudo sh install.sh --uninstall
```

Hapus seluruh prefix:

```sh
sudo sh install.sh --uninstall --purge
```

## Catatan privilege

Backup timer dijalankan sebagai root. Untuk `CLICKHOUSE_MODE=docker`, akses
Docker socket setara dengan privilege host yang sangat tinggi; memasukkan service
user non-root ke grup `docker` tidak memberi isolasi keamanan yang nyata.

## Retention

Jangan menghapus base backup ketika incremental yang bergantung padanya masih
dipertahankan. Gunakan S3 lifecycle dengan kebijakan yang mempertahankan seluruh
backup chain dan lakukan restore test berkala.


## Rsync backend

Interactive wizard:

```text
Backup backend [s3]: rsync
Local staging root [/opt/sismedika-clickhouse-backup/var/data]:
Rsync remote host:
Rsync remote user:
SSH port [22]:
Remote backup path:
SSH private key [/root/.ssh/id_ed25519]:
```

Flow:

```text
ClickHouse native BACKUP
        |
        v
local staging
        |
        v
rsync over SSH
        |
        v
remote backup server
```

Rsync backend requires passwordless SSH using the configured private key.
The agent runs SSH with `BatchMode=yes` and requires an already-trusted host key.

A backup is only marked successful after both the local ClickHouse backup and
the remote rsync complete successfully.


## CI/CD

`.github/workflows/ci.yml` runs on pushes and pull requests:

- ShellCheck and `checkbashisms`
- POSIX syntax validation in `sh`, `dash`, and `bash`
- VERSION / SCRIPT_VERSION consistency
- checksum validation
- Debian, Ubuntu, and Alpine smoke tests
- installer dry-run
- ZIP packaging and CI artifact upload

`.github/workflows/cd.yml` runs for tags such as:

```sh
git tag v1.1.2
git push origin v1.1.2
```

The release workflow validates the release artifact, regenerates SHA-256 files,
builds the ZIP, and creates a GitHub Release.


## Multiple selected databases

```sh
BACKUP_SCOPE="databases"
BACKUP_DATABASES="bronze primaya"
```

This generates one native ClickHouse backup chain containing both selected
databases. Preflight checks `bronze` and `primaya` separately.

Old configs containing:

```sh
BACKUP_SCOPE="database"
BACKUP_DATABASE="bronze primaya"
```

remain supported and are normalized at runtime to multi-database mode.


## Long-running backup timeout

Long full backups can exceed the ClickHouse client's default 300-second receive
timeout. v1.3.0 configures:

```sh
CLICKHOUSE_CONNECT_TIMEOUT="10"
CLICKHOUSE_SEND_TIMEOUT="3600"
CLICKHOUSE_RECEIVE_TIMEOUT="3600"
BACKUP_ASYNC="true"
BACKUP_POLL_INTERVAL="10"
BACKUP_TIMEOUT_SEC="43200"
```

`BACKUP_ASYNC=true` submits the backup asynchronously and polls
`system.backups` until completion, avoiding a long-lived client connection.


## Verbose progress estimation

```sh
/opt/sismedika-clickhouse-backup/bin/clickhouse-backup.sh --verbose backup full
```

Example:

```text
[verbose] backup start: mode=full destination=https://... async=true
[verbose] source estimate: 487.2 GiB
[verbose] backup poll: status=CREATING_BACKUP elapsed=00:50:03 files=18223 written=126.4 GiB source≈487.2 GiB progress≈25.9% speed≈43.1 MiB/s eta≈02:22:00
```

The percentage, throughput, and ETA are estimates. Source size comes from active
`system.parts.bytes_on_disk`; written bytes come from `system.backups`.
ClickHouse backup compression and representation can differ, so these values
must not be treated as exact completion percentages.
