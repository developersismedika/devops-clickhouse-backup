#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# =============================================================================
# Sismedika ClickHouse Backup
# =============================================================================
# Backup ClickHouse ke S3:
#   - full mingguan (default: Minggu)
#   - incremental harian dengan SETTINGS base_backup = S3(...)
#   - fallback ke full bila incremental gagal / chain putus
#   - lock atomik, state file, log, preflight
#   - mode native atau Docker
#   - installer systemd / cron fallback
#   - self-update + SHA-256 + rollback
#
# Ditulis untuk POSIX /bin/sh. "local" dipakai dengan trade-off yang sama seperti
# sismedika-host-monitor (dash, busybox ash, FreeBSD sh, mksh, bash mendukung).
#
# SECURITY
#   backup.env adalah shell code dan berisi secret. Pastikan mode 0600.
#   Jangan commit backup.env ke git.
# =============================================================================

set -u
set -f
umask 077
LC_ALL=C
export LC_ALL

VERBOSE=0

CLICKHOUSE_BACKUP_SCRIPT_ID="sismedika-clickhouse-backup"
SCRIPT_VERSION="1.1.2"
STATE_VERSION="1"
APP_NAME="clickhouse-backup"
SERVICE_USER="${SERVICE_USER:-root}"

_CLI_LOG_DIR="${LOG_DIR-}"
_CLI_BACKUP_TIME="${BACKUP_TIME-}"

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }
verbose() { [ "$VERBOSE" -eq 1 ] && printf '[verbose] %s\n' "$*" >&2 || true; }

resolve_self() {
    local src dir base r
    src=$0
    case $src in
        */*) : ;;
        *) r=$(command -v "$0" 2>/dev/null) && [ -n "$r" ] && src=$r ;;
    esac
    if have readlink; then
        r=$(readlink -f -- "$src" 2>/dev/null) && [ -n "$r" ] && src=$r
    fi
    case $src in
        */*) dir=${src%/*}; base=${src##*/} ;;
        *) dir='.'; base=$src ;;
    esac
    r=$(cd -P -- "$dir" 2>/dev/null && pwd -P) && [ -n "$r" ] && dir=$r
    SCRIPT_PATH="$dir/$base"
    SCRIPT_DIR=$dir
    case $SCRIPT_DIR in
        */bin) PREFIX=${SCRIPT_DIR%/bin} ;;
        *) PREFIX=$SCRIPT_DIR ;;
    esac
}
resolve_self

file_mode() {
    local m
    m=$(stat -c '%a' -- "$1" 2>/dev/null) && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
    m=$(stat -f '%Lp' -- "$1" 2>/dev/null) && [ -n "$m" ] && { printf '%s' "$m"; return 0; }
    return 0
}

file_owner() {
    local u
    u=$(stat -c '%u' -- "$1" 2>/dev/null) && [ -n "$u" ] && { printf '%s' "$u"; return 0; }
    u=$(stat -f '%u' -- "$1" 2>/dev/null) && [ -n "$u" ] && { printf '%s' "$u"; return 0; }
    return 0
}

find_env_file() {
    local c
    if [ -n "${BACKUP_ENV-}" ]; then
        ENV_FILE=$BACKUP_ENV
        return 0
    fi
    for c in \
        "$PREFIX/etc/backup.env" \
        "/usr/local/etc/sismedika-clickhouse-backup/backup.env" \
        "/etc/sismedika-clickhouse-backup/backup.env" \
        "${HOME-/nonexistent}/.config/clickhouse-backup.env"
    do
        if [ -r "$c" ]; then
            ENV_FILE=$c
            return 0
        fi
    done
    ENV_FILE="$PREFIX/etc/backup.env"
}

env_file_is_safe() {
    local f mode owner me
    f=$1
    [ -r "$f" ] || return 1

    owner=$(file_owner "$f")
    me=$(id -u 2>/dev/null) || me=''
    if [ -n "$owner" ] && [ -n "$me" ] && [ "$owner" != 0 ] && [ "$owner" != "$me" ]; then
        err "$APP_NAME: $f dimiliki uid $owner (bukan root/kita); diabaikan"
        return 1
    fi

    mode=$(file_mode "$f")
    case $mode in
        '') return 0 ;;
        *[2367])
            err "$APP_NAME: $f bisa ditulis group/other (mode $mode); diabaikan"
            return 1
            ;;
    esac
    return 0
}

find_env_file
if [ -r "$ENV_FILE" ] && env_file_is_safe "$ENV_FILE"; then
    # shellcheck source=/dev/null
    . "$ENV_FILE"
fi

derive_paths() {
    LOG_DIR="${_CLI_LOG_DIR:-${LOG_DIR:-$PREFIX/var}}"
    LOG_FILE="$LOG_DIR/backup.log"
    ERROR_LOG="$LOG_DIR/error.log"
    UPDATE_LOG="$LOG_DIR/update.log"
    STATE_FILE="$LOG_DIR/.state"
    LOCK_DIR="$LOG_DIR/.lock"
}
derive_paths

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
CLICKHOUSE_MODE="${CLICKHOUSE_MODE:-docker}"       # docker | native
CLICKHOUSE_CONTAINER="${CLICKHOUSE_CONTAINER:-his-transformer-clickhouse}"
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-127.0.0.1}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-9000}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
CLICKHOUSE_CONNECT_TIMEOUT="${CLICKHOUSE_CONNECT_TIMEOUT:-10}"
CLICKHOUSE_SEND_TIMEOUT="${CLICKHOUSE_SEND_TIMEOUT:-3600}"
CLICKHOUSE_RECEIVE_TIMEOUT="${CLICKHOUSE_RECEIVE_TIMEOUT:-3600}"
CLICKHOUSE_SECURE="${CLICKHOUSE_SECURE:-false}"

BACKUP_SCOPE="${BACKUP_SCOPE:-database}"           # database | all
BACKUP_DATABASE="${BACKUP_DATABASE:-his_transformer}"
BACKUP_DATABASES="${BACKUP_DATABASES:-}"

BACKUP_BACKEND="${BACKUP_BACKEND:-s3}"             # s3 | rsync
LOCAL_BACKUP_ROOT="${LOCAL_BACKUP_ROOT:-$PREFIX/var/data}"

RSYNC_REMOTE_HOST="${RSYNC_REMOTE_HOST:-}"
RSYNC_REMOTE_USER="${RSYNC_REMOTE_USER:-}"
RSYNC_REMOTE_PORT="${RSYNC_REMOTE_PORT:-22}"
RSYNC_REMOTE_PATH="${RSYNC_REMOTE_PATH:-}"
RSYNC_SSH_KEY="${RSYNC_SSH_KEY:-/root/.ssh/id_ed25519}"
RSYNC_EXTRA_OPTS="${RSYNC_EXTRA_OPTS:--aH --delete-delay}"

S3_ENDPOINT="${S3_ENDPOINT:-https://s3.amazonaws.com}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-clickhouse}"
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"

FULL_BACKUP_DAY="${FULL_BACKUP_DAY:-7}"            # 1=Mon ... 7=Sun
BACKUP_TIME="${_CLI_BACKUP_TIME:-${BACKUP_TIME:-02:00}}"
SYSTEMD_RANDOMIZED_DELAY="${SYSTEMD_RANDOMIZED_DELAY:-5m}"

UPDATE_BASE_URL="${UPDATE_BASE_URL:-}"
UPDATE_CONNECT_TIMEOUT="${UPDATE_CONNECT_TIMEOUT:-5}"
UPDATE_MAX_TIME="${UPDATE_MAX_TIME:-30}"

