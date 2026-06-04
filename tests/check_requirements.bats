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

@test "PROJECT_NAME med semikolon avvises" {
    export PROJECT_NAME="test;rm"
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"PROJECT_NAME"* ]]
}

@test "PROJECT_NAME med slash avvises" {
    export PROJECT_NAME="test/subdir"
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"PROJECT_NAME"* ]]
}

@test "PROJECT_NAME med gyldig navn aksepteres" {
    export PROJECT_NAME=mitt-prosjekt.v2
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]
    [[ "$output" != *"ugyldig"* ]]
}

@test "HETZNER_BACKUP_PATH med semikolon avvises nar Hetzner er konfigurert" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export HETZNER_HOST=hetzner.example.com
    export HETZNER_USER=u12345
    export HETZNER_BACKUP_PATH="backups/test;rm -rf /"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"HETZNER_BACKUP_PATH"* ]]
}

@test "HETZNER_BACKUP_PATH med path-traversal avvises" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export HETZNER_HOST=hetzner.example.com
    export HETZNER_USER=u12345
    export HETZNER_BACKUP_PATH="backups/../../../etc"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"HETZNER_BACKUP_PATH"* ]]
}

@test "HETZNER_BACKUP_PATH med gyldig sti aksepteres" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export HETZNER_HOST=hetzner.example.com
    export HETZNER_USER=u12345
    export HETZNER_BACKUP_PATH="backups/testprosjekt"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]
    [[ "$output" != *"HETZNER_BACKUP_PATH"* ]]
}

@test "HETZNER_BACKUP_PATH valideres ikke nar Hetzner ikke er konfigurert" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    unset HETZNER_HOST
    export HETZNER_BACKUP_PATH="backups/test;rm -rf /"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]
}

@test "HETZNER_HOST med spesialtegn avvises" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export HETZNER_HOST="hetzner.example.com;evil"
    export HETZNER_USER=u12345
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"HETZNER_HOST"* ]]
}

@test "HETZNER_PORT med ikke-numerisk verdi avvises" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export HETZNER_HOST=hetzner.example.com
    export HETZNER_USER=u12345
    export HETZNER_PORT="23 -o ProxyCommand=evil"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"HETZNER_PORT"* ]]
}

@test "backup feiler hvis HETZNER_HOST er satt men HETZNER_USER mangler" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export HETZNER_HOST=hetzner.example.com
    unset HETZNER_USER
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"HETZNER_USER"* ]]
}

@test "backup feiler hvis HETZNER_HOST er satt men HETZNER_USER er tom streng" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export HETZNER_HOST=hetzner.example.com
    export HETZNER_USER=""
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"HETZNER_USER"* ]]
}

@test "BACKUP_HEALTHCHECK_WINDOW ignoreres av entrypoint (eies av consumer docker-compose)" {
    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=nokkel
    export BACKUP_HEALTHCHECK_WINDOW="ikke-et-tall"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]
    [[ "$output" != *"BACKUP_HEALTHCHECK_WINDOW"* ]]
}

@test "pg_dump stub-versjon er synkronisert med Dockerfile baseimage (versjonsdrift-vakt)" {
    dockerfile_major=$(grep '^FROM postgres:' "$SAFEKEEPER_ROOT/Dockerfile" \
        | sed 's/FROM postgres:\([0-9]*\)\..*/\1/')
    [ -n "$dockerfile_major" ]
    run pg_dump --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ [[:space:]]${dockerfile_major}[.] ]]
}
