#!/bin/bash
#
# Safekeeper - generisk PostgreSQL backup med NAS + Hetzner StorageBox
# Styres via miljovariabler - ingen prosjektspesifikk kode
#
# Pakrevde miljovariabler:
#   PROJECT_NAME    - Brukes i filnavn og logging
#   DB_PASSWORD     - Database-passord
#
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:?Manglende miljovariabel: PROJECT_NAME}"

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 5 * * *}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-${PROJECT_NAME}}"
DB_USER="${DB_USER:-${PROJECT_NAME}}"

BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

# Fil-backup (valgfritt)
FILES_DIR="${FILES_DIR:-}"

# Hetzner StorageBox
HETZNER_HOST="${HETZNER_HOST:-}"
HETZNER_USER="${HETZNER_USER:-}"
HETZNER_PORT="${HETZNER_PORT:-23}"
HETZNER_BACKUP_PATH="${HETZNER_BACKUP_PATH:-backups/${PROJECT_NAME}}"

SSH_KEY=/tmp/id_ed25519
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o BatchMode=yes -p ${HETZNER_PORT}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
error() { log "ERROR: $1" >&2; exit 1; }

check_requirements() {
    [[ -n "${DB_PASSWORD:-}" ]] || error "Manglende miljovariabel: DB_PASSWORD"

    # Kopier SSH-nokkel med riktige tillatelser (montert nokkel kan ha feil eierskap)
    if [[ -f /root/.ssh/id_ed25519 ]]; then
        cp /root/.ssh/id_ed25519 "${SSH_KEY}"
        chmod 600 "${SSH_KEY}"
    fi
}

hetzner_configured() {
    [[ -n "$HETZNER_HOST" ]] && [[ -n "$HETZNER_USER" ]] && [[ -f "$SSH_KEY" ]]
}

upload_to_hetzner() {
    local backup_file="$1"
    local filename=$(basename "$backup_file")

    if ! hetzner_configured; then
        log "ADVARSEL: Hetzner StorageBox ikke konfigurert - hopper over offsite backup"
        return 0
    fi

    log "Laster opp til Hetzner StorageBox ($HETZNER_HOST)..."

    # Opprett mapper hvis de ikke finnes (ett niva om gangen - Hetzner stotter ikke mkdir -p)
    local path_parts
    IFS='/' read -ra path_parts <<< "${HETZNER_BACKUP_PATH}"
    local current_path=""
    for part in "${path_parts[@]}"; do
        [[ -z "$part" ]] && continue
        current_path="${current_path:+${current_path}/}${part}"
        ssh ${SSH_OPTS} "${HETZNER_USER}@${HETZNER_HOST}" "mkdir ${current_path}" 2>/dev/null || true
    done

    if scp -P "${HETZNER_PORT}" -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=no -o BatchMode=yes \
        "${backup_file}" \
        "${HETZNER_USER}@${HETZNER_HOST}:${HETZNER_BACKUP_PATH}/${filename}"; then
        log "Offsite backup lastet opp: ${HETZNER_BACKUP_PATH}/${filename}"
    else
        log "ADVARSEL: Opplasting til Hetzner feilet - lokal backup er intakt"
    fi
}

cleanup_hetzner() {
    if ! hetzner_configured; then
        return 0
    fi

    log "Rydder gamle backups pa Hetzner StorageBox..."
    local cutoff_ts=$(date -d "-${BACKUP_RETENTION_DAYS} days" +%Y%m%d 2>/dev/null || date -v-${BACKUP_RETENTION_DAYS}d +%Y%m%d 2>/dev/null || echo "")
    [[ -z "$cutoff_ts" ]] && return 0

    ssh ${SSH_OPTS} "${HETZNER_USER}@${HETZNER_HOST}" "ls ${HETZNER_BACKUP_PATH}" 2>/dev/null | while read -r remote_file; do
        local file_date=$(echo "$remote_file" | grep -oP "${PROJECT_NAME}_\K[0-9]{8}" || echo "")
        if [[ -n "$file_date" ]] && [[ "$file_date" < "$cutoff_ts" ]]; then
            log "Sletter gammel offsite backup: $remote_file"
            ssh ${SSH_OPTS} "${HETZNER_USER}@${HETZNER_HOST}" \
                "rm ${HETZNER_BACKUP_PATH}/${remote_file}" 2>/dev/null || true
        fi
    done
}