# -- SigNoz / OTLP log emission ------------------------------------------------
# Model sama dengan sismedika-host-monitor: memakai binary `logsend`.
OTLP_ENABLED="${OTLP_ENABLED:-false}"
OTLP_KEY="${OTLP_KEY:-}"
LOGSEND_PATH="${LOGSEND_PATH:-$PREFIX/bin/logsend-clickhouse-backup}"
LOGSEND_ENDPOINT="${LOGSEND_ENDPOINT:-}"
# header = custom header (default self-hosted SigNoz)
# apikey = signoz-ingestion-key (SigNoz Cloud)
OTLP_AUTH_MODE="${OTLP_AUTH_MODE:-header}"
OTLP_HEADER_NAME="${OTLP_HEADER_NAME:-X-Tenant-Key}"
LOGSEND_SPOOL_DIR="${LOGSEND_SPOOL_DIR:-$LOG_DIR/spool}"

# Optional: bila true, BACKUP memakai ASYNC lalu dipoll. Default synchronous,
# lebih sederhana dan exit code clickhouse-client langsung merepresentasikan job.
BACKUP_ASYNC="${BACKUP_ASYNC:-true}"
BACKUP_POLL_INTERVAL="${BACKUP_POLL_INTERVAL:-10}"
BACKUP_TIMEOUT_SEC="${BACKUP_TIMEOUT_SEC:-0}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
ensure_dir() {
    [ -d "$1" ] && return 0
    mkdir -p -- "$1" 2>/dev/null
}

now_human() { date '+%Y-%m-%d %H:%M:%S'; }
now_compact() { date '+%Y%m%d-%H%M%S'; }
today_iso() { date '+%Y-%m-%d'; }

append_log() {
    local file msg
    file=$1
    shift
    msg=$*
    ensure_dir "$LOG_DIR" || return 1
    printf '%s\n' "$msg" >> "$file" 2>/dev/null || true
}

sql_quote() {
    # SQL string literal: ' -> ''
    # pure shell, no sed dependency.
    local rest ch out
    rest=${1-}
    out=''
    while [ -n "$rest" ]; do
        ch=${rest%"${rest#?}"}
        rest=${rest#?}
        case $ch in
            "'") out=$out"''" ;;
            *) out="$out$ch" ;;
        esac
    done
    SQL_QUOTED=$out
}

normalize_s3_endpoint() {
    # User may set https://s3.amazonaws.com or MinIO endpoint.
    # URL constructed as endpoint/bucket/prefix/path
    S3_ENDPOINT=${S3_ENDPOINT%/}
    S3_PREFIX=${S3_PREFIX#/}
    S3_PREFIX=${S3_PREFIX%/}
}

s3_url_for() {
    local rel
    rel=$1
    normalize_s3_endpoint
    S3_URL="$S3_ENDPOINT/$S3_BUCKET"
    [ -n "$S3_PREFIX" ] && S3_URL="$S3_URL/$S3_PREFIX"
    [ -n "$rel" ] && S3_URL="$S3_URL/$rel"
    S3_URL="${S3_URL%/}/"
}

backup_target_expr() {
    local url quote
    url=$1
    quote="'"
    sql_quote "$url"; local q_url; q_url="$SQL_QUOTED"
    sql_quote "$S3_ACCESS_KEY_ID"; local q_key; q_key="$SQL_QUOTED"
    sql_quote "$S3_SECRET_ACCESS_KEY"; local q_secret; q_secret="$SQL_QUOTED"
    TARGET_EXPR="S3(${quote}${q_url}${quote}, ${quote}${q_key}${quote}, ${quote}${q_secret}${quote})"
}

backup_object_expr() {
    build_database_object_list
}

acquire_lock() {
    ensure_dir "$LOG_DIR" || return 1
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi

    # Stale-lock recovery when PID is clearly dead.
    if [ -r "$LOCK_DIR/pid" ]; then
        read -r oldpid < "$LOCK_DIR/pid" 2>/dev/null || oldpid=''
        case $oldpid in
            ''|*[!0-9]*) : ;;
            *)
                if ! kill -0 "$oldpid" 2>/dev/null; then
                    rm -rf -- "$LOCK_DIR" 2>/dev/null || true
                    if mkdir "$LOCK_DIR" 2>/dev/null; then
                        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
                        return 0
                    fi
                fi
                ;;
        esac
    fi
    return 1
}

release_lock() {
    rm -rf -- "$LOCK_DIR" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
ST_last_success=''
ST_last_type=''
ST_last_backup=''
ST_last_base=''
ST_last_error=''

state_load() {
    ST_last_success=''
    ST_last_type=''
    ST_last_backup=''
    ST_last_base=''
    ST_last_error=''

    [ -r "$STATE_FILE" ] || return 0
    # State is generated by this script. Only accept safe ownership/mode.
    env_file_is_safe "$STATE_FILE" || return 0
    # shellcheck source=/dev/null
    . "$STATE_FILE"
}

state_escape() {
    # Single-quoted shell assignment safe value.
    local rest ch out
    rest=${1-}
    out=''
    while [ -n "$rest" ]; do
        ch=${rest%"${rest#?}"}
        rest=${rest#?}
        case $ch in
            "'") out="$out'\"'\"'" ;;
            *) out="$out$ch" ;;
        esac
    done
    ESCAPED=$out
}

state_save() {
    local tmp
    ensure_dir "$LOG_DIR" || return 1
    tmp="$STATE_FILE.tmp.$$"

    {
        printf "ST_state_version='%s'\n" "$STATE_VERSION"
        state_escape "$ST_last_success"; printf "ST_last_success='%s'\n" "$ESCAPED"
        state_escape "$ST_last_type";    printf "ST_last_type='%s'\n" "$ESCAPED"
        state_escape "$ST_last_backup";  printf "ST_last_backup='%s'\n" "$ESCAPED"
        state_escape "$ST_last_base";    printf "ST_last_base='%s'\n" "$ESCAPED"
        state_escape "$ST_last_error";   printf "ST_last_error='%s'\n" "$ESCAPED"
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }

    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$STATE_FILE"
}

# -----------------------------------------------------------------------------
# ClickHouse execution
# -----------------------------------------------------------------------------
ch_native_args() {
    # Build positional args in caller is awkward in POSIX shell; use direct
    # functions instead of storing shell-escaped command strings.
    :
}

run_sql() {
    # SQL is passed through stdin so S3 secret is not visible as a --query arg.
    local sql rc secure_arg
    sql=$1
    secure_arg=''

    case "$CLICKHOUSE_SECURE" in
        true|1|yes) secure_arg='--secure' ;;
    esac

    case "$CLICKHOUSE_MODE" in
        docker)
            have docker || { err "$APP_NAME: docker tidak ditemukan"; return 127; }
            # Password still becomes an argv of clickhouse-client inside container.
            # Prefer a ClickHouse user with minimal BACKUP/S3 grants and protected env file.
            # shellcheck disable=SC2086
            printf '%s\n' "$sql" | docker exec -i "$CLICKHOUSE_CONTAINER" \
                clickhouse-client \
        --connect_timeout "$CLICKHOUSE_CONNECT_TIMEOUT" \
        --send_timeout "$CLICKHOUSE_SEND_TIMEOUT" \
        --receive_timeout "$CLICKHOUSE_RECEIVE_TIMEOUT" \
                --user "$CLICKHOUSE_USER" \
                --password "$CLICKHOUSE_PASSWORD" \
                $secure_arg
            rc=$?
            ;;
        native)
            have clickhouse-client || { err "$APP_NAME: clickhouse-client tidak ditemukan"; return 127; }
            # shellcheck disable=SC2086
            printf '%s\n' "$sql" | clickhouse-client \
                --host "$CLICKHOUSE_HOST" \
                --port "$CLICKHOUSE_PORT" \
                --user "$CLICKHOUSE_USER" \
                --password "$CLICKHOUSE_PASSWORD" \
                $secure_arg
            rc=$?
            ;;
        *)
            err "$APP_NAME: CLICKHOUSE_MODE harus docker atau native"
            return 2
            ;;
    esac
    return "$rc"
}

