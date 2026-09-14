#!/bin/sh
# shellcheck shell=sh
# =============================================================================
# Sismedika ClickHouse Backup - bootstrap installer
# =============================================================================
#
# Local ZIP/repository:
#   sudo sh install.sh
#
# Remote bootstrap:
#   curl -fsSL https://raw.githubusercontent.com/developersismedika/devops-clickhouse-backup/main/install.sh | sudo sh
#
# Non-interactive with configuration:
#   curl -fsSL .../install.sh | sudo \
#     S3_BUCKET="backup-prod" \
#     S3_ACCESS_KEY_ID="..." \
#     S3_SECRET_ACCESS_KEY="..." \
#     CLICKHOUSE_PASSWORD="..." \
#     sh
#
# Idempotent: backup.env yang sudah ada TIDAK ditimpa.
# =============================================================================

set -eu
umask 022
LC_ALL=C
export LC_ALL

APP="sismedika-clickhouse-backup"
REPO="${CB_REPO:-developersismedika/devops-clickhouse-backup}"
LOGSEND_REPO="${LOGSEND_REPO:-icaksh/opentelemetry-cli-send-log}"
CHANNEL="${CHANNEL:-main}"
PIN_VERSION="${PIN_VERSION:-}"

DEFAULT_PREFIX="${DEFAULT_PREFIX:-/opt/$APP}"
LEGACY_PREFIX="${LEGACY_PREFIX:-/var/lib/$APP}"
PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
BIN_DIR="$PREFIX/bin"
ETC_DIR="$PREFIX/etc"
VAR_DIR="$PREFIX/var"
ENV_FILE="$ETC_DIR/backup.env"
AGENT="$BIN_DIR/clickhouse-backup.sh"
LOGSEND_BIN="$BIN_DIR/logsend-clickhouse-backup"

CLICKHOUSE_MODE="${CLICKHOUSE_MODE:-docker}"
CLICKHOUSE_CONTAINER="${CLICKHOUSE_CONTAINER:-his-transformer-clickhouse}"
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-127.0.0.1}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-9000}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-clickhouse}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
BACKUP_SCOPE="${BACKUP_SCOPE:-database}"
BACKUP_DATABASE="${BACKUP_DATABASE:-his_transformer}"

BACKUP_BACKEND="${BACKUP_BACKEND:-s3}"
LOCAL_BACKUP_ROOT="${LOCAL_BACKUP_ROOT:-$PREFIX/var/data}"
RSYNC_REMOTE_HOST="${RSYNC_REMOTE_HOST:-}"
RSYNC_REMOTE_USER="${RSYNC_REMOTE_USER:-}"
RSYNC_REMOTE_PORT="${RSYNC_REMOTE_PORT:-22}"
RSYNC_REMOTE_PATH="${RSYNC_REMOTE_PATH:-}"
RSYNC_SSH_KEY="${RSYNC_SSH_KEY:-/root/.ssh/id_ed25519}"
RSYNC_EXTRA_OPTS="${RSYNC_EXTRA_OPTS:--aH --delete-delay}"

S3_ENDPOINT="${S3_ENDPOINT:-https://s3.amazonaws.com}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-his-transformer}"
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"

FULL_BACKUP_DAY="${FULL_BACKUP_DAY:-7}"
BACKUP_TIME="${BACKUP_TIME:-02:00}"

OTLP_ENABLED="${OTLP_ENABLED:-false}"
OTLP_KEY="${OTLP_KEY:-}"
LOGSEND_ENDPOINT="${LOGSEND_ENDPOINT:-}"
OTLP_AUTH_MODE="${OTLP_AUTH_MODE:-header}"
OTLP_HEADER_NAME="${OTLP_HEADER_NAME:-X-Tenant-Key}"

