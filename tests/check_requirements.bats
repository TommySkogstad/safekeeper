#!/usr/bin/env bats
#
# Tester for miljovariabel-validering i backup-entrypoint.sh.
# Verifiserer at skriptet feiler raskt ved manglende paakrevde variabler.

load 'helpers/common'

setup() {
    setup_stubs
    unset PROJECT_NAME DB_PASSWORD BACKUP_ENCRYPTION_KEY
    BACKUP_DIR="$(mktemp -d)"
    BACKUP_SUCCESS_FILE="$(mktemp -u)"
    export BACKUP_DIR BACKUP_SUCCESS_FILE
}

teardown() {
    rm -rf "$BACKUP_DIR"
    rm -f "$BACKUP_SUCCESS_FILE"
    rm -f "${TMPDIR:-/tmp}/stub_gpg_encrypt_count_${BACKUP_DIR//\//_}"
}

@test "backup feiler hvis PROJECT_NAME mangler" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"PROJECT_NAME"* ]]
}

@test "backup feiler hvis DB_PASSWORD mangler" {
    export PROJECT_NAME=testprosjekt
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"DB_PASSWORD"* ]]
}

@test "backup feiler hvis BACKUP_ENCRYPTION_KEY mangler" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"BACKUP_ENCRYPTION_KEY"* ]]
}

@test "backup feiler hvis BACKUP_ENCRYPTION_KEY er tom streng" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=""
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"BACKUP_ENCRYPTION_KEY"* ]]
}

@test "check_requirements feiler hvis BACKUP_SCHEDULE har feil antall felt" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export BACKUP_SCHEDULE="every day at 3"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"BACKUP_SCHEDULE"* ]]
}

@test "check_requirements aksepterer gyldig cron-uttrykk (5 felt)" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export BACKUP_SCHEDULE="0 3 * * *"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]
    [[ "$output" != *"BACKUP_SCHEDULE har feil"* ]]
}