ch_query() {
    run_sql "$1"
}

query_scalar() {
    local q out
    q=$1
    out=$(run_sql "$q" 2>/dev/null) || return 1
    # First line only, pure shell.
    case $out in
        *'
'*) out=${out%%'
'*} ;;
    esac
    printf '%s' "$out"
}

container_running() {
    [ "$CLICKHOUSE_MODE" = docker ] || return 0
    have docker || return 1
    [ "$(docker inspect -f '{{.State.Running}}' "$CLICKHOUSE_CONTAINER" 2>/dev/null || printf false)" = true ]
}

# -----------------------------------------------------------------------------
# SigNoz / OTLP
# -----------------------------------------------------------------------------
send_otlp_event() {
    local event severity message backup_type destination base_url status
    local endpoint spool_arg insecure_arg quiet_arg host_name timestamp_iso

    event=$1
    severity=$2
    message=$3
    backup_type=${4-}
    destination=${5-}
    base_url=${6-}
    status=${7-}

    case "$OTLP_ENABLED" in
        true|1|yes) : ;;
        *) return 0 ;;
    esac

    [ -n "$OTLP_KEY" ] || {
        err "$APP_NAME: OTLP_KEY kosong; event SigNoz dilewati"
        return 0
    }
    [ -x "$LOGSEND_PATH" ] || {
        err "$APP_NAME: $LOGSEND_PATH tidak ada / tidak executable; event SigNoz dilewati"
        return 0
    }
    endpoint=$LOGSEND_ENDPOINT
    [ -n "$endpoint" ] || {
        err "$APP_NAME: LOGSEND_ENDPOINT kosong; event SigNoz dilewati"
        return 0
    }

    ensure_dir "$LOGSEND_SPOOL_DIR" || true
    spool_arg=$LOGSEND_SPOOL_DIR

    insecure_arg=''
    case $endpoint in
        http://*) insecure_arg=--insecure ;;
    esac

    quiet_arg=--quiet
    [ -t 2 ] && quiet_arg=''

    case $OTLP_AUTH_MODE in
        apikey)
            SIGNOZ_INGESTION_KEY=$OTLP_KEY
            export SIGNOZ_INGESTION_KEY
            unset LOGSEND_HEADERS 2>/dev/null || true
            ;;
        *)
            LOGSEND_HEADERS="$OTLP_HEADER_NAME=$OTLP_KEY"
            export LOGSEND_HEADERS
            unset SIGNOZ_INGESTION_KEY 2>/dev/null || true
            ;;
    esac

    # Retry kiriman sebelumnya yang gagal; backup tidak boleh gagal hanya
    # karena observability sedang down.
    "$LOGSEND_PATH" --replay --quiet --spool "$spool_arg" >/dev/null 2>&1 || true

    host_name=$(hostname 2>/dev/null || uname -n 2>/dev/null || printf unknown)
    timestamp_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '')

    # shellcheck disable=SC2086
    "$LOGSEND_PATH" \
        --endpoint "$endpoint" \
        --spool "$spool_arg" \
        $insecure_arg $quiet_arg \
        --service "$APP_NAME" \
        --severity "$severity" \
        --event "$event" \
        --message "$message" \
        schema.version="$STATE_VERSION" \
        script.version="$SCRIPT_VERSION" \
        host.name="$host_name" \
        event.timestamp="$timestamp_iso" \
        clickhouse.mode="$CLICKHOUSE_MODE" \
        clickhouse.container="$CLICKHOUSE_CONTAINER" \
        clickhouse.host="$CLICKHOUSE_HOST" \
        clickhouse.database="$BACKUP_DATABASE" \
        backup.scope="$BACKUP_SCOPE" \
        backup.type="$backup_type" \
        backup.status="$status" \
        backup.destination="$destination" \
        backup.base="$base_url" \
        s3.bucket="$S3_BUCKET" \
        s3.prefix="$S3_PREFIX" \
        || err "$APP_NAME: logsend gagal (exit $?); backup tetap berjalan"

    return 0
}

# -----------------------------------------------------------------------------
# Backup backend helpers
# -----------------------------------------------------------------------------
local_backup_path_for() {
    local rel
    rel=$1
    LOCAL_BACKUP_PATH="$LOCAL_BACKUP_ROOT/$rel"
}

sync_rsync_backend() {
    local remote ssh_cmd

    [ "$BACKUP_BACKEND" = rsync ] || return 0

    have rsync || { err "$APP_NAME: rsync tidak ditemukan"; return 1; }
    have ssh || { err "$APP_NAME: ssh tidak ditemukan"; return 1; }
    [ -n "$RSYNC_REMOTE_HOST" ] || { err "$APP_NAME: RSYNC_REMOTE_HOST kosong"; return 1; }
    [ -n "$RSYNC_REMOTE_USER" ] || { err "$APP_NAME: RSYNC_REMOTE_USER kosong"; return 1; }
    [ -n "$RSYNC_REMOTE_PATH" ] || { err "$APP_NAME: RSYNC_REMOTE_PATH kosong"; return 1; }
    [ -r "$RSYNC_SSH_KEY" ] || { err "$APP_NAME: SSH key tidak bisa dibaca: $RSYNC_SSH_KEY"; return 1; }

    remote="$RSYNC_REMOTE_USER@$RSYNC_REMOTE_HOST:$RSYNC_REMOTE_PATH/"
    ssh_cmd="ssh -p $RSYNC_REMOTE_PORT -i $RSYNC_SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=yes"

    # shellcheck disable=SC2086
    rsync $RSYNC_EXTRA_OPTS -e "$ssh_cmd" "$LOCAL_BACKUP_ROOT/" "$remote"
}


# -----------------------------------------------------------------------------
# Database selection helpers
# -----------------------------------------------------------------------------
normalize_database_selection() {
    # Backward compatibility for older configs:
    # BACKUP_SCOPE=database + BACKUP_DATABASE="db1 db2"
    if [ -z "${BACKUP_DATABASES:-}" ] && [ "${BACKUP_SCOPE:-database}" = database ]; then
        case "$BACKUP_DATABASE" in
            *" "*|*"	"*)
                BACKUP_DATABASES=$BACKUP_DATABASE
                BACKUP_SCOPE=databases
                ;;
        esac
    fi

    if [ "${BACKUP_SCOPE:-database}" = databases ] && [ -z "${BACKUP_DATABASES:-}" ]; then
        BACKUP_DATABASES=$BACKUP_DATABASE
    fi
}

validate_database_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*)
            return 1
            ;;
    esac
    return 0
}

database_exists() {
    local db
    db=$1
    validate_database_name "$db" || return 1
    query_scalar "SELECT count() FROM system.databases WHERE name = '$db'" 2>/dev/null \
        | tr -d '\r\n ' | grep -q '^1$'
}