DRY_RUN=0
DO_UNINSTALL=0
DO_PURGE=0
SKIP_LOGSEND="${SKIP_LOGSEND:-0}"
INTERACTIVE=0
NON_INTERACTIVE=0
MIGRATED_LEGACY=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_B=$(printf '\033[1m'); C_G=$(printf '\033[32m')
    C_Y=$(printf '\033[33m'); C_R=$(printf '\033[31m'); C_0=$(printf '\033[0m')
else
    C_B=''; C_G=''; C_Y=''; C_R=''; C_0=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_G" "$C_0" "$C_B" "$*" "$C_0"; }
say()  { printf '    %s\n' "$*"; }
warn() { printf '%s !! %s%s\n' "$C_Y" "$*" "$C_0" >&2; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

usage() {
    cat <<EOF
Sismedika ClickHouse Backup - installer

  sudo sh install.sh
  curl -fsSL <install-url> | sudo sh
  curl -fsSL <install-url> | sudo sh -s -- [opsi]

Opsi:
  --version X.Y.Z      Pasang versi GitHub Release tertentu
  --channel NAMA       Branch sumber (default: main)
  --interactive, -i    Wizard konfigurasi via /dev/tty
  --non-interactive    Pakai environment/default saja
  --skip-logsend       Jangan unduh binary logsend
  --dry-run            Hanya tampilkan perubahan
  --uninstall          Lepas service + bin/config; var dipertahankan
  --purge              Dengan --uninstall, hapus seluruh prefix
  -h, --help           Bantuan

Environment utama:
  CLICKHOUSE_MODE=docker|native
  CLICKHOUSE_CONTAINER
  CLICKHOUSE_USER / CLICKHOUSE_PASSWORD
  BACKUP_SCOPE=database|all
  BACKUP_DATABASE
  BACKUP_BACKEND=s3|rsync
  S3_ENDPOINT / S3_BUCKET / S3_PREFIX
  S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY
  RSYNC_REMOTE_HOST / RSYNC_REMOTE_USER / RSYNC_REMOTE_PATH
  RSYNC_REMOTE_PORT / RSYNC_SSH_KEY
  FULL_BACKUP_DAY=7
  BACKUP_TIME=02:00
  OTLP_ENABLED=true|false
  OTLP_KEY / LOGSEND_ENDPOINT / OTLP_AUTH_MODE / OTLP_HEADER_NAME
EOF
}

need_val() { [ "$1" -ge 2 ] || die "opsi $2 butuh nilai"; }
while [ $# -gt 0 ]; do
    case $1 in
        --version) need_val $# --version; PIN_VERSION=$2; shift 2 ;;
        --version=*) PIN_VERSION=${1#*=}; shift ;;
        --channel) need_val $# --channel; CHANNEL=$2; shift 2 ;;
        --channel=*) CHANNEL=${1#*=}; shift ;;
        --interactive|-i) INTERACTIVE=1; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --skip-logsend) SKIP_LOGSEND=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --uninstall) DO_UNINSTALL=1; shift ;;
        --purge) DO_PURGE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "opsi tidak dikenal: $1" ;;
    esac
done

TTY=/dev/tty
have_tty() { [ -c "$TTY" ] 2>/dev/null && [ -r "$TTY" ] 2>/dev/null; }
ask() {
    printf '  %s [%s]: ' "$1" "${2:-kosong}"
    REPLY=''
    IFS= read -r REPLY < "$TTY" 2>/dev/null || REPLY=''
    [ -n "$REPLY" ] || REPLY=$2
}
ask_secret() {
    REPLY=''
    have stty && stty -echo < "$TTY" 2>/dev/null || true
    printf '  %s: ' "$1"
    IFS= read -r REPLY < "$TTY" 2>/dev/null || REPLY=''
    have stty && stty echo < "$TTY" 2>/dev/null || true
    printf '\n'
}
ask_choice() {
    while :; do
        ask "$1" "$2"
        case "|$3|" in *"|$REPLY|"*) return 0 ;; esac
        printf '    pilihan: %s\n' "$3"
    done
}

