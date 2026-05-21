#!/usr/bin/env bats
#
# Tester for cleanup_hetzner() i backup-entrypoint.sh.
# Verifiserer at sletting av gamle Hetzner-backups gjøres med én SSH rm-kommando
# uansett antall filer (ikke N+1 SSH-tilkoblinger).

load 'helpers/common'

setup() {
    setup_stubs
    BACKUP_DIR="$(mktemp -d)"
    export BACKUP_DIR

    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=testnokkel
    export HETZNER_HOST=hetzner.example
    export HETZNER_USER=u12345
    export BACKUP_RETENTION_DAYS=30

    STUB_SSH_CALL_LOG="$(mktemp)"
    export STUB_SSH_CALL_LOG

    unset STUB_SCP_FAIL STUB_SSH_FAIL STUB_SSH_LS_OUTPUT
}

teardown() {
    rm -rf "$BACKUP_DIR"
    rm -f "${STUB_SSH_CALL_LOG:-}"
}

# Laster backup-entrypoint.sh som bibliotek uten main og uten set -euo pipefail
# (set -euo pipefail forstyrrer BATS sin feilhåndtering i testsuiten).
load_backup_lib() {
    local stripped
    # Strip set -euo pipefail og trap cleanup EXIT — begge forstyrrer BATS sin feilhåndtering.
    stripped=$(sed 's|^main "\$@".*$|:|; s|^set -euo pipefail.*$|:|; s|^trap cleanup EXIT.*$|:|' "$SAFEKEEPER_ROOT/backup-entrypoint.sh")
    eval "$stripped"
    echo "dummy-ssh-key" > "$SSH_KEY"
}

@test "cleanup_hetzner gjør maks 2 SSH-kall (ls + rm) for 3 gamle filer" {
    # Cutoff blir i dag - 30 dager; filer fra 2020 er garantert eldre
    export STUB_SSH_LS_OUTPUT="testprosjekt_20200101_030000.sql.gz.gpg
testprosjekt_20200102_030000.sql.gz.gpg
testprosjekt_20200103_030000.sql.gz.gpg"

    load_backup_lib
    run cleanup_hetzner

    local call_count
    call_count=$(wc -l < "$STUB_SSH_CALL_LOG")
    [[ "$call_count" -le 2 ]]
}

@test "cleanup_hetzner gjør ingen rm-kall hvis ingen filer er eldre enn cutoff" {
    # Filer fra fremtiden er garantert nyere enn cutoff
    local future_date
    future_date=$(date -d "+365 days" +%Y%m%d 2>/dev/null || date -v+365d +%Y%m%d 2>/dev/null || echo "20991231")
    export STUB_SSH_LS_OUTPUT="testprosjekt_${future_date}_030000.sql.gz.gpg"

    load_backup_lib
    run cleanup_hetzner

    # Kun ls-kallet forventes — ingen rm
    ! grep -q ' rm ' "$STUB_SSH_CALL_LOG" 2>/dev/null
}

@test "cleanup_hetzner gjør ingen SSH-kall når Hetzner ikke er konfigurert" {
    unset HETZNER_HOST

    load_backup_lib
    run cleanup_hetzner

    local call_count
    call_count=$(wc -l < "$STUB_SSH_CALL_LOG")
    [[ "$call_count" -eq 0 ]]
}

@test "cleanup_hetzner avviser filnavn med spesialtegn og logger advarsel" {
    export STUB_SSH_LS_OUTPUT="testprosjekt_20200101_030000.sql.gz.gpg
testprosjekt_20200102_030000.sql.gz.gpg;rm -rf /
testprosjekt_20200103_030000.sql.gz.gpg"

    load_backup_lib
    run cleanup_hetzner

    # Filen med semikolon skal ikke være med i rm-kommandoen
    ! grep -q 'rm.*rm -rf' "$STUB_SSH_CALL_LOG" 2>/dev/null
    # Advarsel skal være logget
    echo "$output" | grep -q "ADVARSEL"
}

@test "cleanup_hetzner logger advarsel naar SSH rm-kommando feiler" {
    export STUB_SSH_LS_OUTPUT="testprosjekt_20200101_030000.sql.gz.gpg"
    export STUB_SSH_RM_FAIL=1

    load_backup_lib
    run cleanup_hetzner

    [[ "$output" == *"ADVARSEL"* ]]
}

@test "cleanup_hetzner behandler gyldige filnavn normalt" {
    export STUB_SSH_LS_OUTPUT="testprosjekt_20200101_030000.sql.gz.gpg
testprosjekt_20200102_030000.sql.gz.gpg"

    load_backup_lib
    run cleanup_hetzner

    # Begge filer skal markeres for sletting (rm-kall skal forekomme)
    grep -q ' rm ' "$STUB_SSH_CALL_LOG" 2>/dev/null
}

@test "cleanup_hetzner sletter gammel fil — dato-ekstraksjon med POSIX sed (BusyBox-kompatibel)" {
    # grep -oP (Perl-regex) støttes ikke i BusyBox grep (postgres:16-alpine).
    # Verifiserer at dato-ekstraksjon fungerer og at filen inkluderes i rm-kommandoen.
    export STUB_SSH_LS_OUTPUT="testprosjekt_20200101_030000.sql.gz.gpg"

    load_backup_lib
    run cleanup_hetzner

    grep -q 'testprosjekt_20200101_030000.sql.gz.gpg' "$STUB_SSH_CALL_LOG"
}