build_database_object_list() {
    local db out
    normalize_database_selection
    out=''

    case "$BACKUP_SCOPE" in
        database)
            validate_database_name "$BACKUP_DATABASE" || {
                err "$APP_NAME: nama database tidak valid: $BACKUP_DATABASE"
                return 1
            }
            BACKUP_OBJECT="DATABASE \`$BACKUP_DATABASE\`"
            ;;
        databases)
            [ -n "$BACKUP_DATABASES" ] || {
                err "$APP_NAME: BACKUP_DATABASES kosong"
                return 1
            }
            for db in $BACKUP_DATABASES; do
                validate_database_name "$db" || {
                    err "$APP_NAME: nama database tidak valid: $db"
                    return 1
                }
                if [ -n "$out" ]; then
                    out="$out, "
                fi
                out="${out}DATABASE \`$db\`"
            done
            [ -n "$out" ] || return 1
            BACKUP_OBJECT=$out
            ;;
        all)
            BACKUP_OBJECT="ALL"
            ;;
        *)
            err "$APP_NAME: BACKUP_SCOPE harus database, databases, atau all"
            return 1
            ;;
    esac
}

check_selected_databases() {
    local db rc
    normalize_database_selection
    rc=0

    case "$BACKUP_SCOPE" in
        database)
            printf '  database            %s\n' "$BACKUP_DATABASE"
            if database_exists "$BACKUP_DATABASE"; then
                printf '  database status     OK\n'
            else
                printf '  database status     GAGAL\n'
                rc=1
            fi
            ;;
        databases)
            printf '  databases           %s\n' "$BACKUP_DATABASES"
            for db in $BACKUP_DATABASES; do
                if database_exists "$db"; then
                    printf '    %-18s OK\n' "$db"
                else
                    printf '    %-18s GAGAL\n' "$db"
                    rc=1
                fi
            done
            ;;
        all)
            printf '  database selection  ALL\n'
            ;;
        *)
            printf '  database status     GAGAL - scope tidak dikenal\n'
            rc=1
            ;;
    esac

    return "$rc"
}


# -----------------------------------------------------------------------------
# Verbose progress helpers
# -----------------------------------------------------------------------------
format_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", u, " ");
        i=1;
        while (b >= 1024 && i < 6) { b=b/1024; i++ }
        if (i == 1) printf "%.0f %s", b, u[i];
        else printf "%.1f %s", b, u[i];
    }'
}

format_duration() {
    _sec=${1:-0}
    [ "$_sec" -ge 0 ] 2>/dev/null || _sec=0
    _d=$(( _sec / 86400 ))
    _h=$(( (_sec % 86400) / 3600 ))
    _m=$(( (_sec % 3600) / 60 ))
    _s=$(( _sec % 60 ))
    if [ "$_d" -gt 0 ]; then
        printf '%dd %02d:%02d:%02d' "$_d" "$_h" "$_m" "$_s"
    else
        printf '%02d:%02d:%02d' "$_h" "$_m" "$_s"
    fi
}

estimate_source_size() {
    local db where
    normalize_database_selection
    where=''

    case "$BACKUP_SCOPE" in
        database)
            validate_database_name "$BACKUP_DATABASE" || return 1
            where="database = '$BACKUP_DATABASE'"
            ;;
        databases)
            for db in $BACKUP_DATABASES; do
                validate_database_name "$db" || return 1
                if [ -n "$where" ]; then
                    where="$where OR "
                fi
                where="${where}database = '$db'"
            done
            ;;
        all)
            where="database NOT IN ('system','information_schema','INFORMATION_SCHEMA')"
            ;;
        *)
            return 1
            ;;
    esac

    SOURCE_EST_BYTES=$(ch_query "
        SELECT toUInt64(coalesce(sum(bytes_on_disk), 0))
        FROM system.parts
        WHERE active AND ($where)
    " 2>/dev/null | tr -d '\r\n ')

    case "$SOURCE_EST_BYTES" in
        ''|*[!0-9]*) SOURCE_EST_BYTES=0 ;;
    esac
    return 0
}

backup_progress_row() {
    local dest q
    dest=$1
    sql_quote "$dest"
    q=$SQL_QUOTED

    # TSV: status, num_files, uncompressed_size, compressed_size, error
    ch_query "
        SELECT
            status,
            toUInt64(num_files),
            toUInt64(uncompressed_size),
            toUInt64(compressed_size),
            replaceRegexpAll(error, '[\\r\\n\\t]+', ' ')
        FROM system.backups
        WHERE name = '$q'
        ORDER BY start_time DESC
        LIMIT 1
        FORMAT TSVRaw
    " 2>/dev/null
}

verbose_progress() {
    local dest elapsed row status files unc comp error pct speed eta written source
    dest=$1
    elapsed=$2
    source=${SOURCE_EST_BYTES:-0}

    row=$(backup_progress_row "$dest" || true)
    [ -n "$row" ] || {
        verbose "backup poll: status=unknown elapsed=$(format_duration "$elapsed")"
        return 0
    }

    status=$(printf '%s\n' "$row" | awk -F '\t' '{print $1}')
    files=$(printf '%s\n' "$row" | awk -F '\t' '{print $2}')
    unc=$(printf '%s\n' "$row" | awk -F '\t' '{print $3}')
    comp=$(printf '%s\n' "$row" | awk -F '\t' '{print $4}')
    error=$(printf '%s\n' "$row" | awk -F '\t' '{print $5}')

    case "$unc" in ''|*[!0-9]*) unc=0 ;; esac
    case "$comp" in ''|*[!0-9]*) comp=0 ;; esac
    case "$files" in ''|*[!0-9]*) files=0 ;; esac

    # Use uncompressed_size as the closest comparable measure to bytes_on_disk.
    # This remains an estimate; ClickHouse backup representation can differ.
    written=$unc
    pct='n/a'
    speed='n/a'
    eta='n/a'

    if [ "$source" -gt 0 ] 2>/dev/null; then
        pct=$(awk -v w="$written" -v t="$source" 'BEGIN {
            p=(t>0 ? w*100/t : 0);
            if (p<0) p=0;
            if (p>99.9) p=99.9;
            printf "%.1f", p
        }')
        if [ "$elapsed" -gt 0 ] 2>/dev/null && [ "$written" -gt 0 ] 2>/dev/null; then
            speed=$(awk -v w="$written" -v e="$elapsed" 'BEGIN { if(e>0) printf "%.0f", w/e; else print 0 }')
            if [ "$speed" -gt 0 ] 2>/dev/null && [ "$written" -lt "$source" ] 2>/dev/null; then
                eta=$(( (source - written) / speed ))
            fi
        fi
    fi

    if [ "$speed" != n/a ]; then
        speed="$(format_bytes "$speed")/s"
    fi
    if [ "$eta" != n/a ]; then
        eta=$(format_duration "$eta")
    fi

    verbose "backup poll: status=${status:-unknown} elapsed=$(format_duration "$elapsed") files=$files written=$(format_bytes "$written") source≈$(format_bytes "$source") progress≈${pct}% speed≈$speed eta≈$eta"
    [ -n "$error" ] && [ "$error" != "0" ] && verbose "backup error: $error"
}