run_wizard() {
    printf '\n%s== Konfigurasi ClickHouse Backup ==%s\n' "$C_B" "$C_0"
    ask_choice "Mode ClickHouse" "$CLICKHOUSE_MODE" "docker|native"
    CLICKHOUSE_MODE=$REPLY
    if [ "$CLICKHOUSE_MODE" = docker ]; then
        ask "Container ClickHouse" "$CLICKHOUSE_CONTAINER"; CLICKHOUSE_CONTAINER=$REPLY
    else
        ask "ClickHouse host" "$CLICKHOUSE_HOST"; CLICKHOUSE_HOST=$REPLY
        ask "ClickHouse port" "$CLICKHOUSE_PORT"; CLICKHOUSE_PORT=$REPLY
    fi
    ask "ClickHouse user" "$CLICKHOUSE_USER"; CLICKHOUSE_USER=$REPLY
    [ -n "$CLICKHOUSE_PASSWORD" ] || { ask_secret "ClickHouse password"; CLICKHOUSE_PASSWORD=$REPLY; }

    ask_choice "Backup scope" "$BACKUP_SCOPE" "database|all"; BACKUP_SCOPE=$REPLY
    if [ "$BACKUP_SCOPE" = database ]; then
        ask "Database" "$BACKUP_DATABASE"; BACKUP_DATABASE=$REPLY
    fi

    ask_choice "Backup backend" "$BACKUP_BACKEND" "s3|rsync"
    BACKUP_BACKEND=$REPLY

    if [ "$BACKUP_BACKEND" = s3 ]; then
        ask "S3 endpoint" "$S3_ENDPOINT"; S3_ENDPOINT=$REPLY
        ask "S3 bucket" "$S3_BUCKET"; S3_BUCKET=$REPLY
        ask "S3 prefix" "$S3_PREFIX"; S3_PREFIX=$REPLY
        [ -n "$S3_ACCESS_KEY_ID" ] || { ask_secret "S3 access key"; S3_ACCESS_KEY_ID=$REPLY; }
        [ -n "$S3_SECRET_ACCESS_KEY" ] || { ask_secret "S3 secret key"; S3_SECRET_ACCESS_KEY=$REPLY; }
    else
        ask "Local staging root" "$LOCAL_BACKUP_ROOT"; LOCAL_BACKUP_ROOT=$REPLY
        ask "Rsync remote host" "$RSYNC_REMOTE_HOST"; RSYNC_REMOTE_HOST=$REPLY
        ask "Rsync remote user" "$RSYNC_REMOTE_USER"; RSYNC_REMOTE_USER=$REPLY
        ask "SSH port" "$RSYNC_REMOTE_PORT"; RSYNC_REMOTE_PORT=$REPLY
        ask "Remote backup path" "$RSYNC_REMOTE_PATH"; RSYNC_REMOTE_PATH=$REPLY
        ask "SSH private key" "$RSYNC_SSH_KEY"; RSYNC_SSH_KEY=$REPLY
    fi

    ask "Full backup day (1=Mon..7=Sun)" "$FULL_BACKUP_DAY"; FULL_BACKUP_DAY=$REPLY
    ask "Backup time HH:MM" "$BACKUP_TIME"; BACKUP_TIME=$REPLY

    ask_choice "Kirim lifecycle log ke SigNoz?" "$OTLP_ENABLED" "true|false"
    OTLP_ENABLED=$REPLY
    if [ "$OTLP_ENABLED" = true ]; then
        [ -n "$OTLP_KEY" ] || { ask_secret "OTLP key"; OTLP_KEY=$REPLY; }
        ask "OTLP endpoint" "$LOGSEND_ENDPOINT"; LOGSEND_ENDPOINT=$REPLY
        ask_choice "OTLP auth mode" "$OTLP_AUTH_MODE" "header|apikey"; OTLP_AUTH_MODE=$REPLY
    fi
}

