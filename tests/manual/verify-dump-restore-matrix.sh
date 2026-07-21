#!/bin/bash
#
# Manuell verifisering av dump/restore-matrise (safekeeper #171 / #133):
# safekeeper-imagets pg_dump/psql (klient v18) mot postgres:16-alpine og
# postgres:17-alpine som SERVERE. Bruker samme flagg/flyt som
# backup-entrypoint.sh og restore.sh.
#
# Kjøres KUN manuelt — IKKE del av BATS-suiten (bats tests/ / tests/run.sh
# matcher kun *.bats og plukker aldri opp dette skriptet).
#
# Bruk:
#   ./tests/manual/verify-dump-restore-matrix.sh
#
# Krever Docker. Bygger safekeeper-imaget fra repo-roten hvis SAFEKEEPER_IMAGE
# ikke allerede finnes lokalt.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SAFEKEEPER_IMAGE="${SAFEKEEPER_IMAGE:-safekeeper-matrix-test:local}"
RUN_ID="$$_${RANDOM}"
NETWORK="safekeeper-matrix-${RUN_ID}"
WORKDIR="$(mktemp -d)"

DB_NAME="matrixdb"
DB_USER="matrixuser"
DB_PASSWORD="matrixpass"

CLEANUP_CONTAINERS=()

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# shellcheck disable=SC2317,SC2329  # kun kalt via 'trap cleanup EXIT' — shellcheck feiltolker dette som ubrukt naar skriptet avsluttes med en eksplisitt 'exit'-linje (funnene varierer mellom shellcheck-versjoner)
cleanup() {
    log "Rydder opp midlertidige containere og nettverk..."
    if [[ ${#CLEANUP_CONTAINERS[@]} -gt 0 ]]; then
        docker rm -f "${CLEANUP_CONTAINERS[@]}" >/dev/null 2>&1 || true
    fi
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker er ikke tilgjengelig i dette miljøet — hopper over matrise-verifisering."
    exit 0
fi

if ! docker image inspect "$SAFEKEEPER_IMAGE" >/dev/null 2>&1; then
    log "Bygger safekeeper-image ($SAFEKEEPER_IMAGE) fra $REPO_ROOT..."
    docker build -t "$SAFEKEEPER_IMAGE" "$REPO_ROOT" || { log "FEIL: klarte ikke bygge safekeeper-imaget"; exit 1; }
fi

docker network create "$NETWORK" >/dev/null || { log "FEIL: klarte ikke opprette Docker-nettverk"; exit 1; }

wait_for_pg() {
    local container="$1"
    local attempts=0
    local max_attempts=30
    until docker exec "$container" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge $max_attempts ]]; then
            log "FEIL: $container ble ikke klar innen tidsfrist"
            return 1
        fi
        sleep 2
    done
}

seed_data() {
    local container="$1"
    docker exec -i "$container" psql -U "$DB_USER" -d "$DB_NAME" <<'SQL'
CREATE TABLE kunder (
    id BIGSERIAL PRIMARY KEY,
    navn TEXT NOT NULL,
    notat TEXT
);

CREATE SEQUENCE ordre_nr_seq START 1000;

CREATE TABLE ordre (
    id BIGINT PRIMARY KEY DEFAULT nextval('ordre_nr_seq'),
    kunde_id BIGINT REFERENCES kunder(id),
    stor_tekst TEXT
);

INSERT INTO kunder (navn, notat)
SELECT 'Kunde ' || i, 'Notat for kunde ' || i
FROM generate_series(1, 500) AS i;

INSERT INTO ordre (kunde_id, stor_tekst)
SELECT (i % 500) + 1, repeat('x', 10000) || i::text
FROM generate_series(1, 200) AS i;

SELECT setval('ordre_nr_seq', (SELECT max(id) FROM ordre) + 1);
SQL
}

# Skriver ut "kunder_count|ordre_count|innhold_md5|sekvens_siste_verdi" for sammenligning.
# Bruker pg_sequences.last_value (IKKE nextval()) for å lese sekvensen uten å mutere den —
# nextval() ville forbrukt én verdi ved hver kontroll og gitt falske mismatch mellom kilde og mål.
snapshot_data() {
    local container="$1"
    local kunder_count ordre_count checksum seq_last_value
    kunder_count=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM kunder;") || return 1
    ordre_count=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM ordre;") || return 1
    checksum=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT md5(string_agg(stor_tekst, '' ORDER BY id)) FROM ordre;") || return 1
    seq_last_value=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT last_value FROM pg_sequences WHERE schemaname = 'public' AND sequencename = 'ordre_nr_seq';") || return 1
    echo "${kunder_count}|${ordre_count}|${checksum}|${seq_last_value}"
}

run_matrix_for_version() {
    local pg_version="$1"
    local suffix="${pg_version//./-}-${RUN_ID}"
    local source_container="safekeeper-matrix-src-${suffix}"
    local target_container="safekeeper-matrix-tgt-${suffix}"
    local dump_file="${WORKDIR}/dump-${pg_version}.sql"

    log "=== Matrise: postgres:${pg_version} (server) mot safekeeper pg-klient 18 ==="

    log "Henter postgres:${pg_version}..."
    docker pull "postgres:${pg_version}" >/dev/null || { log "FEIL: klarte ikke hente postgres:${pg_version}"; return 1; }

    log "Starter kilde-container ($source_container)..."
    docker run -d --name "$source_container" --network "$NETWORK" \
        -e POSTGRES_DB="$DB_NAME" -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        "postgres:${pg_version}" >/dev/null || { log "FEIL: klarte ikke starte $source_container"; return 1; }
    CLEANUP_CONTAINERS+=("$source_container")
    wait_for_pg "$source_container" || return 1

    log "Populerer testdata (kunder, ordre m/stor tekstkolonne, sekvens)..."
    seed_data "$source_container" || { log "FEIL: seeding av testdata feilet"; return 1; }

    local expected
    expected=$(snapshot_data "$source_container") || { log "FEIL: klarte ikke lese kildedata"; return 1; }
    log "Kildedata: kunder=$(cut -d'|' -f1 <<<"$expected") ordre=$(cut -d'|' -f2 <<<"$expected")"

    log "Dumper med safekeeper-imagets pg_dump (klient 18) — samme flagg som backup-entrypoint.sh..."
    docker run --rm --network "$NETWORK" \
        -e PGPASSWORD="$DB_PASSWORD" \
        --entrypoint pg_dump \
        "$SAFEKEEPER_IMAGE" \
        -h "$source_container" -U "$DB_USER" -d "$DB_NAME" \
        --no-owner --no-privileges --format=plain --clean --if-exists \
        > "$dump_file" || { log "FEIL: pg_dump feilet mot postgres:${pg_version}"; return 1; }

    log "Starter target-container ($target_container) for restore..."
    docker run -d --name "$target_container" --network "$NETWORK" \
        -e POSTGRES_DB="$DB_NAME" -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        "postgres:${pg_version}" >/dev/null || { log "FEIL: klarte ikke starte $target_container"; return 1; }
    CLEANUP_CONTAINERS+=("$target_container")
    wait_for_pg "$target_container" || return 1

    log "Gjenoppretter med safekeeper-imagets psql --single-transaction (klient 18) — samme flyt som restore.sh, inkludert transaction_timeout-filteret fra #174..."
    sed '/^SET transaction_timeout/d' "$dump_file" \
        | docker run --rm -i --network "$NETWORK" \
        -e PGPASSWORD="$DB_PASSWORD" \
        --entrypoint psql \
        "$SAFEKEEPER_IMAGE" \
        --single-transaction -h "$target_container" -U "$DB_USER" -d "$DB_NAME" \
        >/dev/null || { log "FEIL: restore feilet mot postgres:${pg_version}"; return 1; }

    local actual
    actual=$(snapshot_data "$target_container") || { log "FEIL: klarte ikke lese gjenopprettet data"; return 1; }

    if [[ "$expected" == "$actual" ]]; then
        log "OK: postgres:${pg_version} — data intakt etter dump/restore (kunder=$(cut -d'|' -f1 <<<"$actual"), ordre=$(cut -d'|' -f2 <<<"$actual"), sekvens_siste_verdi=$(cut -d'|' -f4 <<<"$actual"))"
        return 0
    else
        log "FEIL: postgres:${pg_version} — data-mismatch! Forventet=${expected} Faktisk=${actual}"
        return 1
    fi
}

overall_status=0
for version in "16-alpine" "17-alpine"; do
    if ! run_matrix_for_version "$version"; then
        overall_status=1
    fi
    echo
done

if [[ $overall_status -eq 0 ]]; then
    log "Alle matrise-scenarier OK: pg-klient 18 dumper/restorer korrekt mot postgres:16-alpine og postgres:17-alpine."
else
    log "Ett eller flere matrise-scenarier FEILET — se output over. IKKE nedgrader baseimage for å fikse dette; rapporter funnet i #133."
fi

exit $overall_status