# -----------------------------------------------------------------------------
# Backup operations
# -----------------------------------------------------------------------------
build_backup_sql() {
    local dest base mode async_suffix
    dest=$1
    base=${2-}
    mode=$3

    backup_object_expr || return 1

    case "$BACKUP_BACKEND" in
        s3)
            backup_target_expr "$dest"
            local dest_expr; dest_expr="$TARGET_EXPR"
            ;;
        rsync)
            sql_quote "$dest"; local q_dest quote; q_dest="$SQL_QUOTED"; quote="'"
            local dest_expr; dest_expr="File(${quote}${q_dest}${quote})"
            ;;
        *)
            err "$APP_NAME: BACKUP_BACKEND harus s3 atau rsync"
            return 1
            ;;
    esac

    async_suffix=''
    [ "$BACKUP_ASYNC" = true ] && async_suffix=' ASYNC'

    if [ "$mode" = incremental ]; then
        [ -n "$base" ] || return 1
        case "$BACKUP_BACKEND" in
            s3)
                backup_target_expr "$base"
                local base_expr; base_expr="$TARGET_EXPR"
                ;;
            rsync)
                sql_quote "$base"; local q_base quote; q_base="$SQL_QUOTED"; quote="'"
                local base_expr; base_expr="File(${quote}${q_base}${quote})"
                ;;
        esac
        BACKUP_SQL="BACKUP $BACKUP_OBJECT TO $dest_expr$async_suffix SETTINGS base_backup = $base_expr"
    else
        BACKUP_SQL="BACKUP $BACKUP_OBJECT TO $dest_expr$async_suffix"
    fi
}

wait_async_backup() {
    # For ASYNC mode, find our backup by exact name and poll system.backups.
    local dest start now elapsed row status error
    dest=$1
    start=$(date +%s 2>/dev/null || printf 0)

    while :; do
        sql_quote "$dest"; local q; q="$SQL_QUOTED"
        row=$(run_sql "SELECT concat(status, '|', ifNull(error,'')) FROM system.backups WHERE position(name, '$q') > 0 ORDER BY start_time DESC LIMIT 1 FORMAT TSVRaw" 2>/dev/null || true)

        status=${row%%|*}
        error=''
        case $row in
            *'|'*) error=${row#*|} ;;
        esac

        case "$status" in
            BACKUP_CREATED|RESTORED)
                return 0
                ;;
            BACKUP_FAILED|RESTORE_FAILED)
                [ -n "$error" ] && err "$APP_NAME: ClickHouse backup failed: $error"
                return 1
                ;;
        esac

        now=$(date +%s 2>/dev/null || printf 0)
        elapsed=$(( now - start ))
        if [ "$VERBOSE" -eq 1 ]; then
            verbose_progress "$dest" "$elapsed"
        fi

        if [ "$BACKUP_TIMEOUT_SEC" -gt 0 ] && [ "$start" -gt 0 ] && [ "$elapsed" -ge "$BACKUP_TIMEOUT_SEC" ]; then
            err "$APP_NAME: timeout menunggu async backup (${BACKUP_TIMEOUT_SEC}s)"
            return 1
        fi
        sleep "$BACKUP_POLL_INTERVAL"
    done
}

perform_backup() {
    local mode dest base sql rc
    mode=$1
    dest=$2
    base=${3-}

    SOURCE_EST_BYTES=0
    if [ "$VERBOSE" -eq 1 ]; then
        estimate_source_size || true
        verbose "backup start: mode=$mode destination=$dest base=${base:-none} async=$BACKUP_ASYNC"
        verbose "source estimate: $(format_bytes "${SOURCE_EST_BYTES:-0}")"
    fi

    build_backup_sql "$dest" "$base" "$mode" || return 1
    sql=$BACKUP_SQL

    if ! run_sql "$sql"; then
        return 1
    fi

    if [ "$BACKUP_ASYNC" = true ]; then
        wait_async_backup "$dest" || return 1
    fi

    return 0
}

desired_backup_type() {
    local dow
    dow=$(date +%u 2>/dev/null || printf '')
    case $dow in
        1|2|3|4|5|6|7) : ;;
        *) err "$APP_NAME: date +%u tidak tersedia"; return 1 ;;
    esac

    if [ "$dow" = "$FULL_BACKUP_DAY" ]; then
        DESIRED_TYPE=full
    elif [ -z "$ST_last_backup" ]; then
        DESIRED_TYPE=full
    else
        DESIRED_TYPE=incremental
    fi
}

