#!/usr/bin/env bats
#
# Tester for proaktiv ntfy-varsling ved backup-feil i backup-entrypoint.sh.
# Verifiserer at wget kalles med korrekt URL naar NTFY_URL er satt,
# og at ingen varsling sendes naar NTFY_URL er tom.

load 'helpers/common'

setup() {
    setup_stubs
    BACKUP_DIR="$(mktemp -d)"
    BACKUP_SUCCESS_FILE="$(mktemp -u)"
    WGET_CALL_LOG="$(mktemp)"
    export BACKUP_DIR BACKUP_SUCCESS_FILE WGET_CALL_LOG

    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=testnokkel123
    unset HETZNER_HOST HETZNER_USER FILES_DIR
    unset STUB_WGET_FAIL
}

teardown() {
    rm -rf "$BACKUP_DIR"
    rm -f "$BACKUP_SUCCESS_FILE"
    rm -f "$WGET_CALL_LOG"
}

@test "backup-feil med NTFY_URL satt sender wget-kall til ntfy-URL" {
    export NTFY_URL="http://ntfy.test/safekeeper"
    export STUB_PGISREADY_FAIL=always
    export DB_WAIT_TIMEOUT=4

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]

    [ -s "$WGET_CALL_LOG" ]
    [[ "$(cat "$WGET_CALL_LOG")" == *"http://ntfy.test/safekeeper"* ]]
}

@test "backup-feil uten NTFY_URL sender ingen wget-varsling" {
    unset NTFY_URL
    export STUB_PGISREADY_FAIL=always
    export DB_WAIT_TIMEOUT=4

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]

    [ ! -s "$WGET_CALL_LOG" ]
}

@test "backup-feil med NTFY_URL tom streng sender ingen wget-varsling" {
    export NTFY_URL=""
    export STUB_PGISREADY_FAIL=always
    export DB_WAIT_TIMEOUT=4

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]

    [ ! -s "$WGET_CALL_LOG" ]
}

@test "ntfy-varsling inkluderer PROJECT_NAME i Title-header" {
    export NTFY_URL="http://ntfy.test/safekeeper"
    export STUB_PGISREADY_FAIL=always
    export DB_WAIT_TIMEOUT=4

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]

    [[ "$(cat "$WGET_CALL_LOG")" == *"testprosjekt"* ]]
}

@test "ntfy-varsling feiler stille — backup-feil-exit er fortsatt 1 (STUB_WGET_FAIL=1)" {
    export NTFY_URL="http://ntfy.test/safekeeper"
    export STUB_WGET_FAIL=1
    export STUB_PGISREADY_FAIL=always
    export DB_WAIT_TIMEOUT=4

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
}
