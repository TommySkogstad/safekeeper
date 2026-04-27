#!/bin/bash
#
# Safekeeper restore - gjenoppretter backup fra lokal fil (NAS)
#
# Bruk:
#   ./restore.sh <backup_file>    # Gjenopprett fra lokal fil
#   ./restore.sh --list           # List tilgjengelige backups
#
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:?Manglende miljovariabel: PROJECT_NAME}"

DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-${PROJECT_NAME}}"
DB_USER="${DB_USER:-${PROJECT_NAME}}"
DB_PASSWORD="${DB_PASSWORD:-}"

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
FILES_DIR="${FILES_DIR:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
error() { log "FEIL: $1" >&2; exit 1; }

# .pgpass for sikker passordoverlevering (unngaar PGPASSWORD i prosessliste)
setup_pgpass() {
    PGPASS_FILE=$(mktemp)
    echo "${DB_HOST}:${DB_PORT}:${DB_NAME}:${DB_USER}:${DB_PASSWORD}" > "$PGPASS_FILE"
    chmod 600 "$PGPASS_FILE"
    export PGPASSFILE="$PGPASS_FILE"
}

cleanup_pgpass() {
    if [[ -n "${PGPASS_FILE:-}" ]]; then
        rm -f "$PGPASS_FILE"
    fi
}
trap cleanup_pgpass EXIT

usage() {
    echo "Bruk:"
    echo "  $0 <backup_file>                    Gjenopprett database-backup"
    echo "  $0 <fil.tar.gz.gpg> [maalmappe]     Gjenopprett fil-backup (default: gjeldende mappe)"
    echo "  $0 --list                            List tilgjengelige database-backups"
    echo "  $0 --list-files                      List tilgjengelige fil-backups"
    echo ""
    echo "Eksempler:"
    echo "  $0 /backups/${PROJECT_NAME}_20260218_030000.sql.gz.gpg"
    echo "  $0 /backups/${PROJECT_NAME}_files_20260218_030000.tar.gz.gpg /var/data"
    echo ""
    echo "Miljovariabler:"
    echo "  BACKUP_ENCRYPTION_KEY    Dekrypteringsnokkel (pakrevd for .gpg-filer)"
    echo "  DB_PASSWORD              Database-passord (pakrevd for database-restore)"
    exit 1
}

list_backups() {
    log "Tilgjengelige backups i ${BACKUP_DIR} (${PROJECT_NAME}):"
    ls -lh "${BACKUP_DIR}/${PROJECT_NAME}"_*.sql.gz* 2>/dev/null || log "Ingen backups funnet."
}

list_files() {
    log "Tilgjengelige fil-backups i ${BACKUP_DIR} (${PROJECT_NAME}):"
    ls -lh "${BACKUP_DIR}/${PROJECT_NAME}"_files_*.tar.gz* 2>/dev/null || log "Ingen fil-backups funnet."
}

verify_checksum() {
    local backup_file="$1"
    if [[ -f "${backup_file}.sha256" ]]; then
        log "Verifiserer checksum..."
        if sha256sum -c "${backup_file}.sha256" > /dev/null 2>&1; then
            log "Checksum verifisert OK"
        else
            error "Checksum-verifisering feilet! Backup-filen kan vaere korrupt."
        fi
    fi
}

restore_files() {
    local backup_file="$1"
    local target_dir="${2:-${FILES_DIR:-.}}"

    target_dir=$(cd "$target_dir" 2>/dev/null && pwd) \
        || error "Maalmappe finnes ikke eller er ikke en katalog: ${2:-${FILES_DIR:-.}}"

    [[ ! -f "$backup_file" ]] && error "Backup-fil finnes ikke: $backup_file"

    verify_checksum "$backup_file"

    [[ -z "$BACKUP_ENCRYPTION_KEY" ]] && error "BACKUP_ENCRYPTION_KEY ma vaere satt for a dekryptere .gpg-filer"

    log "Gjenoppretter filer til: $target_dir"
    gpg --batch --yes --decrypt \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$backup_file" \
        | tar xzf - -C "$target_dir"

    log "Fil-gjenoppretting fullfort!"
}

restore_backup() {
    local backup_file="$1"

    [[ ! -f "$backup_file" ]] && error "Backup-fil finnes ikke: $backup_file"
    [[ -z "$DB_PASSWORD" ]] && error "DB_PASSWORD ma vaere satt"

    setup_pgpass

    verify_checksum "$backup_file"

    log "Gjenoppretter fra: $backup_file"

    if [[ "$backup_file" == *.gpg ]]; then
        [[ -z "$BACKUP_ENCRYPTION_KEY" ]] && error "BACKUP_ENCRYPTION_KEY ma vaere satt for a dekryptere .gpg-filer"
        log "Dekrypterer og gjenoppretter..."
        gpg --batch --yes --decrypt \
            --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
            < "$backup_file" \
            | gunzip \
            | psql --single-transaction -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME"
    elif [[ "$backup_file" == *.gz ]]; then
        log "Pakker ut og gjenoppretter..."
        gunzip -c "$backup_file" \
            | psql --single-transaction -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME"
    else
        log "Gjenoppretter ukomprimert fil..."
        psql --single-transaction -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" < "$backup_file"
    fi

    log "Gjenoppretting fullfort!"
}

[[ $# -eq 0 ]] && usage

case "$1" in
    --help|-h) usage ;;
    --list) list_backups ;;
    --list-files) list_files ;;
    *)
        if [[ "$1" == *.tar.gz.gpg ]]; then
            restore_files "$1" "${2:-}"
        else
            restore_backup "$1"
        fi
        ;;
esac