if [ "$NON_INTERACTIVE" -eq 0 ] && [ "$DO_UNINSTALL" -eq 0 ] && [ "$INTERACTIVE" -eq 0 ]; then
    [ -t 0 ] && INTERACTIVE=1
fi
if [ "$INTERACTIVE" -eq 1 ] && [ "$DO_UNINSTALL" -eq 0 ] && have_tty; then
    run_wizard
fi

OS=$(uname -s 2>/dev/null || printf unknown)
MACH=$(uname -m 2>/dev/null || printf unknown)
case $OS in
    Linux) PLATFORM=linux ;;
    FreeBSD) PLATFORM=freebsd ;;
    Darwin) PLATFORM=darwin ;;
    *) die "OS tidak didukung: $OS" ;;
esac
case $MACH in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) ARCH=unsupported ;;
esac

# Local bundle takes precedence when install.sh sits next to agent/checksum.
SCRIPT_DIR=$(CDPATH=''; export CDPATH; cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P || printf '.')
LOCAL_BUNDLE=0
if [ -r "$SCRIPT_DIR/clickhouse-backup.sh" ] && [ -r "$SCRIPT_DIR/clickhouse-backup.sh.sha256" ]; then
    LOCAL_BUNDLE=1
fi

if [ -n "${CB_BASE_URL:-}" ]; then
    BASE_URL=$CB_BASE_URL
elif [ -n "$PIN_VERSION" ]; then
    BASE_URL="https://github.com/$REPO/releases/download/v$PIN_VERSION"
else
    BASE_URL="https://raw.githubusercontent.com/$REPO/$CHANNEL"
fi
case $BASE_URL in https://*) : ;; *) die "BASE_URL harus HTTPS" ;; esac

UPDATE_BASE_URL="${UPDATE_BASE_URL:-https://raw.githubusercontent.com/$REPO/$CHANNEL}"
LOGSEND_BASE="${CB_LOGSEND_BASE:-https://github.com/$LOGSEND_REPO/releases/latest/download}"

DOWNLOADER=none
if have curl; then DOWNLOADER=curl
elif have wget; then DOWNLOADER=wget
elif have fetch; then DOWNLOADER=fetch
fi

HASHER=none
if have sha256sum; then HASHER=sha256sum
elif have sha256; then HASHER=sha256
elif have shasum; then HASHER=shasum
elif have openssl; then HASHER=openssl
fi

fetch_url() {
    _url=$1; _dest=$2
    case $DOWNLOADER in
        curl) curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 -o "$_dest" "$_url" ;;
        wget) wget -q --https-only --tries=3 --timeout=120 -O "$_dest" "$_url" ;;
        fetch) fetch -q -T 120 -o "$_dest" "$_url" ;;
        *) return 1 ;;
    esac
}
sha_of() {
    case $HASHER in
        sha256sum) sha256sum -- "$1" | awk '{print $1}' ;;
        sha256) sha256 -q -- "$1" ;;
        shasum) shasum -a 256 -- "$1" | awk '{print $1}' ;;
        openssl) openssl dgst -sha256 "$1" | awk '{print $NF}' ;;
        *) return 1 ;;
    esac
}


rewrite_legacy_paths() {
    _file=$1
    [ -f "$_file" ] || return 0

    _tmp="${_file}.migrate.$$"
    sed "s#${LEGACY_PREFIX}#${PREFIX}#g" "$_file" > "$_tmp" || {
        rm -f "$_tmp"
        return 1
    }
    chown root:root "$_tmp" 2>/dev/null || true
    chmod 0600 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$_file"
}

