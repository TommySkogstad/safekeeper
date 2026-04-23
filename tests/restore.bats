#!/usr/bin/env bats
#
# Tester for restore.sh.
# Dekker checksum-verifisering og krav om BACKUP_ENCRYPTION_KEY
# for .gpg-filer. Bruker psql-stub for aa unngaa ekte database.

load 'helpers/common'

setup() {
    setup_stubs
    BACKUP_DIR="$(mktemp -d)"
    export BACKUP_DIR

    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    unset BACKUP_ENCRYPTION_KEY
}

teardown() {
    rm -rf "$BACKUP_DIR"
}

@test "restore.sh feiler hvis backup-fil ikke finnes" {
    export BACKUP_ENCRYPTION_KEY=testnokkel
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$BACKUP_DIR/finnes-ikke.sql.gz.gpg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Backup-fil finnes ikke"* ]]
}

@test "restore.sh feiler hvis BACKUP_ENCRYPTION_KEY mangler for .gpg-fil" {
    local backup_file="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "dummy kryptert innhold" > "$backup_file"

    unset BACKUP_ENCRYPTION_KEY
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"BACKUP_ENCRYPTION_KEY"* ]]
}

@test "restore.sh feiler ved checksum-mismatch" {
    export BACKUP_ENCRYPTION_KEY=testnokkel
    local backup_file="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "faktisk innhold" > "$backup_file"
    # Skriv en feil checksum til .sha256-filen
    echo "0000000000000000000000000000000000000000000000000000000000000000  $backup_file" \
        > "${backup_file}.sha256"

    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Checksum-verifisering feilet"* ]]
}