run_backup() {
    normalize_database_selection
    local forced stamp day rel dest base msg fallback_rel fallback_dest started
    forced=${1-auto}

    ensure_dir "$LOG_DIR" || {
        err "$APP_NAME: tidak bisa membuat $LOG_DIR"
        return 1
    }

    if ! acquire_lock; then
        err "$APP_NAME: backup lain masih berjalan; dilewati"
        return 0
    fi
    trap 'release_lock' EXIT INT TERM

    state_load

    if ! run_preflight_quiet; then
        ST_last_error="preflight failed"
        state_save || true
        append_log "$ERROR_LOG" "[$(now_human)] preflight failed"
        release_lock
        trap - EXIT INT TERM
        return 1
    fi

    case $forced in
        auto) desired_backup_type || { release_lock; trap - EXIT INT TERM; return 1; } ;;
        full|incremental) DESIRED_TYPE=$forced ;;
        *) err "$APP_NAME: tipe backup harus auto|full|incremental"; release_lock; trap - EXIT INT TERM; return 2 ;;
    esac

    if [ "$DESIRED_TYPE" = incremental ] && [ -z "$ST_last_backup" ]; then
        err "$APP_NAME: tidak ada base backup di state; menggunakan full"
        DESIRED_TYPE=full
    fi

    stamp=$(now_compact)
    day=$(today_iso)
    started=$(now_human)

    if [ "$DESIRED_TYPE" = full ]; then
        rel="full/$day/full-$stamp"
        if [ "$BACKUP_BACKEND" = s3 ]; then
            if [ "$BACKUP_BACKEND" = s3 ]; then
        s3_url_for "$rel"; dest=$S3_URL
    else
        local_backup_path_for "$rel"; dest=$LOCAL_BACKUP_PATH
        mkdir -p "$dest" 2>/dev/null || true
    fi
        else
            local_backup_path_for "$rel"; dest=$LOCAL_BACKUP_PATH
            mkdir -p "$dest" 2>/dev/null || true
        fi

        log "$APP_NAME: FULL -> $dest"
        append_log "$LOG_FILE" "[$started] START full $dest"
        send_otlp_event "backup_started" "INFO"             "ClickHouse full backup started"             "full" "$dest" "" "running"

        if perform_backup full "$dest"; then
            if ! sync_rsync_backend; then
                msg="backup lokal berhasil tetapi rsync gagal: $dest"
                ST_last_error=$msg
                state_save || true
                append_log "$ERROR_LOG" "[$(now_human)] $msg"
                send_otlp_event "backup_failed" "ERROR" "$msg" "full" "$dest" "" "sync_failed"
                err "$APP_NAME: $msg"
                release_lock
                trap - EXIT INT TERM
                return 1
            fi
            ST_last_success=$(now_human)
            ST_last_type=full
            ST_last_backup=$dest
            ST_last_base=''
            ST_last_error=''
            state_save || true
            append_log "$LOG_FILE" "[$(now_human)] OK full $dest"
            send_otlp_event "backup_succeeded" "INFO"                 "ClickHouse full backup succeeded"                 "full" "$dest" "" "success"
            log "$APP_NAME: backup full selesai"
            release_lock
            trap - EXIT INT TERM
            return 0
        fi

        msg="full backup gagal: $dest"
        ST_last_error=$msg
        state_save || true
        append_log "$ERROR_LOG" "[$(now_human)] $msg"
        send_otlp_event "backup_failed" "ERROR"             "$msg"             "full" "$dest" "" "failed"
        err "$APP_NAME: $msg"
        release_lock
        trap - EXIT INT TERM
        return 1
    fi

    base=$ST_last_backup
    rel="incremental/$day/inc-$stamp"
    s3_url_for "$rel"; dest=$S3_URL

    log "$APP_NAME: INCREMENTAL -> $dest"
    log "$APP_NAME: base -> $base"
    append_log "$LOG_FILE" "[$started] START incremental $dest base=$base"
    send_otlp_event "backup_started" "INFO"         "ClickHouse incremental backup started"         "incremental" "$dest" "$base" "running"

    if perform_backup incremental "$dest" "$base"; then
        if ! sync_rsync_backend; then
            msg="incremental lokal berhasil tetapi rsync gagal: $dest"
            ST_last_error=$msg
            state_save || true
            append_log "$ERROR_LOG" "[$(now_human)] $msg"
            send_otlp_event "backup_failed" "ERROR" "$msg" "incremental" "$dest" "$base" "sync_failed"
            err "$APP_NAME: $msg"
            release_lock
            trap - EXIT INT TERM
            return 1
        fi
        ST_last_success=$(now_human)
        ST_last_type=incremental
        ST_last_backup=$dest
        ST_last_base=$base
        ST_last_error=''
        state_save || true
        append_log "$LOG_FILE" "[$(now_human)] OK incremental $dest base=$base"
        send_otlp_event "backup_succeeded" "INFO"             "ClickHouse incremental backup succeeded"             "incremental" "$dest" "$base" "success"
        log "$APP_NAME: backup incremental selesai"
        release_lock
        trap - EXIT INT TERM
        return 0
    fi

    # IMPORTANT: never reuse failed incremental destination for fallback full.
    append_log "$ERROR_LOG" "[$(now_human)] incremental gagal $dest base=$base; fallback full"
    send_otlp_event "backup_failed" "ERROR"         "ClickHouse incremental backup failed; trying full fallback"         "incremental" "$dest" "$base" "failed"
    err "$APP_NAME: incremental gagal; mencoba FULL fallback"

    stamp=$(now_compact)
    fallback_rel="full/$day/full-fallback-$stamp"
    if [ "$BACKUP_BACKEND" = s3 ]; then
        s3_url_for "$fallback_rel"; fallback_dest=$S3_URL
    else
        local_backup_path_for "$fallback_rel"; fallback_dest=$LOCAL_BACKUP_PATH
        mkdir -p "$fallback_dest" 2>/dev/null || true
    fi

    send_otlp_event "backup_fallback_started" "WARN"         "ClickHouse full fallback started"         "full-fallback" "$fallback_dest" "$base" "running"

    if perform_backup full "$fallback_dest"; then
        if ! sync_rsync_backend; then
            msg="full fallback lokal berhasil tetapi rsync gagal"
            ST_last_error=$msg
            state_save || true
            append_log "$ERROR_LOG" "[$(now_human)] $msg"
            send_otlp_event "backup_failed" "ERROR" "$msg" "full-fallback" "$fallback_dest" "$base" "sync_failed"
            err "$APP_NAME: $msg"
            release_lock
            trap - EXIT INT TERM
            return 1
        fi
        ST_last_success=$(now_human)
        ST_last_type=full
        ST_last_backup=$fallback_dest
        ST_last_base=''
        ST_last_error=''
        state_save || true
        append_log "$LOG_FILE" "[$(now_human)] OK full-fallback $fallback_dest"
        send_otlp_event "backup_fallback_succeeded" "WARN"             "ClickHouse full fallback succeeded after incremental failure"             "full-fallback" "$fallback_dest" "$base" "success"
        log "$APP_NAME: FULL fallback selesai -> $fallback_dest"
        release_lock
        trap - EXIT INT TERM
        return 0
    fi

    msg="incremental dan full fallback sama-sama gagal"
    ST_last_error=$msg
    state_save || true
    append_log "$ERROR_LOG" "[$(now_human)] $msg"
    send_otlp_event "backup_failed" "ERROR"         "$msg"         "full-fallback" "$fallback_dest" "$base" "failed"
    err "$APP_NAME: $msg"
    release_lock
    trap - EXIT INT TERM
    return 1
}

# -----------------------------------------------------------------------------
# Status / list
# -----------------------------------------------------------------------------
show_status() {
    state_load
    printf 'Sismedika ClickHouse Backup v%s\n\n' "$SCRIPT_VERSION"
    printf 'State\n'
    printf '  last success        %s\n' "${ST_last_success:-never}"
    printf '  last type           %s\n' "${ST_last_type:-none}"
    printf '  last backup         %s\n' "${ST_last_backup:-none}"
    printf '  last base           %s\n' "${ST_last_base:-none}"
    printf '  last error          %s\n' "${ST_last_error:-none}"
    printf '\nClickHouse latest backup records\n'
    run_sql "SELECT id, status, name, start_time, end_time, error FROM system.backups ORDER BY start_time DESC LIMIT 10 FORMAT PrettyCompact" || true
}

list_backups() {
    run_sql "SELECT id, status, name, start_time, end_time, num_files, formatReadableSize(uncompressed_size) AS uncompressed, formatReadableSize(compressed_size) AS compressed, error FROM system.backups ORDER BY start_time DESC LIMIT 30 FORMAT PrettyCompact"
}

# -----------------------------------------------------------------------------
# Restore helper
# -----------------------------------------------------------------------------
restore_backup() {
    local src object sql
    src=${1-}
    [ -n "$src" ] || {
        err "Penggunaan: $APP_NAME restore <s3-url>"
        return 2
    }

    backup_object_expr || return 1
    object=$BACKUP_OBJECT
    backup_target_expr "$src"

    sql="RESTORE $object FROM $TARGET_EXPR"
    log "$APP_NAME: restore $object dari $src"
    run_sql "$sql"
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
detect_init() {
    if [ -d /run/systemd/system ] && have systemctl; then
        INIT_SYS=systemd
    elif have crontab || [ -d /etc/cron.d ]; then
        INIT_SYS=cron
    else
        INIT_SYS=none
    fi
}

run_preflight_quiet() {
    case "$BACKUP_BACKEND" in
        s3)
            [ -n "$S3_BUCKET" ] || return 1
            [ -n "$S3_ACCESS_KEY_ID" ] || return 1
            [ -n "$S3_SECRET_ACCESS_KEY" ] || return 1
            ;;
        rsync)
            have rsync || return 1
            have ssh || return 1
            [ -n "$RSYNC_REMOTE_HOST" ] || return 1
            [ -n "$RSYNC_REMOTE_USER" ] || return 1
            [ -n "$RSYNC_REMOTE_PATH" ] || return 1
            [ -r "$RSYNC_SSH_KEY" ] || return 1
            ensure_dir "$LOCAL_BACKUP_ROOT" || return 1
            ;;
        *) return 1 ;;
    esac
    backup_object_expr >/dev/null 2>&1 || return 1

    case $CLICKHOUSE_MODE in
        docker)
            have docker || return 1
            container_running || return 1
            ;;
        native)
            have clickhouse-client || return 1
            ;;
        *) return 1 ;;
    esac

    query_scalar "SELECT 1" >/dev/null 2>&1 || return 1

    if [ "$BACKUP_SCOPE" = database ]; then
        sql_quote "$BACKUP_DATABASE"; local qdb; qdb="$SQL_QUOTED"
        [ "$(query_scalar "SELECT count() FROM system.databases WHERE name='$qdb'")" = 1 ] || return 1
    fi
    return 0
}

masked() {
    [ -n "${1-}" ] && printf 'set' || printf 'EMPTY'
}