migrate_legacy_installation() {
    # Only migrate the historical default layout into the new default layout.
    [ "$PREFIX" = "$DEFAULT_PREFIX" ] || return 0
    [ -e "$LEGACY_PREFIX" ] || return 0

    # Previous migration may have left this compatibility symlink.
    if [ -L "$LEGACY_PREFIX" ]; then
        _target=$(readlink "$LEGACY_PREFIX" 2>/dev/null || true)
        case "$_target" in
            "$PREFIX"|"$DEFAULT_PREFIX")
                say "legacy path sudah symlink ke $PREFIX"
                return 0
                ;;
        esac
    fi

    if [ -e "$PREFIX" ]; then
        die "legacy install ditemukan di $LEGACY_PREFIX tetapi $PREFIX juga sudah ada.
Tidak dilakukan merge otomatis untuk mencegah kehilangan data.
Periksa keduanya secara manual sebelum menjalankan installer lagi."
    fi

    step "Migrasi existing installation ke /opt"

    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] stop clickhouse-backup.timer/service"
        say "[dry-run] mv $LEGACY_PREFIX -> $PREFIX"
        say "[dry-run] rewrite path absolut di $PREFIX/etc/backup.env"
        say "[dry-run] symlink $LEGACY_PREFIX -> $PREFIX"
        MIGRATED_LEGACY=1
        return 0
    fi

    if have systemctl; then
        systemctl stop clickhouse-backup.timer 2>/dev/null || true
        systemctl stop clickhouse-backup.service 2>/dev/null || true
    fi

    mkdir -p "$(dirname "$PREFIX")"
    mv "$LEGACY_PREFIX" "$PREFIX" || die "gagal memindahkan $LEGACY_PREFIX ke $PREFIX"

    rewrite_legacy_paths "$PREFIX/etc/backup.env" \
        || die "gagal memperbarui path di backup.env"

    # Compatibility only: data is physically under /opt.
    ln -s "$PREFIX" "$LEGACY_PREFIX" \
        || die "gagal membuat compatibility symlink"

    MIGRATED_LEGACY=1
    say "dipindah    : $LEGACY_PREFIX -> $PREFIX"
    say "compat link : $LEGACY_PREFIX -> $PREFIX"
}

do_uninstall() {
    step "Melepas $APP"
    if [ -x "$AGENT" ]; then
        run "$AGENT" uninstall-service || true
    fi
    run rm -rf "$BIN_DIR" "$ETC_DIR"
    if [ "$DO_PURGE" -eq 1 ]; then
        run rm -rf "$PREFIX"
        if [ -L "$LEGACY_PREFIX" ]; then
            _target=$(readlink "$LEGACY_PREFIX" 2>/dev/null || true)
            [ "$_target" = "$PREFIX" ] && run rm -f "$LEGACY_PREFIX"
        fi
        say "purge: $PREFIX"
    else
        say "runtime/log tetap di $VAR_DIR"
    fi
    step "Selesai"
    exit 0
}

printf '%s\n' "$C_B== Sismedika ClickHouse Backup - installer ==$C_0"
if [ "$DRY_RUN" -eq 0 ]; then
    [ "$(id -u)" -eq 0 ] || die "harus root (gunakan sudo sh install.sh)"
fi
[ "$DO_UNINSTALL" -eq 1 ] && do_uninstall
[ "$HASHER" != none ] || die "butuh utilitas SHA-256"

if [ "$LOCAL_BUNDLE" -eq 0 ]; then
    [ "$DOWNLOADER" != none ] || die "butuh curl/wget/fetch untuk remote install"
fi

migrate_legacy_installation

step "Deteksi platform"
if [ -d /run/systemd/system ] && have systemctl; then INIT=systemd
elif have crontab || [ -d /etc/cron.d ]; then INIT=cron
else INIT=none
fi
say "os          : $OS ($MACH -> $ARCH)"
say "init        : $INIT"
say "prefix      : $PREFIX"
[ "$MIGRATED_LEGACY" -eq 1 ] && say "migration   : $LEGACY_PREFIX -> $PREFIX"
say "local bundle: $LOCAL_BUNDLE"

