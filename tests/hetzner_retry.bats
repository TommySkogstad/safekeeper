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

    unset STUB_SCP_FAIL STUB_SSH_FAIL STUB_SFTP_FAIL STUB_SFTP_WRONG_SIZE STUB_SFTP_LS_SIZE
}

teardown() {
    rm -rf "$BACKUP_DIR"
}

# Laster backup-entrypoint.sh som bibliotek uten main og uten set -euo pipefail
# (set -euo pipefail forstyrrer BATS sin feilhåndtering i testsuiten).
load_backup_lib() {
    local stripped
    stripped=$(sed 's|^main "\$@".*$|:|; s|^set -euo pipefail.*$|:|; s|^trap cleanup EXIT.*$|:|' "$SAFEKEEPER_ROOT/backup-entrypoint.sh")
    eval "$stripped"
    echo "dummy-ssh-key" > "$SSH_KEY"
}

@test "upload_with_retry prover 3 ganger ved vedvarende scp-feil" {
    export STUB_SCP_FAIL=1
    export BACKUP_RETRY_MAX=3
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"forsok 1/3"* ]]
    [[ "$output" == *"forsok 2/3"* ]]
}

@test "upload_with_retry logger 'etter 3 forsok' ved total feil" {
    export STUB_SCP_FAIL=1
    export BACKUP_RETRY_MAX=3
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"Hetzner-opplasting feilet etter 3 forsok"* ]]
}

@test "upload_with_retry prover pa nytt ved stoerrelses-mismatch etter opplasting" {
    export STUB_SFTP_WRONG_SIZE=1
    export BACKUP_RETRY_MAX=3
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"Størrelsesmismatch"* ]]
    [[ "$output" == *"forsok 1/3"* ]]
    [[ "$output" == *"forsok 2/3"* ]]
}

@test "upload_to_hetzner logger advarsel men lykkes naar SFTP ls-la er tom og SSH sha256sum ogsaa er tom" {
    # SFTP ls -la returnerer ingenting → SSH sha256sum fallback → ssh stub returnerer 0 med tom output
    # Resultat: advarsel-logging, men status 0 (stoler paa SCP exit 0)
    export STUB_SFTP_LS_EMPTY=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    printf 'content' > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Kunne ikke bekrefte"* ]]
}

@test "upload_to_hetzner returnerer 1 og logger katalog-feil naar baade SFTP og SSH feiler" {
    # Bade SFTP og SSH maa feile for at katalog-oppretting skal returnere 1
    export STUB_SFTP_FAIL=1
    export STUB_SSH_FAIL=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 1 ]
    [[ "$output" == *"katalog"* ]]
}

@test "upload_with_retry respekterer BACKUP_RETRY_MAX=1 (ingen gjenforsok)" {
    export STUB_SCP_FAIL=1
    export BACKUP_RETRY_MAX=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"feilet etter 1 forsok"* ]]
    [[ "$output" != *"Prover igjen"* ]]
}

@test "upload_with_retry respekterer BACKUP_RETRY_MAX=2 (ett gjenforsok)" {
    export STUB_SCP_FAIL=1
    export BACKUP_RETRY_MAX=2
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"forsok 1/2"* ]]
    [[ "$output" == *"feilet etter 2 forsok"* ]]
    [[ "$output" != *"forsok 2/2"* ]]
}

@test "upload_to_hetzner returnerer 1 og logger katalog-feil naar baade SFTP og SSH feiler (2)" {
    export STUB_SFTP_FAIL=1
    export STUB_SSH_FAIL=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 1 ]
    [[ "$output" == *"katalog"* ]]
}

@test "upload_to_hetzner lykkes med SSH-fallback naar SFTP-subsystem er utilgjengelig men SSH shell virker" {
    # Simuler StorageBox der SFTP-subsystem feiler (f.eks. u571604 der SFTP er utilgjengelig)
    # men SSH shell-kommandoer (mkdir/test-d) fungerer.
    # Skal lykkes selv om hverken SFTP mkdir eller SFTP ls-la-verifisering virker.
    export STUB_SFTP_FAIL=1
    export STUB_SSH_FAIL=0
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    printf 'content' > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 0 ]
    # Forventer enten "lastet opp og verifisert" (SSH sha256sum fungerte) eller
    # "Kunne ikke bekrefte" med SCP exit 0 (begge verifiseringsveier feiler, men OK)
    [[ "$output" != *"SFTP og SSH feilet"* ]] || [[ "$output" == *"Kunne ikke bekrefte"* ]]
}

@test "upload_to_hetzner lykkes i SFTP-only-modus (ssh feiler, sftp fungerer)" {
    # Simuler StorageBox i SFTP-only-modus: ssh er utilgjengelig, sftp virker.
    # Med gammel kode (ssh mkdir/test-d) feiler upload_to_hetzner.
    # Med ny kode (sftp -mkdir/ls) skal upload lykkes.
    export STUB_SSH_FAIL=1
    export STUB_SFTP_FAIL=0
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    printf 'content' > "$dummy"
    export STUB_SFTP_LS_SIZE=7

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lastet opp og verifisert"* ]]
}