run_check() {
    local rc ch_ok db_ok
    rc=0
    detect_init

    printf 'Sismedika ClickHouse Backup v%s\n\n' "$SCRIPT_VERSION"
    printf 'Runtime\n'
    printf '  os                  %s\n' "$(uname -s 2>/dev/null || printf unknown)"
    printf '  init                %s\n' "$INIT_SYS"
    printf '  prefix              %s\n' "$PREFIX"
    printf '  script              %s\n' "$SCRIPT_PATH"
    printf '  env                 %s\n' "$ENV_FILE"
    printf '  log dir             %s\n' "$LOG_DIR"
    printf '  uid                 %s\n' "$(id -u 2>/dev/null || printf '?')"

    printf '\nClickHouse\n'
    printf '  mode                %s\n' "$CLICKHOUSE_MODE"
    if [ "$CLICKHOUSE_MODE" = docker ]; then
        printf '  container           %s\n' "$CLICKHOUSE_CONTAINER"
        if container_running; then
            printf '  container state     OK\n'
        else
            printf '  container state     GAGAL\n'
            rc=1
        fi
    else
        printf '  host                %s:%s\n' "$CLICKHOUSE_HOST" "$CLICKHOUSE_PORT"
    fi

    ch_ok=false
    if query_scalar "SELECT 1" >/dev/null 2>&1; then
        ch_ok=true
        printf '  connection          OK\n'
        printf '  version             %s\n' "$(query_scalar "SELECT version()" || printf '?')"
    else
        printf '  connection          GAGAL\n'
        rc=1
    fi

    printf '  scope               %s\n' "$BACKUP_SCOPE"
    if ! check_selected_databases; then
        rc=1
    fi


    printf '\nStorage backend\n'
    printf '  backend             %s\n' "$BACKUP_BACKEND"
    case "$BACKUP_BACKEND" in
        s3)
            printf '  endpoint            %s\n' "$S3_ENDPOINT"
            printf '  bucket              %s\n' "${S3_BUCKET:-EMPTY}"
            printf '  prefix              %s\n' "$S3_PREFIX"
            printf '  access key          %s\n' "$(masked "$S3_ACCESS_KEY_ID")"
            printf '  secret key          %s\n' "$(masked "$S3_SECRET_ACCESS_KEY")"
            if [ -n "$S3_BUCKET" ] && [ -n "$S3_ACCESS_KEY_ID" ] && [ -n "$S3_SECRET_ACCESS_KEY" ]; then
                printf '  status              OK\n'
            else
                printf '  status              GAGAL\n'
                rc=1
            fi
            ;;
        rsync)
            printf '  local root          %s\n' "$LOCAL_BACKUP_ROOT"
            printf '  remote              %s@%s:%s\n' "$RSYNC_REMOTE_USER" "$RSYNC_REMOTE_HOST" "$RSYNC_REMOTE_PATH"
            printf '  ssh port            %s\n' "$RSYNC_REMOTE_PORT"
            printf '  ssh key             %s\n' "$RSYNC_SSH_KEY"
            if have rsync && have ssh && [ -n "$RSYNC_REMOTE_HOST" ] && [ -n "$RSYNC_REMOTE_USER" ] && [ -n "$RSYNC_REMOTE_PATH" ] && [ -r "$RSYNC_SSH_KEY" ]; then
                printf '  status              OK\n'
            else
                printf '  status              GAGAL\n'
                rc=1
            fi
            ;;
        *)
            printf '  status              GAGAL - backend tidak dikenal\n'
            rc=1
            ;;
    esac


    printf '\nSchedule\n'
    printf '  time                %s\n' "$BACKUP_TIME"
    printf '  full day            %s (1=Mon ... 7=Sun)\n' "$FULL_BACKUP_DAY"
    printf '  async               %s\n' "$BACKUP_ASYNC"
    if [ "$BACKUP_TIMEOUT_SEC" -eq 0 ]; then
        printf '  backup timeout      unlimited\n'
    else
        printf '  backup timeout      %ss\n' "$BACKUP_TIMEOUT_SEC"
    fi

    state_load
    printf '\nState\n'
    printf '  last success        %s\n' "${ST_last_success:-never}"
    printf '  last type           %s\n' "${ST_last_type:-none}"
    printf '  last backup         %s\n' "${ST_last_backup:-none}"
    printf '  last error          %s\n' "${ST_last_error:-none}"

    printf '\n'
    if [ "$rc" -eq 0 ]; then
        printf 'Status                OK\n'
    else
        printf 'Status                GAGAL\n'
    fi
    return "$rc"
}

# -----------------------------------------------------------------------------
# Self update
# -----------------------------------------------------------------------------
choose_downloader() {
    if have curl; then DOWNLOADER=curl
    elif have wget; then DOWNLOADER=wget
    elif have fetch; then DOWNLOADER=fetch
    else DOWNLOADER=none
    fi
}

choose_hasher() {
    if have sha256sum; then HASHER=sha256sum
    elif have sha256; then HASHER=sha256
    elif have shasum; then HASHER=shasum
    elif have openssl; then HASHER=openssl
    else HASHER=none
    fi
}
choose_downloader
choose_hasher

download_to() {
    local url dest
    url=$1; dest=$2
    case $DOWNLOADER in
        curl)
            curl --fail --silent --show-error --location \
                 --proto '=https' --tlsv1.2 \
                 --retry 2 --retry-delay 3 \
                 --connect-timeout "$UPDATE_CONNECT_TIMEOUT" \
                 --max-time "$UPDATE_MAX_TIME" \
                 -o "$dest" "$url"
            ;;
        wget)
            wget --quiet --https-only --tries=3 \
                 --connect-timeout="$UPDATE_CONNECT_TIMEOUT" \
                 --timeout="$UPDATE_MAX_TIME" \
                 -O "$dest" "$url"
            ;;
        fetch)
            fetch -q -T "$UPDATE_MAX_TIME" -o "$dest" "$url"
            ;;
        *) return 1 ;;
    esac
}

compute_sha256() {
    local out
    case $HASHER in
        sha256sum) out=$(sha256sum -- "$1" 2>/dev/null) || return 1; SHA=${out%% *} ;;
        sha256) out=$(sha256 -q -- "$1" 2>/dev/null) || return 1; SHA=${out%% *} ;;
        shasum) out=$(shasum -a 256 -- "$1" 2>/dev/null) || return 1; SHA=${out%% *} ;;
        openssl) out=$(openssl dgst -sha256 "$1" 2>/dev/null) || return 1; SHA=${out##* } ;;
        *) return 1 ;;
    esac
}

