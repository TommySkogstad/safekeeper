#!/usr/bin/env bats
#
# Tester for retention-logikk i run_backup() i backup-entrypoint.sh.
# Verifiserer at find -mtime +N -delete sletter riktige filer og beholder andre.
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
    export BACKUP_RETENTION_DAYS=1
    unset HETZNER_HOST HETZNER_USER FILES_DIR
    unset STUB_GPG_FAIL STUB_PGDUMP_FAIL STUB_PGISREADY_FAIL
}

teardown() {
    rm -rf "$BACKUP_DIR"
    rm -f "$BACKUP_SUCCESS_FILE"
}

@test "retention sletter backup-filer eldre enn BACKUP_RETENTION_DAYS" {
    local old_file="${BACKUP_DIR}/testprosjekt_20240101_030000.sql.gz.gpg"
    touch -d "3 days ago" "$old_file"

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    [ ! -f "$old_file" ]
}

@test "retention beholder backup-filer yngre enn BACKUP_RETENTION_DAYS" {
    local new_file="${BACKUP_DIR}/testprosjekt_$(date +%Y%m%d)_000000.sql.gz.gpg"
    touch "$new_file"

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    [ -f "$new_file" ]
}

@test "retention sletter .sha256-fil tilhorende gammel backup" {
    local old_backup="${BACKUP_DIR}/testprosjekt_20240101_030000.sql.gz.gpg"
    local old_checksum="${old_backup}.sha256"
    touch -d "3 days ago" "$old_backup" "$old_checksum"

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    [ ! -f "$old_backup" ]
    [ ! -f "$old_checksum" ]
}

@test "retention gir ingen feil med tom backup-katalog" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]
}

@test "retention roerer ikke filer fra andre prosjekter" {
    local other_file="${BACKUP_DIR}/annetprosjekt_20240101_030000.sql.gz.gpg"
    touch -d "3 days ago" "$other_file"

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    [ -f "$other_file" ]
}
