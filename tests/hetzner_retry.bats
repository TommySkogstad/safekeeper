#!/usr/bin/env bats
#
# Tester for upload_with_retry i backup-entrypoint.sh.
# Verifiserer at opplasting forsoeker 3 ganger ved vedvarende scp-feil
# og logger korrekt feilmelding naar alle forsoek slar feil.
#
# backup-entrypoint.sh sources som bibliotek (main-kallet strippes bort)
# slik at upload_with_retry kan kalles direkte uten aa kjore en full
# backup-flyt.

load 'helpers/common'

setup() {
    setup_stubs
    BACKUP_DIR="$(mktemp -d)"
    export BACKUP_DIR

    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=testnokkel
    export HETZNER_HOST=hetzner.example
    export HETZNER_USER=u12345

    unset STUB_SCP_FAIL STUB_SSH_FAIL
}

teardown() {
    rm -rf "$BACKUP_DIR"
}

# Laster backup-entrypoint.sh som bibliotek uten aa kjore main.
# Populerer deretter SSH_KEY saa hetzner_configured returnerer sant.
load_backup_lib() {
    local stripped
    stripped=$(sed 's|^main "\$@".*$|:|' "$SAFEKEEPER_ROOT/backup-entrypoint.sh")
    eval "$stripped"
    echo "dummy-ssh-key" > "$SSH_KEY"
}

@test "upload_with_retry prover 3 ganger ved vedvarende scp-feil" {
    export STUB_SCP_FAIL=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"forsok 1/3"* ]]
    [[ "$output" == *"forsok 2/3"* ]]
}

@test "upload_with_retry logger 'etter 3 forsok' ved total feil" {
    export STUB_SCP_FAIL=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"Hetzner-opplasting feilet etter 3 forsok"* ]]
}

@test "upload_with_retry prover pa nytt ved checksum-mismatch etter opplasting" {
    export STUB_SSH_WRONG_CHECKSUM=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"Checksum-mismatch"* ]]
    [[ "$output" == *"forsok 1/3"* ]]
    [[ "$output" == *"forsok 2/3"* ]]
}

@test "upload_to_hetzner logger advarsel og returnerer 0 ved tom sha256sum-respons" {
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Kunne ikke verifisere checksum"* ]]
}