step "Direktori"
run mkdir -p "$BIN_DIR" "$ETC_DIR" "$VAR_DIR/spool"
run chown root:root "$PREFIX" "$BIN_DIR" "$ETC_DIR"
run chmod 0755 "$PREFIX" "$BIN_DIR"
run chmod 0700 "$ETC_DIR" "$VAR_DIR"
say "$BIN_DIR"
say "$ETC_DIR"
say "$VAR_DIR"

TMPD="${TMPDIR:-/tmp}/.$APP.$$"
run mkdir -p "$TMPD"
cleanup() { rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

step "Agent"
if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] install clickhouse-backup.sh"
else
    if [ "$LOCAL_BUNDLE" -eq 1 ]; then
        cp "$SCRIPT_DIR/clickhouse-backup.sh" "$TMPD/clickhouse-backup.sh"
        cp "$SCRIPT_DIR/clickhouse-backup.sh.sha256" "$TMPD/agent.sha256"
    else
        fetch_url "$BASE_URL/clickhouse-backup.sh" "$TMPD/clickhouse-backup.sh" || die "gagal unduh agent"
        fetch_url "$BASE_URL/clickhouse-backup.sh.sha256" "$TMPD/agent.sha256" || die "gagal unduh checksum"
    fi
    want=$(awk '{print $1; exit}' "$TMPD/agent.sha256" | tr -d '\r\n')
    got=$(sha_of "$TMPD/clickhouse-backup.sh")
    [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum agent tidak cocok"
    sh -n "$TMPD/clickhouse-backup.sh" || die "agent gagal sh -n"
    [ -f "$AGENT" ] && cp -f "$AGENT" "$AGENT.bak"
    cp -f "$TMPD/clickhouse-backup.sh" "$AGENT"
    chown root:root "$AGENT"
    chmod 0755 "$AGENT"
    say "terpasang : $("$AGENT" version)"
    say "checksum  : OK ($got)"
fi

step "Binary logsend khusus ClickHouse"
if [ "$SKIP_LOGSEND" -eq 1 ]; then
    say "dilewati (--skip-logsend)"
elif [ "$ARCH" = unsupported ]; then
    warn "arsitektur tidak didukung logsend"
elif [ "$PLATFORM" = freebsd ] && [ "$ARCH" != amd64 ]; then
    warn "logsend FreeBSD hanya amd64"
elif [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] download logsend-$PLATFORM-$ARCH -> $LOGSEND_BIN"
else
    [ "$DOWNLOADER" != none ] || {
        warn "tidak ada downloader; logsend tidak dipasang"
        SKIP_LOGSEND=1
    }
    if [ "$SKIP_LOGSEND" -eq 0 ]; then
        asset="logsend-$PLATFORM-$ARCH"
        if fetch_url "$LOGSEND_BASE/$asset" "$TMPD/$asset" &&
           fetch_url "$LOGSEND_BASE/checksums.txt" "$TMPD/checksums.txt"; then
            want=$(grep -E "[ *]${asset}\$" "$TMPD/checksums.txt" 2>/dev/null | head -n1 | awk '{print $1}')
            got=$(sha_of "$TMPD/$asset")
            if [ -n "$want" ] && [ "$want" = "$got" ]; then
                cp -f "$TMPD/$asset" "$LOGSEND_BIN"
                chown root:root "$LOGSEND_BIN"
                chmod 0755 "$LOGSEND_BIN"
                say "terpasang : $LOGSEND_BIN"
                say "checksum  : OK"
            else
                warn "checksum logsend tidak cocok / asset tidak tercantum; tidak dipasang"
            fi
        else
            warn "gagal mengunduh logsend; backup tetap dapat berjalan"
        fi
    fi
fi

step "Config"
if [ -f "$ENV_FILE" ]; then
    say "$ENV_FILE sudah ada, TIDAK ditimpa"
else
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] create $ENV_FILE"
    else
        umask 077
        cat > "$ENV_FILE" <<EOF
