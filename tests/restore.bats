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

@test "restore.sh feiler hvis DB_PASSWORD mangler for database-gjenoppretting" {
    export BACKUP_ENCRYPTION_KEY=testnokkel
    local backup_file="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "dummy" > "$backup_file"
    unset DB_PASSWORD
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"DB_PASSWORD"* ]]
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

# --- Fil-backup (.tar.gz.gpg) ---

@test "--list-files viser tilgjengelige fil-backups" {
    touch "$BACKUP_DIR/testprosjekt_files_20260101_120000.tar.gz.gpg"
    run bash "$SAFEKEEPER_ROOT/restore.sh" --list-files
    [ "$status" -eq 0 ]
    [[ "$output" == *"testprosjekt_files_20260101_120000.tar.gz.gpg"* ]]
}

@test "--list-files melder ingen backups hvis ingen finnes" {
    run bash "$SAFEKEEPER_ROOT/restore.sh" --list-files
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ingen fil-backups funnet"* ]]
}

@test "restore.sh feiler hvis fil-backup ikke finnes" {
    export BACKUP_ENCRYPTION_KEY=testnokkel
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$BACKUP_DIR/finnes-ikke.tar.gz.gpg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Backup-fil finnes ikke"* ]]
}

@test "restore.sh feiler hvis BACKUP_ENCRYPTION_KEY mangler for .tar.gz.gpg" {
    local backup_file="$BACKUP_DIR/testprosjekt_files_20260101_120000.tar.gz.gpg"
    echo "dummy" > "$backup_file"
    unset BACKUP_ENCRYPTION_KEY
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"BACKUP_ENCRYPTION_KEY"* ]]
}

@test "restore.sh feiler ved checksum-mismatch for fil-backup" {
    export BACKUP_ENCRYPTION_KEY=testnokkel
    local backup_file="$BACKUP_DIR/testprosjekt_files_20260101_120000.tar.gz.gpg"
    echo "faktisk innhold" > "$backup_file"
    echo "0000000000000000000000000000000000000000000000000000000000000000  $backup_file" \
        > "${backup_file}.sha256"
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Checksum-verifisering feilet"* ]]
}

@test "restore.sh feiler hvis maalmappe ikke finnes" {
    export BACKUP_ENCRYPTION_KEY=testnokkel
    local backup_file="$BACKUP_DIR/testprosjekt_files_20260101_120000.tar.gz.gpg"
    echo "dummy" > "$backup_file"
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file" "/finnes/ikke/2026"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Maalmappe finnes ikke"* ]]
}

@test "restore_wrong_password_test" {
    export BACKUP_ENCRYPTION_KEY=testnokkel
    local backup_file="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    # Gyldig gzip-innhold slik at gunzip passerer og psql naas i pipelinen
    printf 'SELECT 1;\n' | gzip > "$backup_file"

    STUB_PSQL_FAIL=1 run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file"
    [ "$status" -ne 0 ]
    [[ "$output" != *"Gjenoppretting fullfort!"* ]]
}

# --- Database happy-path ---

@test "restore.sh gjenoppretter .sql.gz.gpg (dekrypter → gunzip → psql OK)" {
    export BACKUP_ENCRYPTION_KEY=testnokkel
    local backup_file="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    # gpg-stub er passthrough, så filen må inneholde ekte gzip-data
    printf 'SELECT 1;\n' | gzip > "$backup_file"
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Gjenoppretting fullfort!"* ]]
}

@test "restore.sh gjenoppretter .sql.gz (gunzip → psql OK)" {
    local backup_file="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz"
    printf 'SELECT 1;\n' | gzip > "$backup_file"
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Gjenoppretting fullfort!"* ]]
}

@test "restore.sh gjenoppretter plain .sql (psql OK)" {
    local backup_file="$BACKUP_DIR/testprosjekt_20260101_120000.sql"
    printf 'SELECT 1;\n' > "$backup_file"
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Gjenoppretting fullfort!"* ]]
}

@test "restore.sh gjenoppretter fil-backup til maalmappe" {
    export BACKUP_ENCRYPTION_KEY=testnokkel
    local target_dir
    target_dir=$(mktemp -d)
    local src_dir
    src_dir=$(mktemp -d)
    echo "testinnhold" > "$src_dir/testfil.txt"
    local backup_file="$BACKUP_DIR/testprosjekt_files_20260101_120000.tar.gz.gpg"
    # gpg-stubben passerer gjennom, så vi lager en ekte tar.gz
    tar czf "$backup_file" -C "$(dirname "$src_dir")" "$(basename "$src_dir")"
    run bash "$SAFEKEEPER_ROOT/restore.sh" "$backup_file" "$target_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Fil-gjenoppretting fullfort"* ]]
    rm -rf "$src_dir" "$target_dir"
}
