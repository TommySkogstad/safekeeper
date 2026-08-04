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
MIN_BACKUP_SIZE_BYTES="${MIN_BACKUP_SIZE_BYTES:-1024}"

# Interne fil-stier (kan overstyres i tester via env-variabler)
SAFEKEEPER_ENV_FILE="${SAFEKEEPER_ENV_FILE:-/etc/safekeeper.env}"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
BACKUP_LOCK_FILE="${BACKUP_LOCK_FILE:-/tmp/safekeeper-${PROJECT_NAME}.lock}"

# Fil-backup (valgfritt)
FILES_DIR="${FILES_DIR:-}"

# Hetzner StorageBox
HETZNER_HOST="${HETZNER_HOST:-}"
HETZNER_USER="${HETZNER_USER:-}"
HETZNER_PORT="${HETZNER_PORT:-23}"
HETZNER_BACKUP_PATH="${HETZNER_BACKUP_PATH:-backups/${PROJECT_NAME}}"
HETZNER_SFTP_CONNECT_TIMEOUT="${HETZNER_SFTP_CONNECT_TIMEOUT:-30}"
HETZNER_SSH_ALIVE_INTERVAL="${HETZNER_SSH_ALIVE_INTERVAL:-15}"
HETZNER_SSH_ALIVE_COUNT="${HETZNER_SSH_ALIVE_COUNT:-3}"

# ntfy-varsling (tom = deaktivert)
NTFY_URL="${NTFY_URL:-}"

# Valgfri overstyring av host-key for Hetzner StorageBox (known_hosts-format).
# Default (tom) verifiseres mot flaatenoklene bakt inn i /etc/ssh/ssh_known_hosts —
# Hetzner publiserer felles fingerprints for *.your-storagebox.de, og de er
# verifisert identiske med live keyscan av prod-boksen (#190, 2026-08-04).
# Sett kun denne ved avvikende boks/port; den overstyrer den innbakte fila helt.
HETZNER_HOST_KEY="${HETZNER_HOST_KEY:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

notify_ntfy() {
    [[ -z "${NTFY_URL:-}" ]] && return 0
    local message="$1"
    wget -q -O /dev/null \
        --post-data "BACKUP FEILET (${PROJECT_NAME:-ukjent}): ${message}" \
        --header "Title: Backup feilet: ${PROJECT_NAME:-ukjent}" \
        --header "Priority: urgent" \
        --header "Tags: rotating_light" \
        "${NTFY_URL}" 2>/dev/null || log "ADVARSEL: ntfy-varsling feilet (exit $?) — sjekk NTFY_URL og nettverkstilgang"
}

error() { log "ERROR: $1" >&2; notify_ntfy "$1"; exit 1; }

# SSH-nokkel via mktemp (ryddes opp via trap)
SSH_KEY=$(mktemp)
# Aktiv backup-fil for opprydding i cleanup-trap ved pipeline-feil
CURRENT_BACKUP_FILE=""
# Pinnet known_hosts-fil (satt evt. lenger ned, ryddes opp i cleanup-trap)
KNOWN_HOSTS_FILE=""

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
    [[ -n "${KNOWN_HOSTS_FILE:-}" ]] && rm -f "$KNOWN_HOSTS_FILE"
    [[ -n "${PGPASS_FILE:-}" ]] && rm -f "$PGPASS_FILE"
    # Fjern delvis skrevet backup-fil ved pipeline-feil (set -euo pipefail avbryter
    # midt i pipelinen og lar shell-omdirigeringen stå igjen som en tom/korrupt fil)
    if [[ -n "${CURRENT_BACKUP_FILE:-}" ]] && [[ -f "${CURRENT_BACKUP_FILE}" ]]; then
        rm -f "${CURRENT_BACKUP_FILE}" \
            || log "ADVARSEL: Klarte ikke slette korrupt backup-fil ${CURRENT_BACKUP_FILE} — sjekk rettigheter"
    fi
}
# Registreres FOR HETZNER_HOST_KEY-validering under, slik at en tidlig error()/exit
# (f.eks. ugyldig nokkelformat) fortsatt rydder opp SSH_KEY/KNOWN_HOSTS_FILE (#190 QA-funn).
trap cleanup EXIT

