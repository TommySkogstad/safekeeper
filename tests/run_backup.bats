#!/usr/bin/env bats
#
# Tester for run_backup happy path i backup-entrypoint.sh.
# Bruker stubs for pg_isready/pg_dump/gpg slik at testene kjorer uten
# ekte database eller GPG-nokkel.

load 'helpers/common'

setup() {
    setup_stubs
    BACKUP_DIR="$(mktemp -d)"
    BACKUP_SUCCESS_FILE="$(mktemp -u)"
    export BACKUP_DIR BACKUP_SUCCESS_FILE

    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=testnokkel123
    unset HETZNER_HOST HETZNER_USER FILES_DIR
    unset STUB_GPG_FAIL STUB_PGDUMP_FAIL STUB_PGISREADY_FAIL
}

teardown() {
    rm -rf "$BACKUP_DIR"
    rm -f "$BACKUP_SUCCESS_FILE"
}

@test "run_backup oppretter kryptert backup-fil i BACKUP_DIR" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_*.sql.gz.gpg" | wc -l)
    [ "$files" -eq 1 ]
}

@test "run_backup genererer .sha256-checksum-fil" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local checksums
    checksums=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_*.sql.gz.gpg.sha256" | wc -l)
    [ "$checksums" -eq 1 ]
}

@test "run_backup skriver timestamp til BACKUP_SUCCESS_FILE" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    [ -f "$BACKUP_SUCCESS_FILE" ]
    local ts
    ts=$(cat "$BACKUP_SUCCESS_FILE")
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "backup-fil og checksum har chmod 600" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local backup_file
    backup_file=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_*.sql.gz.gpg" | head -1)
    [ -n "$backup_file" ]

    local perms
    perms=$(stat -c '%a' "$backup_file")
    [ "$perms" = "600" ]

    perms=$(stat -c '%a' "${backup_file}.sha256")
    [ "$perms" = "600" ]
}

@test "run_backup feiler hvis gpg-kryptering feiler (STUB_GPG_FAIL=1)" {
    export STUB_GPG_FAIL=1
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]

    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_*.sql.gz.gpg.sha256" | wc -l)
    [ "$files" -eq 0 ]
}