run_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        backup_file="${BACKUP_DIR}/${PROJECT_NAME}_${timestamp}.sql.gz.gpg"
    else
        backup_file="${BACKUP_DIR}/${PROJECT_NAME}_${timestamp}.sql.gz"
    fi

    log "Starter backup..."

    until PGPASSWORD="${DB_PASSWORD}" pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" > /dev/null 2>&1; do
        log "Venter pa database..."
        sleep 2
    done

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        log "Krypterer backup med GPG (AES256)..."
        PGPASSWORD="${DB_PASSWORD}" pg_dump \
            -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            --no-owner --no-privileges --format=plain \
            | gzip \
            | gpg --batch --yes --symmetric --cipher-algo AES256 \
                --passphrase "$BACKUP_ENCRYPTION_KEY" \
            > "$backup_file"
    else
        log "ADVARSEL: Backup er ikke kryptert. Sett BACKUP_ENCRYPTION_KEY for kryptering."
        PGPASSWORD="${DB_PASSWORD}" pg_dump \
            -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            --no-owner --no-privileges --format=plain | gzip > "$backup_file"
    fi

    local size=$(du -h "$backup_file" | cut -f1)
    log "Backup lagret lokalt: $backup_file ($size)"

    # Last opp til Hetzner StorageBox (offsite)
    upload_to_hetzner "$backup_file"

    # Slett lokale backups eldre enn BACKUP_RETENTION_DAYS
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_*.sql.gz" -mtime "+${BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_*.sql.gz.gpg" -mtime "+${BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true

    # Slett gamle backups pa Hetzner
    cleanup_hetzner

    log "Backup fullfort OK"
}

backup_files() {
    if [[ -z "$FILES_DIR" ]] || [[ ! -d "$FILES_DIR" ]]; then
        return 0
    fi

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        backup_file="${BACKUP_DIR}/${PROJECT_NAME}_files_${timestamp}.tar.gz.gpg"
    else
        backup_file="${BACKUP_DIR}/${PROJECT_NAME}_files_${timestamp}.tar.gz"
    fi

    log "Starter fil-backup av ${FILES_DIR}..."

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        tar czf - -C "$(dirname "$FILES_DIR")" "$(basename "$FILES_DIR")" \
            | gpg --batch --yes --symmetric --cipher-algo AES256 \
                --passphrase "$BACKUP_ENCRYPTION_KEY" \
            > "$backup_file"
    else
        tar czf "$backup_file" -C "$(dirname "$FILES_DIR")" "$(basename "$FILES_DIR")"
    fi

    local size=$(du -h "$backup_file" | cut -f1)
    log "Fil-backup lagret lokalt: $backup_file ($size)"

    # Last opp til Hetzner
    upload_to_hetzner "$backup_file"

    # Rydd opp gamle fil-backups
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_files_*.tar.gz" -mtime "+${BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_files_*.tar.gz.gpg" -mtime "+${BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true

    log "Fil-backup fullfort OK"
}

main() {
    log "=== Safekeeper Backup Service (${PROJECT_NAME}) ==="
    check_requirements
    mkdir -p "$BACKUP_DIR"

    if [[ "${1:-}" == "backup" ]]; then
        run_backup
        backup_files
        exit 0
    fi

    log "Kjorer initial backup..."
    run_backup
    backup_files

    log "Setter opp daglig backup: $BACKUP_SCHEDULE"
    echo "$BACKUP_SCHEDULE /usr/local/bin/backup-entrypoint.sh backup >> /var/log/backup.log 2>&1" > /etc/crontabs/root

    log "Starter cron daemon..."
    exec crond -f -l 2
}

main "$@"