# =============================================================================
# Sismedika ClickHouse Backup - runtime config
# =============================================================================

CLICKHOUSE_MODE="$CLICKHOUSE_MODE"
CLICKHOUSE_CONTAINER="$CLICKHOUSE_CONTAINER"
CLICKHOUSE_HOST="$CLICKHOUSE_HOST"
CLICKHOUSE_PORT="$CLICKHOUSE_PORT"
CLICKHOUSE_USER="$CLICKHOUSE_USER"
CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD"

BACKUP_SCOPE="$BACKUP_SCOPE"
BACKUP_DATABASE="$BACKUP_DATABASE"

BACKUP_BACKEND="$BACKUP_BACKEND"
LOCAL_BACKUP_ROOT="$LOCAL_BACKUP_ROOT"
RSYNC_REMOTE_HOST="$RSYNC_REMOTE_HOST"
RSYNC_REMOTE_USER="$RSYNC_REMOTE_USER"
RSYNC_REMOTE_PORT="$RSYNC_REMOTE_PORT"
RSYNC_REMOTE_PATH="$RSYNC_REMOTE_PATH"
RSYNC_SSH_KEY="$RSYNC_SSH_KEY"
RSYNC_EXTRA_OPTS="$RSYNC_EXTRA_OPTS"

S3_ENDPOINT="$S3_ENDPOINT"
S3_BUCKET="$S3_BUCKET"
S3_PREFIX="$S3_PREFIX"
S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"

FULL_BACKUP_DAY="$FULL_BACKUP_DAY"
BACKUP_TIME="$BACKUP_TIME"
SYSTEMD_RANDOMIZED_DELAY="5m"

OTLP_ENABLED="$OTLP_ENABLED"
OTLP_KEY="$OTLP_KEY"
LOGSEND_ENDPOINT="$LOGSEND_ENDPOINT"
LOGSEND_PATH="$LOGSEND_BIN"
OTLP_AUTH_MODE="$OTLP_AUTH_MODE"
OTLP_HEADER_NAME="$OTLP_HEADER_NAME"
LOGSEND_SPOOL_DIR="$VAR_DIR/spool"

LOG_DIR="$VAR_DIR"

# Self update
UPDATE_BASE_URL="$UPDATE_BASE_URL"
EOF
        chown root:root "$ENV_FILE"
        chmod 0600 "$ENV_FILE"
        umask 022
        say "dibuat: $ENV_FILE (root:root 0600)"
    fi
fi

step "Preflight"
if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] $AGENT check"
else
    if "$AGENT" check; then
        say "preflight OK"
    else
        warn "preflight belum OK."
        warn "Ini normal bila credential/config belum diisi; edit $ENV_FILE lalu jalankan:"
        warn "  $AGENT check"
    fi
fi

step "Service ($INIT)"
if [ "$INIT" = none ]; then
    warn "init tidak dikenali; service tidak dipasang"
elif [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] $AGENT install-service"
else
    "$AGENT" install-service || die "gagal memasang service"
fi

step "Selesai"
cat <<EOF

  Agent       : $AGENT
  Config      : $ENV_FILE
  Runtime     : $VAR_DIR
  logsend     : $LOGSEND_BIN
  Schedule    : daily $BACKUP_TIME
  Full        : weekday $FULL_BACKUP_DAY (1=Mon..7=Sun)

Perintah:
  $AGENT check
  $AGENT status
  $AGENT list
  $AGENT backup full
  $AGENT backup incremental

Edit konfigurasi:
  sudo vi $ENV_FILE

Systemd:
  systemctl status clickhouse-backup.timer
  systemctl list-timers clickhouse-backup.timer

Uninstall:
  sudo sh install.sh --uninstall
  sudo sh install.sh --uninstall --purge

EOF
