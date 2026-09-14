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
unzip devops-clickhouse-backup-v1.4.0.zip
cd devops-clickhouse-backup
sudo sh install.sh
```

Installer akan:

1. Membuat `/var/lib/sismedika-clickhouse-backup`.
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
/var/lib/sismedika-clickhouse-backup/
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
/var/lib/sismedika-clickhouse-backup/bin/clickhouse-backup.sh check
/var/lib/sismedika-clickhouse-backup/bin/clickhouse-backup.sh status
/var/lib/sismedika-clickhouse-backup/bin/clickhouse-backup.sh list
/var/lib/sismedika-clickhouse-backup/bin/clickhouse-backup.sh backup
/var/lib/sismedika-clickhouse-backup/bin/clickhouse-backup.sh backup full
/var/lib/sismedika-clickhouse-backup/bin/clickhouse-backup.sh backup incremental
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
  /var/lib/sismedika-clickhouse-backup/bin/logsend-clickhouse-backup
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
Local staging root [/var/lib/sismedika-clickhouse-backup/var/data]:
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
git tag v1.4.0
git push origin v1.4.0
```

The release workflow validates the release artifact, regenerates SHA-256 files,
builds the ZIP, and creates a GitHub Release.
