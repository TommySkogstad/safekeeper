#!/usr/bin/env bats
#
# Tester for lås mot parallell backup-kjøring i backup-entrypoint.sh.

load 'helpers/common'

setup() {
    setup_stubs
    BACKUP_DIR="$(mktemp -d)"
    BACKUP_SUCCESS_FILE="$(mktemp -u)"
    BACKUP_LOCK_FILE="$(mktemp -u)"
    export BACKUP_DIR BACKUP_SUCCESS_FILE BACKUP_LOCK_FILE

    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=testnokkel123
    unset HETZNER_HOST HETZNER_USER FILES_DIR
    unset STUB_GPG_FAIL STUB_PGDUMP_FAIL STUB_PGISREADY_FAIL
}

teardown() {
    rm -rf "$BACKUP_DIR"
    rm -f "$BACKUP_SUCCESS_FILE"
    rm -f "$BACKUP_LOCK_FILE"
    rm -f "${TMPDIR:-/tmp}/stub_gpg_encrypt_count_${BACKUP_DIR//\//_}"
}

@test "backup hopper over og logger ADVARSEL naar en annen backup holder laas" {
    # Hold låsen manuelt — simulerer parallell kjøring
    exec {FD}>"$BACKUP_LOCK_FILE"
    flock -x "$FD"

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"kjores allerede"* ]] || [[ "$output" == *"kjøres allerede"* ]]

    # Ingen backup-fil skal opprettes når backup hoppes over
    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_*.sql.gz.gpg" 2>/dev/null | wc -l)
    [ "$files" -eq 0 ]

    flock -u "$FD"
    exec {FD}>&-
}

@test "backup kjorer normalt naar ingen annen backup holder laas" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_*.sql.gz.gpg" | wc -l)
    [ "$files" -eq 1 ]
}
