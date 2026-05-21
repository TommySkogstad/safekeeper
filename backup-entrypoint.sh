#!/bin/bash
#
# Safekeeper - generisk PostgreSQL backup med NAS + Hetzner StorageBox
# Styres via miljovariabler - ingen prosjektspesifikk kode
#
# Pakrevde miljovariabler:
#   PROJECT_NAME          - Brukes i filnavn og logging
#   DB_PASSWORD           - Database-passord
#   BACKUP_ENCRYPTION_KEY - GPG-krypteringsnokkel (AES256, pakrevd)
#
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:?Manglende miljovariabel: PROJECT_NAME}"

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 5 * * *}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
BACKUP_SUCCESS_FILE="${BACKUP_SUCCESS_FILE:-/tmp/last-backup-success}"

DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-${PROJECT_NAME}}"
DB_USER="${DB_USER:-${PROJECT_NAME}}"

BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-60}"
BACKUP_RETRY_MAX="${BACKUP_RETRY_MAX:-3}"
BACKUP_RETRY_DELAY="${BACKUP_RETRY_DELAY:-5}"
BACKUP_HEALTHCHECK_WINDOW="${BACKUP_HEALTHCHECK_WINDOW:-93600}"

# Interne fil-stier (kan overstyres i tester via env-variabler)
SAFEKEEPER_ENV_FILE="${SAFEKEEPER_ENV_FILE:-/etc/safekeeper.env}"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"

# Fil-backup (valgfritt)
FILES_DIR="${FILES_DIR:-}"

# Hetzner StorageBox
HETZNER_HOST="${HETZNER_HOST:-}"
HETZNER_USER="${HETZNER_USER:-}"
HETZNER_PORT="${HETZNER_PORT:-23}"
HETZNER_BACKUP_PATH="${HETZNER_BACKUP_PATH:-backups/${PROJECT_NAME}}"

# SSH-nokkel via mktemp (ryddes opp via trap)
SSH_KEY=$(mktemp)
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -p "${HETZNER_PORT}")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
error() { log "ERROR: $1" >&2; exit 1; }

# .pgpass for sikker passordoverlevering (unngaar PGPASSWORD i prosessliste)
setup_pgpass() {
    PGPASS_FILE=$(mktemp)
    echo "${DB_HOST}:${DB_PORT}:${DB_NAME}:${DB_USER}:${DB_PASSWORD}" > "$PGPASS_FILE"
    chmod 600 "$PGPASS_FILE"
    export PGPASSFILE="$PGPASS_FILE"
}

# Rydd opp sensitive filer ved avslutning
cleanup() {
    rm -f "${SSH_KEY:-}"
    [[ -n "${PGPASS_FILE:-}" ]] && rm -f "$PGPASS_FILE"
}
trap cleanup EXIT

