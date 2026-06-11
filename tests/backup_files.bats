#!/usr/bin/env bats
#
# Tester for backup_files() happy-path i backup-entrypoint.sh.
# Verifiserer at fil-backup oppretter .tar.gz.gpg og .sha256 med chmod 600.
# Bruker stubs for pg_isready/pg_dump/gpg slik at testene kjorer uten
# ekte database eller GPG-nokkel.

load 'helpers/common'

# Laster backup-entrypoint.sh som bibliotek uten main/traps slik at
# backup_files() kan kalles direkte i tester som trenger isolasjon.
load_backup_lib() {
    local stripped
    stripped=$(sed 's|^main "\$@".*$|:|; s|^set -euo pipefail.*$|:|; s|^trap cleanup EXIT.*$|:|' "$SAFEKEEPER_ROOT/backup-entrypoint.sh")
    eval "$stripped"
    echo "dummy-ssh-key" > "$SSH_KEY"
}

setup() {
    setup_stubs
    BACKUP_DIR="$(mktemp -d)"
    BACKUP_SUCCESS_FILE="$(mktemp -u)"
    export BACKUP_DIR BACKUP_SUCCESS_FILE

    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=testnokkel123
    unset HETZNER_HOST HETZNER_USER
    unset STUB_GPG_FAIL STUB_GPG_FAIL_FILES STUB_PGDUMP_FAIL STUB_PGISREADY_FAIL

    FILES_DIR="$(mktemp -d)"
    echo "testinnhold" > "${FILES_DIR}/fil.txt"
    export FILES_DIR
}

teardown() {
    rm -rf "$BACKUP_DIR"
    rm -f "$BACKUP_SUCCESS_FILE"
    [[ -n "${FILES_DIR:-}" ]] && rm -rf "$FILES_DIR"
    rm -f "${TMPDIR:-/tmp}/stub_gpg_encrypt_count_${BACKUP_DIR//\//_}"
    rm -f "${TMPDIR:-/tmp}/stub_gpg_verify_count_${BACKUP_DIR//\//_}"
}

@test "backup_files oppretter kryptert .tar.gz.gpg-fil i BACKUP_DIR" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_files_*.tar.gz.gpg" | wc -l)
    [ "$files" -eq 1 ]
}

@test "backup_files genererer .sha256-checksum-fil" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local checksums
    checksums=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_files_*.tar.gz.gpg.sha256" | wc -l)
    [ "$checksums" -eq 1 ]
}

@test "backup_files-fil og checksum har chmod 600" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local backup_file
    backup_file=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_files_*.tar.gz.gpg" | head -1)
    [ -n "$backup_file" ]

    local perms
    perms=$(stat -c '%a' "$backup_file")
    [ "$perms" = "600" ]

    perms=$(stat -c '%a' "${backup_file}.sha256")
    [ "$perms" = "600" ]
}

@test "backup_files feiler ikke naar FILES_DIR ikke er satt (returnerer 0)" {
    unset FILES_DIR
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_files_*.tar.gz.gpg" | wc -l)
    [ "$files" -eq 0 ]
}

@test "backup_files feiler ikke naar FILES_DIR peker paa ikke-eksisterende katalog" {
    export FILES_DIR="/tmp/finnes-ikke-$(date +%s)"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_files_*.tar.gz.gpg" | wc -l)
    [ "$files" -eq 0 ]
}

@test "backup_files feiler hvis gpg kryptering feiler (STUB_GPG_FAIL_FILES=1)" {
    export STUB_GPG_FAIL_FILES=1
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]

    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_files_*.tar.gz.gpg.sha256" | wc -l)
    [ "$files" -eq 0 ]
    # Ingen tom/korrupt .tar.gz.gpg-fil skal ligge igjen etter pipeline-feil
    local gpg_files
    gpg_files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_files_*.tar.gz.gpg" | wc -l)
    [ "$gpg_files" -eq 0 ]
}

@test "backup_files fjerner .tar.gz.gpg-fil naar GPG-verifisering feiler (STUB_GPG_FAIL_VERIFY_FILES=1)" {
    export STUB_GPG_FAIL_VERIFY_FILES=1
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"verifisering feilet"* ]]

    # Korrupt .tar.gz.gpg-fil skal IKKE ligge igjen etter feilet verifisering
    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_files_*.tar.gz.gpg" | wc -l)
    [ "$files" -eq 0 ]
    [ ! -f "$BACKUP_SUCCESS_FILE" ]
}

@test "BACKUP_SUCCESS_FILE skrives ikke naar backup_files feiler (GPG-feil)" {
    export STUB_GPG_FAIL_FILES=1
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]

    [ ! -f "$BACKUP_SUCCESS_FILE" ]
}

@test "backup_files feiler naar fil-backup er mistenkelig liten (MIN_BACKUP_SIZE_BYTES=999999)" {
    load_backup_lib
    export MIN_BACKUP_SIZE_BYTES=999999
    run backup_files
    [ "$status" -ne 0 ]
    [[ "$output" == *"liten"* ]]

    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_files_*.tar.gz.gpg" | wc -l)
    [ "$files" -eq 0 ]
    [ ! -f "$BACKUP_SUCCESS_FILE" ]
}