# Host-key-verifisering er alltid streng: default matcher de innbakte
# flaatenoklene i /etc/ssh/ssh_known_hosts (global known_hosts leses av ssh/sftp
# automatisk); HETZNER_HOST_KEY overstyrer med en enkelt pinnet linje (mktemp +
# cleanup-trap for konsistent hygiene sammen med SSH_KEY/PGPASS_FILE).
HOST_KEY_OPTS=(-o StrictHostKeyChecking=yes)
if [[ -n "$HETZNER_HOST_KEY" ]]; then
    KNOWN_HOSTS_FILE=$(mktemp)
    printf '%s\n' "$HETZNER_HOST_KEY" > "$KNOWN_HOSTS_FILE"
    chmod 600 "$KNOWN_HOSTS_FILE"
    HOST_KEY_FIRST_FIELD=$(awk '{print $1; exit}' "$KNOWN_HOSTS_FILE")
    [[ "$HOST_KEY_FIRST_FIELD" =~ ^(ssh-|ecdsa-|sk-) ]] \
        && error "HETZNER_HOST_KEY mangler vertsdel foran nokkel-typen (forventet format: '[host]:port ssh-ed25519 AAAA...', fikk nokkel-type forst: '${HOST_KEY_FIRST_FIELD}')"
    ssh-keygen -lf "$KNOWN_HOSTS_FILE" >/dev/null 2>&1 \
        || error "HETZNER_HOST_KEY er ikke en gyldig known_hosts-linje (forventet format: '[host]:port ssh-ed25519 AAAA...')"
    log "Hetzner host-key pinnet (StrictHostKeyChecking=yes): $(ssh-keygen -lf "$KNOWN_HOSTS_FILE" 2>/dev/null | tr '\n' ' ')"
    HOST_KEY_OPTS=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" -o GlobalKnownHostsFile=/dev/null)
elif [[ -n "$HETZNER_HOST" ]]; then
    log "Hetzner host-key verifiseres mot innbakte flaatenokler (/etc/ssh/ssh_known_hosts, StrictHostKeyChecking=yes) — sett HETZNER_HOST_KEY ved avvikende boks/port (#190)"
fi