validate_cron_schedule() {
    local schedule="$1"
    local parts
    read -ra parts <<< "$schedule"
    [[ ${#parts[@]} -eq 5 ]] || error "BACKUP_SCHEDULE har feil antall felter (forventet 5, fikk ${#parts[@]}): '$schedule'"
}

check_requirements() {
    [[ -n "${DB_PASSWORD:-}" ]] || error "Manglende miljovariabel: DB_PASSWORD"
    [[ -n "$BACKUP_ENCRYPTION_KEY" ]] || error "Manglende miljovariabel: BACKUP_ENCRYPTION_KEY. Kryptering er pakrevd."
    validate_cron_schedule "$BACKUP_SCHEDULE"

    [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9._-]{1,64}$ ]] || error "PROJECT_NAME inneholder ugyldige tegn: '$PROJECT_NAME'"

    if [[ -n "$HETZNER_HOST" ]]; then
        [[ "$HETZNER_HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || error "HETZNER_HOST inneholder ugyldige tegn: '$HETZNER_HOST'"
        if [[ -n "$HETZNER_USER" ]]; then
            [[ "$HETZNER_USER" =~ ^[a-zA-Z0-9_-]+$ ]] || error "HETZNER_USER inneholder ugyldige tegn: '$HETZNER_USER'"
        fi
        [[ "$HETZNER_PORT" =~ ^[0-9]+$ ]] && [[ "$HETZNER_PORT" -ge 1 ]] && [[ "$HETZNER_PORT" -le 65535 ]] \
            || error "HETZNER_PORT er ugyldig: '$HETZNER_PORT'"
        [[ "$HETZNER_BACKUP_PATH" =~ ^[a-zA-Z0-9._/-]+$ ]] || error "HETZNER_BACKUP_PATH inneholder ugyldige tegn: '$HETZNER_BACKUP_PATH'"
        [[ "$HETZNER_BACKUP_PATH" != *".."* ]] || error "HETZNER_BACKUP_PATH kan ikke inneholde '..'"
    fi

    # Kopier SSH-nokkel med riktige tillatelser (montert nokkel kan ha feil eierskap)
    if [[ -f /root/.ssh/id_ed25519 ]]; then
        cp /root/.ssh/id_ed25519 "${SSH_KEY}"
        chmod 600 "${SSH_KEY}"
    fi
}

hetzner_configured() {
    [[ -n "$HETZNER_HOST" ]] && [[ -n "$HETZNER_USER" ]] && [[ -s "$SSH_KEY" ]]
}

upload_to_hetzner() {
    local backup_file="$1"
    local filename
    filename=$(basename "$backup_file")

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
        # shellcheck disable=SC2029 # lokal ekspansjon tilsiktet — verdier validert i check_requirements()
        ssh "${SSH_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" mkdir "${current_path}" 2>/dev/null \
            || ssh "${SSH_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" test -d "${current_path}" \
            || { log "ADVARSEL: Kan ikke opprette eller bekrefte katalog '${current_path}' på Hetzner"; return 1; }
    done

    # Generer checksum for verifisering etter opplasting
    local local_sha256
    local_sha256=$(sha256sum "$backup_file" | cut -d' ' -f1)

    if ! scp -P "${HETZNER_PORT}" -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        "${backup_file}" \
        "${HETZNER_USER}@${HETZNER_HOST}:${HETZNER_BACKUP_PATH}/${filename}"; then
        log "ADVARSEL: Opplasting til Hetzner feilet - lokal backup er intakt"
        return 1
    fi

    # Verifiser checksum pa Hetzner
    local remote_sha256
    # shellcheck disable=SC2029 # lokal ekspansjon tilsiktet — verdier validert i check_requirements()
    remote_sha256=$(ssh "${SSH_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" \
        sha256sum "${HETZNER_BACKUP_PATH}/${filename}" 2>/dev/null | cut -d' ' -f1 || echo "")

    if [[ "$local_sha256" == "$remote_sha256" ]]; then
        log "Offsite backup lastet opp og verifisert: ${HETZNER_BACKUP_PATH}/${filename}"
    elif [[ -z "$remote_sha256" ]]; then
        log "ADVARSEL: Kunne ikke verifisere checksum på Hetzner (sha256sum utilgjengelig) — regnes som opplastingsfeil"
        return 1
    else
        log "ADVARSEL: Checksum-mismatch etter opplasting! Lokal=$local_sha256 Remote=$remote_sha256"
        return 1
    fi
}

cleanup_hetzner() {
    if ! hetzner_configured; then
        return 0
    fi

    log "Rydder gamle backups pa Hetzner StorageBox..."
    local cutoff_ts
    cutoff_ts=$(date -d "-${BACKUP_RETENTION_DAYS} days" +%Y%m%d 2>/dev/null || date -v-"${BACKUP_RETENTION_DAYS}"d +%Y%m%d 2>/dev/null || echo "")
    [[ -z "$cutoff_ts" ]] && { log "ADVARSEL: Klarte ikke beregne dato-cutoff for Hetzner cleanup — sjekk BACKUP_RETENTION_DAYS='${BACKUP_RETENTION_DAYS}'"; return 1; }

    local files_to_delete=()
    # shellcheck disable=SC2029 # lokal ekspansjon tilsiktet — verdier validert i check_requirements()
    while read -r remote_file; do
        if [[ ! "$remote_file" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            log "ADVARSEL: Avvist filnavn med ugyldige tegn: $remote_file"
            continue
        fi
        local file_date
        file_date=$(echo "$remote_file" | sed -n "s/.*${PROJECT_NAME}_\([0-9]\{8\}\).*/\1/p" || echo "")
        if [[ -n "$file_date" ]] && [[ "$file_date" < "$cutoff_ts" ]]; then
            log "Markerer for sletting: $remote_file"
            files_to_delete+=("${HETZNER_BACKUP_PATH}/${remote_file}")
        fi
    done < <(ssh "${SSH_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" ls "${HETZNER_BACKUP_PATH}" 2>/dev/null)

    if [[ ${#files_to_delete[@]} -gt 0 ]]; then
        log "Sletter ${#files_to_delete[@]} gammel(e) offsite backup(s)..."
        # shellcheck disable=SC2029 # lokal ekspansjon tilsiktet — verdier validert i check_requirements()
        ssh "${SSH_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" \
            rm "${files_to_delete[@]}" \
            || log "ADVARSEL: Sletting av gamle Hetzner-backups feilet — filer kan akkumulere"
    fi
}

run_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/${PROJECT_NAME}_${timestamp}.sql.gz.gpg"

    log "Starter backup..."

    local db_wait_attempts=0
    # pg_isready polles hvert 2. sekund, så maks forsøk = timeout / pollintervall
    local db_wait_max=$(( DB_WAIT_TIMEOUT / 2 ))
    until pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" > /dev/null 2>&1; do
        db_wait_attempts=$(( db_wait_attempts + 1 ))
        log "Venter pa database (forsok ${db_wait_attempts}/${db_wait_max})..."
        sleep 2
        if [[ $db_wait_attempts -ge $db_wait_max ]]; then
            error "Database ikke tilgjengelig etter ${DB_WAIT_TIMEOUT} sekunder (${db_wait_attempts} forsok)"
        fi
    done

    log "Krypterer backup med GPG (AES256)..."
    pg_dump \
        -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --no-owner --no-privileges --format=plain \
        | gzip \
        | gpg --batch --yes --symmetric --cipher-algo AES256 \
            --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        > "$backup_file"
    chmod 600 "$backup_file"

    # Verifiser at backup er gyldig (dekrypterings-test)
    if ! gpg --batch --yes --decrypt \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$backup_file" | gunzip -t > /dev/null 2>&1; then
        error "Backup-verifisering feilet! Kryptert fil kan ikke dekrypteres/dekomprimeres."
    fi

    local size
    size=$(du -h "$backup_file" | cut -f1)

    # Generer SHA256 checksum-fil
    sha256sum "$backup_file" > "${backup_file}.sha256"
    chmod 600 "${backup_file}.sha256"

    log "Backup lagret lokalt: $backup_file ($size)"

    # Last opp til Hetzner StorageBox (offsite) med retry
    upload_with_retry "$backup_file"
    # Last opp checksum-fil til Hetzner
    upload_with_retry "${backup_file}.sha256"

    # Slett lokale backups eldre enn BACKUP_RETENTION_DAYS
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_*.sql.gz.gpg" -mtime "+${BACKUP_RETENTION_DAYS}" -delete \
        || log "ADVARSEL: Fjerning av gamle lokale DB-backups feilet — sjekk rettigheter på $BACKUP_DIR"
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_*.sql.gz.gpg.sha256" -mtime "+${BACKUP_RETENTION_DAYS}" -delete \
        || log "ADVARSEL: Fjerning av gamle lokale checksum-filer feilet — sjekk rettigheter på $BACKUP_DIR"
    # Rydd opp eventuelle gamle ukrypterte backups
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_*.sql.gz" -not -name "*.gpg" -mtime "+${BACKUP_RETENTION_DAYS}" -delete \
        || log "ADVARSEL: Fjerning av gamle ukrypterte lokale backups feilet — sjekk rettigheter på $BACKUP_DIR"

    # Slett gamle backups pa Hetzner
    cleanup_hetzner

    log "Backup fullfort OK"
}

upload_with_retry() {
    local backup_file="$1"
    local max_retries="$BACKUP_RETRY_MAX"
    local retry_delay="$BACKUP_RETRY_DELAY"

    for attempt in $(seq 1 "$max_retries"); do
        upload_to_hetzner "$backup_file" && return 0
        if [[ $attempt -lt "$max_retries" ]]; then
            log "Hetzner-opplasting feilet (forsok $attempt/$max_retries). Prover igjen om ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        fi
    done
    log "ADVARSEL: Hetzner-opplasting feilet etter $max_retries forsok. Lokal backup er intakt."
}

backup_files() {
    if [[ -z "$FILES_DIR" ]] || [[ ! -d "$FILES_DIR" ]]; then
        return 0
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/${PROJECT_NAME}_files_${timestamp}.tar.gz.gpg"

    log "Starter fil-backup av ${FILES_DIR}..."

    tar czf - -C "$(dirname "$FILES_DIR")" "$(basename "$FILES_DIR")" \
        | gpg --batch --yes --symmetric --cipher-algo AES256 \
            --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        > "$backup_file"
    chmod 600 "$backup_file"

    # Verifiser at fil-backup er gyldig (dekrypterings-test)
    if ! gpg --batch --yes --decrypt \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$backup_file" | tar tzf - > /dev/null 2>&1; then
        error "Fil-backup-verifisering feilet! Kryptert arkiv kan ikke dekrypteres/pakkes ut."
    fi

    local size
    size=$(du -h "$backup_file" | cut -f1)

    # Generer SHA256 checksum-fil
    sha256sum "$backup_file" > "${backup_file}.sha256"
    chmod 600 "${backup_file}.sha256"

    log "Fil-backup lagret lokalt: $backup_file ($size)"

    # Last opp til Hetzner med retry
    upload_with_retry "$backup_file"
    # Last opp checksum-fil til Hetzner
    upload_with_retry "${backup_file}.sha256"

    # Rydd opp gamle fil-backups
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_files_*.tar.gz.gpg" -mtime "+${BACKUP_RETENTION_DAYS}" -delete \
        || log "ADVARSEL: Fjerning av gamle lokale fil-backups feilet — sjekk rettigheter på $BACKUP_DIR"
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_files_*.tar.gz.gpg.sha256" -mtime "+${BACKUP_RETENTION_DAYS}" -delete \
        || log "ADVARSEL: Fjerning av gamle lokale fil-backup checksum-filer feilet — sjekk rettigheter på $BACKUP_DIR"
    # Rydd opp eventuelle gamle ukrypterte fil-backups
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_files_*.tar.gz" -not -name "*.gpg" -mtime "+${BACKUP_RETENTION_DAYS}" -delete \
        || log "ADVARSEL: Fjerning av gamle ukrypterte lokale fil-backups feilet — sjekk rettigheter på $BACKUP_DIR"

    log "Fil-backup fullfort OK"
}

main() {
    log "=== Safekeeper Backup Service (${PROJECT_NAME}) ==="
    check_requirements
    setup_pgpass
    mkdir -p "$BACKUP_DIR"

    if [[ "${1:-}" == "backup" ]]; then
        run_backup
        backup_files
        date +%s > "$BACKUP_SUCCESS_FILE"
        exit 0
    fi

    log "Kjorer initial backup..."
    run_backup
    backup_files
    date +%s > "$BACKUP_SUCCESS_FILE"

    log "Setter opp daglig backup: $BACKUP_SCHEDULE"
    # Eksporter miljovariabler til fil for cron (BusyBox crond arver ikke Docker env)
    env | grep -E '^(PROJECT_NAME|DB_|BACKUP_|FILES_DIR|HETZNER_|TZ)[^=]*=' | sed "s/^\\([^=]*\\)=\\(.*\\)\$/export \\1='\\2'/" > "$SAFEKEEPER_ENV_FILE"
    chmod 600 "$SAFEKEEPER_ENV_FILE"
    echo "$BACKUP_SCHEDULE . $SAFEKEEPER_ENV_FILE; /usr/local/bin/backup-entrypoint.sh backup >> /var/log/backup.log 2>&1" > "$CRONTAB_FILE"

    log "Starter cron daemon..."
    exec crond -f -l 2
}

main "$@"
