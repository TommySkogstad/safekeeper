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
    rm -f "${TMPDIR:-/tmp}/stub_gpg_encrypt_count_${BACKUP_DIR//\//_}"
}

# Laster backup-entrypoint.sh som bibliotek uten main og uten set -euo pipefail
# slik at enkeltfunksjoner kan kalles direkte. Brukes av Hetzner-relaterte tester.
load_backup_lib() {
    local stripped
    stripped=$(sed 's|^main "\$@".*$|:|; s|^set -euo pipefail.*$|:|; s|^trap cleanup EXIT.*$|:|' "$SAFEKEEPER_ROOT/backup-entrypoint.sh")
    eval "$stripped"
    echo "dummy-ssh-key" > "$SSH_KEY"
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
    [ ! -f "$BACKUP_SUCCESS_FILE" ]
}

@test "BACKUP_SUCCESS_FILE skrives ikke naar backup_files feiler (GPG-feil under fil-backup)" {
    local files_dir
    files_dir="$(mktemp -d)"
    touch "$files_dir/testfil.txt"
    export FILES_DIR="$files_dir"
    export STUB_GPG_FAIL_FILES=1

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]

    [ ! -f "$BACKUP_SUCCESS_FILE" ]

    rm -rf "$files_dir"
}

@test "run_backup feiler med feilmelding og forsoksteller naar database aldri starter (DB_WAIT_TIMEOUT)" {
    export STUB_PGISREADY_FAIL=always
    export DB_WAIT_TIMEOUT=4
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"ikke tilgjengelig"* ]]
    [[ "$output" == *"forsok"* ]]
}

@test "run_backup feiler med feilmelding naar pg_dump produserer tom output (STUB_PGDUMP_EMPTY=1)" {
    export STUB_PGDUMP_EMPTY=1
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -ne 0 ]
    [[ "$output" == *"liten"* ]]
    # Ingen backup-fil eller checksum skal vaere igjen
    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_*.sql.gz.gpg" | wc -l)
    [ "$files" -eq 0 ]
    [ ! -f "$BACKUP_SUCCESS_FILE" ]
}

@test "run_backup kaller pg_dump med --clean og --if-exists for idempotent restore" {
    local args_file
    args_file="$(mktemp)"
    export STUB_PGDUMP_ARGS_FILE="$args_file"

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    grep -qx -- '--clean' "$args_file"
    grep -qx -- '--if-exists' "$args_file"

    rm -f "$args_file"
}

@test "run_backup lykkes med SSH-fallback og logger ADVARSEL naar SFTP feiler men SSH virker (lokal backup ok)" {
    # SFTP-subsystem utilgjengelig (STUB_SFTP_FAIL=1), men SSH shell-kommandoer virker.
    # SSH mkdir fallback oppretter katalog; sftp put feiler; ingen scp-fallback.
    # Lokal backup er OK — run_backup fullforer selv om Hetzner-opplasting mislyktes.
    export HETZNER_HOST=hetzner.example
    export HETZNER_USER=u12345
    export STUB_SFTP_FAIL=1
    export BACKUP_RETRY_MAX=1
    load_backup_lib

    run run_backup
    [ "$status" -eq 0 ]
    # Forventer ADVARSEL om at Hetzner-opplasting feilet
    [[ "$output" == *"ADVARSEL"* ]]
    [[ "$output" == *"Opplasting til Hetzner feilet"* ]]

    local files
    files=$(find "$BACKUP_DIR" -maxdepth 1 -name "testprosjekt_*.sql.gz.gpg" | wc -l)
    [ "$files" -eq 1 ]
}