# sftp bruker -P (stor bokstav) for port, -q for stille modus.
# ConnectTimeout/ServerAlive forhindrer at en hengt sftp-prosess arver LOCK_FD (flock)
# og blokkerer fremtidige cron-backups i dagevis (rotaarsak for hwa/styreportal-incident 2026-06-07).
SFTP_OPTS=(-q -i "${SSH_KEY}" "${HOST_KEY_OPTS[@]}" -o BatchMode=yes -P "${HETZNER_PORT}" -o ConnectTimeout="${HETZNER_SFTP_CONNECT_TIMEOUT}" -o ServerAliveInterval="${HETZNER_SSH_ALIVE_INTERVAL}" -o ServerAliveCountMax="${HETZNER_SSH_ALIVE_COUNT}")
# SSH_OPTS brukes for sha256sum-verifisering som fallback naar SFTP ls -la er utilgjengelig (ssh bruker -p i stedet for -P)
SSH_OPTS=(-i "${SSH_KEY}" "${HOST_KEY_OPTS[@]}" -o BatchMode=yes -p "${HETZNER_PORT}" -o ConnectTimeout="${HETZNER_SFTP_CONNECT_TIMEOUT}" -o ServerAliveInterval="${HETZNER_SSH_ALIVE_INTERVAL}" -o ServerAliveCountMax="${HETZNER_SSH_ALIVE_COUNT}")

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

    [[ "$BACKUP_RETRY_MAX" =~ ^[0-9]+$ ]] && [[ "$BACKUP_RETRY_MAX" -ge 1 ]] \
        || error "BACKUP_RETRY_MAX må være et positivt heltall >= 1, fikk: '$BACKUP_RETRY_MAX'"
    [[ "$BACKUP_RETRY_DELAY" =~ ^[0-9]+$ ]] && [[ "$BACKUP_RETRY_DELAY" -ge 1 ]] \
        || error "BACKUP_RETRY_DELAY må være et positivt heltall >= 1, fikk: '$BACKUP_RETRY_DELAY'"
    [[ "$MIN_BACKUP_SIZE_BYTES" =~ ^[0-9]+$ ]] && [[ "$MIN_BACKUP_SIZE_BYTES" -ge 1 ]] \
        || error "MIN_BACKUP_SIZE_BYTES må være et positivt heltall >= 1, fikk: '$MIN_BACKUP_SIZE_BYTES'"

    if [[ -n "$HETZNER_HOST" ]]; then
        [[ "$HETZNER_HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || error "HETZNER_HOST inneholder ugyldige tegn: '$HETZNER_HOST'"
        [[ -n "$HETZNER_USER" ]] || error "HETZNER_USER er påkrevd når HETZNER_HOST er satt"
        [[ "$HETZNER_USER" =~ ^[a-zA-Z0-9_-]+$ ]] || error "HETZNER_USER inneholder ugyldige tegn: '$HETZNER_USER'"
        [[ "$HETZNER_PORT" =~ ^[0-9]+$ ]] && [[ "$HETZNER_PORT" -ge 1 ]] && [[ "$HETZNER_PORT" -le 65535 ]] \
            || error "HETZNER_PORT er ugyldig: '$HETZNER_PORT'"
        [[ "$HETZNER_SFTP_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] && [[ "$HETZNER_SFTP_CONNECT_TIMEOUT" -ge 1 ]] \
            || error "HETZNER_SFTP_CONNECT_TIMEOUT må være et positivt heltall >= 1, fikk: '$HETZNER_SFTP_CONNECT_TIMEOUT'"
        [[ "$HETZNER_SSH_ALIVE_INTERVAL" =~ ^[0-9]+$ ]] && [[ "$HETZNER_SSH_ALIVE_INTERVAL" -ge 1 ]] \
            || error "HETZNER_SSH_ALIVE_INTERVAL må være et positivt heltall >= 1, fikk: '$HETZNER_SSH_ALIVE_INTERVAL'"
        [[ "$HETZNER_SSH_ALIVE_COUNT" =~ ^[0-9]+$ ]] && [[ "$HETZNER_SSH_ALIVE_COUNT" -ge 1 ]] \
            || error "HETZNER_SSH_ALIVE_COUNT må være et positivt heltall >= 1, fikk: '$HETZNER_SSH_ALIVE_COUNT'"
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

    # Opprett mapper hvis de ikke finnes (best-effort — ett nivå om gangen, Hetzner støtter ikke mkdir -p).
    # SSH-fallback brukes ikke: StorageBox restricted shell avviser SSH-kommandoer ("Command not found").
    # Feiler sftp mkdir+ls (f.eks. katalog finnes allerede, eller kontospesifikk SFTP-konfig),
    # logges det som advarsel og opplastingen fortsetter — sftp put avgjør om katalogen eksisterer.
    local path_parts
    IFS='/' read -ra path_parts <<< "${HETZNER_BACKUP_PATH}"
    local current_path=""
    for part in "${path_parts[@]}"; do
        [[ -z "$part" ]] && continue
        current_path="${current_path:+${current_path}/}${part}"
        if ! printf -- '-mkdir %s\nls %s\n' "${current_path}" "${current_path}" \
                | sftp "${SFTP_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" >/dev/null 2>&1; then
            log "ADVARSEL: SFTP mkdir '${current_path}' feilet — katalog finnes muligens allerede, fortsetter opplasting"
        fi
    done

    if ! printf 'put %s %s/%s\n' "$backup_file" "$HETZNER_BACKUP_PATH" "$filename" \
        | sftp "${SFTP_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}"; then
        log "ADVARSEL: Opplasting til Hetzner feilet - lokal backup er intakt"
        return 1
    fi

    # Verifiser opplastet fil: SFTP ls -la (størrelses-sjekk) primært,
    # SSH sha256sum som fallback når SFTP-subsystemet er utilgjengelig.
    local local_size remote_size
    local_size=$(wc -c < "$backup_file")
    remote_size=$(printf 'ls -la %s/%s\n' "${HETZNER_BACKUP_PATH}" "${filename}" \
        | sftp "${SFTP_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" 2>/dev/null \
        | awk 'NF >= 9 && /^[-dl]/ {print $5}' | grep -E '^[0-9]+$' | head -1 || echo "")

    if [[ -n "$remote_size" ]] && [[ "$remote_size" -eq "$local_size" ]]; then
        log "Offsite backup lastet opp og verifisert (${remote_size} bytes): ${HETZNER_BACKUP_PATH}/${filename}"
    elif [[ -n "$remote_size" ]]; then
        log "ADVARSEL: Størrelsesmismatch etter opplasting! Lokal=${local_size} Remote=${remote_size}"
        return 1
    else
        # SFTP ls -la feilet — prøv SSH sha256sum som fallback
        local local_sha256 remote_sha256
        local_sha256=$(sha256sum "$backup_file" | cut -d' ' -f1)
        # shellcheck disable=SC2029
        remote_sha256=$(ssh "${SSH_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" \
            sha256sum "${HETZNER_BACKUP_PATH}/${filename}" 2>/dev/null | cut -d' ' -f1 || echo "")
        if [[ -n "$remote_sha256" ]] && [[ "$remote_sha256" == "$local_sha256" ]]; then
            log "Offsite backup lastet opp og verifisert (sha256 via SSH): ${HETZNER_BACKUP_PATH}/${filename}"
        elif [[ -n "$remote_sha256" ]]; then
            log "ADVARSEL: Checksum-mismatch etter opplasting! Lokal=$local_sha256 Remote=$remote_sha256"
            return 1
        else
            # Verken SFTP eller SSH klarte å verifisere — stoler på at SFTP put exit 0 betyr vellykket opplasting
            log "ADVARSEL: Kunne ikke bekrefte opplastet fil på Hetzner (SFTP og SSH feilet) — SFTP put exit 0, antar vellykket"
        fi
    fi
}

cleanup_hetzner() {
    if ! hetzner_configured; then
        return 0
    fi

    log "Rydder gamle backups pa Hetzner StorageBox..."
    local cutoff_ts cutoff_epoch
    # BusyBox (Alpine) date stotter verken GNU "-d '-N days'" eller BSD "-v-Nd".
    # Beregn cutoff via epoke-aritmetikk og formater med "-d @EPOCH" (virker pa
    # bade BusyBox og GNU); BSD "-r" som fallback.
    cutoff_epoch=$(( $(date +%s) - BACKUP_RETENTION_DAYS * 86400 ))
    cutoff_ts=$(date -d "@${cutoff_epoch}" +%Y%m%d 2>/dev/null || date -r "${cutoff_epoch}" +%Y%m%d 2>/dev/null || echo "")
    [[ -z "$cutoff_ts" ]] && { log "ADVARSEL: Klarte ikke beregne dato-cutoff for Hetzner cleanup — sjekk BACKUP_RETENTION_DAYS='${BACKUP_RETENTION_DAYS}'"; return 1; }

    local files_to_delete=()
    while read -r remote_file; do
        # Noen SFTP-servere returnerer fulle stier (f.eks. "backups/hwa/fil.gpg") i ls-output.
        # Bruk basename for å validere og referere kun filnavnet, uavhengig av format.
        local filename
        filename=$(basename "$remote_file")
        if [[ ! "$filename" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            log "ADVARSEL: Avvist filnavn med ugyldige tegn: $filename"
            continue
        fi
        local file_date
        file_date=$(echo "$filename" | sed -n "s/.*${PROJECT_NAME}_\([0-9]\{8\}\).*/\1/p" || echo "")
        if [[ -n "$file_date" ]] && [[ "$file_date" < "$cutoff_ts" ]]; then
            log "Markerer for sletting: $filename"
            files_to_delete+=("${HETZNER_BACKUP_PATH}/${filename}")
        fi
    done < <(printf 'ls -la %s\n' "${HETZNER_BACKUP_PATH}" \
        | sftp "${SFTP_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" 2>/dev/null \
        | awk 'NF >= 9 && /^[-dl]/ && $NF !~ /^\.$|^\.\.$/ {print $NF}')

    if [[ ${#files_to_delete[@]} -gt 0 ]]; then
        log "Sletter ${#files_to_delete[@]} gammel(e) offsite backup(s)..."
        local sftp_rm_batch=""
        for f in "${files_to_delete[@]}"; do
            sftp_rm_batch+="rm ${f}"$'\n'
        done
        printf '%s' "$sftp_rm_batch" \
            | sftp "${SFTP_OPTS[@]}" "${HETZNER_USER}@${HETZNER_HOST}" >/dev/null 2>&1 \
            || log "ADVARSEL: Sletting av gamle Hetzner-backups feilet — filer kan akkumulere"
    fi
}

cleanup_local() {
    local ext="$1"
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_*.${ext}.gpg" -mtime "+${BACKUP_RETENTION_DAYS}" -delete \
        || log "ADVARSEL: Fjerning av gamle lokale ${ext}-backups feilet — sjekk rettigheter på $BACKUP_DIR"
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_*.${ext}.gpg.sha256" -mtime "+${BACKUP_RETENTION_DAYS}" -delete \
        || log "ADVARSEL: Fjerning av gamle lokale ${ext} checksum-filer feilet — sjekk rettigheter på $BACKUP_DIR"
    find "$BACKUP_DIR" -name "${PROJECT_NAME}_*.${ext}" -not -name "*.gpg" -mtime "+${BACKUP_RETENTION_DAYS}" -delete \
        || log "ADVARSEL: Fjerning av gamle ukrypterte lokale ${ext}-backups feilet — sjekk rettigheter på $BACKUP_DIR"
}

run_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/${PROJECT_NAME}_${timestamp}.sql.gz.gpg"
    CURRENT_BACKUP_FILE="$backup_file"

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
        --clean --if-exists \
        | gzip \
        | gpg --batch --yes --symmetric --cipher-algo AES256 \
            --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        > "$backup_file"
    chmod 600 "$backup_file"

    # Verifiser at backup-filen ikke er mistenkelig liten — tom output fra pg_dump
    # gir en gyldig (men verdilos) gzip-innpakket fil som passerer gunzip -t
    local actual_bytes
    actual_bytes=$(wc -c < "$backup_file")
    if [[ "$actual_bytes" -lt "$MIN_BACKUP_SIZE_BYTES" ]]; then
        rm -f "$backup_file"
        error "Backup-fil er mistenkelig liten (${actual_bytes} bytes < ${MIN_BACKUP_SIZE_BYTES} bytes) — pg_dump kan ha feilet"
    fi

    # Verifiser at backup er gyldig (dekrypterings-test)
    if ! gpg --batch --yes --decrypt \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$backup_file" | gunzip -t > /dev/null 2>&1; then
        rm -f "$backup_file"
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
    cleanup_local "sql.gz"

    # Slett gamle backups pa Hetzner (best-effort — opprydding ma ALDRI avbryte
    # backup-flyten eller hindre at cron-daemonen starter via set -e)
    cleanup_hetzner || log "ADVARSEL: Hetzner-opprydding feilet — fortsetter (lokal backup er intakt)"

    CURRENT_BACKUP_FILE=""
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
    CURRENT_BACKUP_FILE="$backup_file"

    log "Starter fil-backup av ${FILES_DIR}..."

    tar czf - -C "$(dirname "$FILES_DIR")" "$(basename "$FILES_DIR")" \
        | gpg --batch --yes --symmetric --cipher-algo AES256 \
            --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        > "$backup_file"
    chmod 600 "$backup_file"

    local actual_bytes
    actual_bytes=$(wc -c < "$backup_file")
    if [[ "$actual_bytes" -lt "$MIN_BACKUP_SIZE_BYTES" ]]; then
        rm -f "$backup_file"
        error "Fil-backup er mistenkelig liten (${actual_bytes} bytes < ${MIN_BACKUP_SIZE_BYTES} bytes) — tar kan ha feilet"
    fi

    # Verifiser at fil-backup er gyldig (dekrypterings-test)
    if ! gpg --batch --yes --decrypt \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$backup_file" | tar tzf - > /dev/null 2>&1; then
        rm -f "$backup_file"
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
    cleanup_local "tar.gz"

    CURRENT_BACKUP_FILE=""
    log "Fil-backup fullfort OK"
}

main() {
    log "=== Safekeeper Backup Service (${PROJECT_NAME}) ==="
    check_requirements
    setup_pgpass
    mkdir -p "$BACKUP_DIR"

    exec {LOCK_FD}>"$BACKUP_LOCK_FILE"
    if ! flock -xn "$LOCK_FD"; then
        log "ADVARSEL: En backup kjores allerede (${BACKUP_LOCK_FILE}) — avslutter"
        exit 0
    fi

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
    # Eksporter miljovariabler til fil for cron (BusyBox crond arver ikke Docker env).
    # printf '%q' håndterer enkle anførselstegn og andre spesialtegn i verdiene korrekt,
    # i motsetning til sed-basert enkelt-quote-wrapper som brytes ved ' i verdien.
    while IFS= read -r _sk_line; do
        _sk_key="${_sk_line%%=*}"
        _sk_val="${_sk_line#*=}"
        printf "export %s=%q\n" "$_sk_key" "$_sk_val"
    done < <(env | grep -E '^(PROJECT_NAME|DB_|BACKUP_|FILES_DIR|HETZNER_|NTFY_|TZ)[^=]*=') > "$SAFEKEEPER_ENV_FILE"
    chmod 600 "$SAFEKEEPER_ENV_FILE"
    echo "$BACKUP_SCHEDULE . $SAFEKEEPER_ENV_FILE; /usr/local/bin/backup-entrypoint.sh backup >> /var/log/backup.log 2>&1" > "$CRONTAB_FILE"

    # Frigir flock-låsen før exec crond — ellers arver crond fd-en og blokkerer alle fremtidige cron-kjøringer.
    exec {LOCK_FD}>&-

    log "Starter cron daemon..."
    exec crond -f -l 2
}

main "$@"
