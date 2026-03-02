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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
error() { log "FEIL: $1" >&2; exit 1; }

usage() {
    echo "Bruk:"
    echo "  $0 <backup_file>    Gjenopprett fra lokal fil"
    echo "  $0 --list           List tilgjengelige backups"
    echo ""
    echo "Eksempler:"
    echo "  $0 /backups/${PROJECT_NAME}_20260218_030000.sql.gz.gpg"
    echo ""
    echo "Miljovariabler:"
    echo "  BACKUP_ENCRYPTION_KEY    Dekrypteringsnokkel (pakrevd for .gpg-filer)"
    echo "  DB_PASSWORD              Database-passord (pakrevd)"
    exit 1
}

list_backups() {
    log "Tilgjengelige backups i ${BACKUP_DIR} (${PROJECT_NAME}):"
    ls -lh "${BACKUP_DIR}"/${PROJECT_NAME}_*.sql.gz* 2>/dev/null || log "Ingen backups funnet."
}

restore_backup() {
    local backup_file="$1"

    [[ ! -f "$backup_file" ]] && error "Backup-fil finnes ikke: $backup_file"
    [[ -z "$DB_PASSWORD" ]] && error "DB_PASSWORD ma vaere satt"

    log "Gjenoppretter fra: $backup_file"

    if [[ "$backup_file" == *.gpg ]]; then
        [[ -z "$BACKUP_ENCRYPTION_KEY" ]] && error "BACKUP_ENCRYPTION_KEY ma vaere satt for a dekryptere .gpg-filer"
        log "Dekrypterer og gjenoppretter..."
        gpg --batch --yes --decrypt --passphrase "$BACKUP_ENCRYPTION_KEY" < "$backup_file" \
            | gunzip \
            | PGPASSWORD="${DB_PASSWORD}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME"
    elif [[ "$backup_file" == *.gz ]]; then
        log "Pakker ut og gjenoppretter..."
        gunzip -c "$backup_file" \
            | PGPASSWORD="${DB_PASSWORD}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME"
    else
        log "Gjenoppretter ukomprimert fil..."
        PGPASSWORD="${DB_PASSWORD}" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" < "$backup_file"
    fi

    log "Gjenoppretting fullfort!"
}

[[ $# -eq 0 ]] && usage

case "$1" in
    --help|-h) usage ;;
    --list) list_backups ;;
    *) restore_backup "$1" ;;
esac