version_key() {
    local v a b c
    v=${1:-0.0.0}
    a=${v%%.*}; v=${v#*.}
    b=${v%%.*}; c=${v#*.}
    VERSION_KEY=$(( ${a:-0} * 1000000 + ${b:-0} * 1000 + ${c:-0} ))
}

get_script_value() {
    local file key line want
    file=$1; key=$2; want="$key=\""
    SCRIPT_VALUE=''
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            "$want"*)
                line=${line#"$want"}
                SCRIPT_VALUE=${line%%\"*}
                return 0
                ;;
        esac
    done < "$file"
    return 1
}

update_self() {
    local base tmp sha_file remote_ver want_sha remote_id old_key new_key
    [ -n "$UPDATE_BASE_URL" ] || { err "$APP_NAME: UPDATE_BASE_URL kosong"; return 1; }
    case $UPDATE_BASE_URL in https://*) : ;; *) err "$APP_NAME: UPDATE_BASE_URL harus HTTPS"; return 1 ;; esac
    [ "$DOWNLOADER" != none ] || { err "$APP_NAME: tidak ada downloader"; return 1; }
    [ "$HASHER" != none ] || { err "$APP_NAME: tidak ada SHA-256 tool"; return 1; }

    base=${UPDATE_BASE_URL%/}
    tmp="${TMPDIR:-/tmp}/clickhouse-backup.$$"
    sha_file="$tmp.sha256"

    download_to "$base/VERSION" "$tmp.version" || { rm -f "$tmp.version"; return 1; }
    read -r remote_ver < "$tmp.version" || remote_ver=''
    rm -f "$tmp.version"

    case $remote_ver in ''|*[!0-9.]*) err "$APP_NAME: VERSION remote invalid"; return 1 ;; esac
    version_key "$SCRIPT_VERSION"; old_key=$VERSION_KEY
    version_key "$remote_ver"; new_key=$VERSION_KEY
    if [ "$new_key" -le "$old_key" ]; then
        log "$APP_NAME: sudah terbaru (v$SCRIPT_VERSION)"
        return 0
    fi

    download_to "$base/clickhouse-backup.sh" "$tmp" || { rm -f "$tmp"; return 1; }
    download_to "$base/clickhouse-backup.sh.sha256" "$sha_file" || { rm -f "$tmp" "$sha_file"; return 1; }
    read -r want_sha rest < "$sha_file" || want_sha=''
    rm -f "$sha_file"
    compute_sha256 "$tmp" || { rm -f "$tmp"; return 1; }
    [ "$want_sha" = "$SHA" ] || { rm -f "$tmp"; err "$APP_NAME: checksum mismatch"; return 1; }

    sh -n "$tmp" || { rm -f "$tmp"; err "$APP_NAME: script remote gagal sh -n"; return 1; }
    get_script_value "$tmp" CLICKHOUSE_BACKUP_SCRIPT_ID || remote_id=''
    remote_id=$SCRIPT_VALUE
    [ "$remote_id" = "$CLICKHOUSE_BACKUP_SCRIPT_ID" ] || { rm -f "$tmp"; err "$APP_NAME: script ID mismatch"; return 1; }

    cp -f -- "$SCRIPT_PATH" "$SCRIPT_PATH.bak" || { rm -f "$tmp"; return 1; }
    chmod 0755 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$SCRIPT_PATH" || return 1

    if ! "$SCRIPT_PATH" version >/dev/null 2>&1; then
        mv -f -- "$SCRIPT_PATH.bak" "$SCRIPT_PATH" 2>/dev/null || true
        err "$APP_NAME: update gagal smoke test; rollback"
        return 1
    fi

    append_log "$UPDATE_LOG" "[$(now_human)] updated v$SCRIPT_VERSION -> v$remote_ver"
    log "$APP_NAME: updated v$SCRIPT_VERSION -> v$remote_ver"
}

rollback_self() {
    [ -f "$SCRIPT_PATH.bak" ] || { err "$APP_NAME: backup script tidak ditemukan"; return 1; }
    mv -f -- "$SCRIPT_PATH.bak" "$SCRIPT_PATH" || return 1
    chmod 0755 "$SCRIPT_PATH" 2>/dev/null || true
    "$SCRIPT_PATH" version
}

# -----------------------------------------------------------------------------
# Installer
# -----------------------------------------------------------------------------
require_root() {
    [ "$(id -u 2>/dev/null || printf 1)" = 0 ] || {
        err "$APP_NAME: '$1' harus dijalankan sebagai root"
        return 1
    }
}

install_systemd() {
    local unit timer hh mm
    hh=${BACKUP_TIME%:*}
    mm=${BACKUP_TIME#*:}

    unit=/etc/systemd/system/clickhouse-backup.service
    timer=/etc/systemd/system/clickhouse-backup.timer

    cat > "$unit" <<EOF
[Unit]
Description=Sismedika ClickHouse S3 Backup
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=$SCRIPT_PATH backup
User=root
Group=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
EOF

    cat > "$timer" <<EOF
[Unit]
Description=Daily Sismedika ClickHouse S3 Backup

[Timer]
OnCalendar=*-*-* ${hh}:${mm}:00
Persistent=true
RandomizedDelaySec=$SYSTEMD_RANDOMIZED_DELAY
Unit=clickhouse-backup.service

[Install]
WantedBy=timers.target
EOF

    chmod 0644 "$unit" "$timer"
    systemctl daemon-reload
    systemctl enable --now clickhouse-backup.timer
    log "  systemd service -> $unit"
    log "  systemd timer   -> $timer"
}

install_cron() {
    local cronfile
    cronfile=/etc/cron.d/clickhouse-backup
    case $BACKUP_TIME in
        [0-2][0-9]:[0-5][0-9]) : ;;
        *) err "$APP_NAME: BACKUP_TIME harus HH:MM untuk cron"; return 1 ;;
    esac
    hh=${BACKUP_TIME%:*}
    mm=${BACKUP_TIME#*:}
    # Strip leading zeros to avoid implementations interpreting octal elsewhere.
    hh=${hh#0}; [ -n "$hh" ] || hh=0
    mm=${mm#0}; [ -n "$mm" ] || mm=0
    printf '%s %s * * * root %s backup >> %s/cron.log 2>&1\n' \
        "$mm" "$hh" "$SCRIPT_PATH" "$LOG_DIR" > "$cronfile"
    chmod 0644 "$cronfile"
    log "  cron -> $cronfile"
}

install_service() {
    require_root install-service || return 1
    detect_init
    ensure_dir "$LOG_DIR" || return 1

    case $INIT_SYS in
        systemd) install_systemd ;;
        cron) install_cron ;;
        *) err "$APP_NAME: systemd/cron tidak ditemukan"; return 1 ;;
    esac
}

uninstall_service() {
    require_root uninstall-service || return 1
    detect_init
    if have systemctl; then
        systemctl disable --now clickhouse-backup.timer 2>/dev/null || true
        rm -f /etc/systemd/system/clickhouse-backup.timer \
              /etc/systemd/system/clickhouse-backup.service
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f /etc/cron.d/clickhouse-backup
    log "$APP_NAME: service/timer dilepas"
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
show_version() {
    printf '%s v%s\n' "$APP_NAME" "$SCRIPT_VERSION"
}

usage() {
    cat <<EOF
Sismedika ClickHouse Backup v$SCRIPT_VERSION

Penggunaan:
  $APP_NAME check
  $APP_NAME backup
  $APP_NAME backup full
  $APP_NAME backup incremental
  $APP_NAME status
  $APP_NAME list
  $APP_NAME restore <s3-url>
  $APP_NAME install-service
  $APP_NAME uninstall-service
  $APP_NAME update
  $APP_NAME rollback
  $APP_NAME version

Opsi global:
  -v, --verbose     tampilkan progress detail/estimasi

Environment:
  $ENV_FILE

Default policy:
  FULL        : weekday $FULL_BACKUP_DAY (1=Mon ... 7=Sun)
  INCREMENTAL : hari lainnya, memakai successful backup sebelumnya sebagai base
  FALLBACK    : incremental gagal -> full ke destination baru
EOF
}

main() {
    local cmd arg

    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    cmd=${1-help}
    arg=${2-}
    case $cmd in
        check|preflight) run_check ;;
        backup|run) run_backup "${arg:-auto}" ;;
        status) show_status ;;
        list) list_backups ;;
        restore) restore_backup "$arg" ;;
        install-service) install_service ;;
        uninstall-service) uninstall_service ;;
        update) update_self ;;
        rollback) rollback_self ;;
        version|--version) show_version ;;
        help|-h|--help) usage ;;
        *) usage >&2; return 2 ;;
    esac
}

main "$@"
