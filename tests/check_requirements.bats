#!/usr/bin/env bats
#
# Tester for miljovariabel-validering i backup-entrypoint.sh.
# Verifiserer at skriptet feiler raskt ved manglende paakrevde variabler.

load 'helpers/common'

setup() {
    unset PROJECT_NAME DB_PASSWORD BACKUP_ENCRYPTION_KEY
    BACKUP_DIR="$(mktemp -d)"
    export BACKUP_DIR
}

teardown() {
    rm -rf "$BACKUP_DIR"
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
