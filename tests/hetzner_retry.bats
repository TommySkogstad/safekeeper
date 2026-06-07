#!/usr/bin/env bats
#
# Tester for upload_with_retry i backup-entrypoint.sh.
# Verifiserer at opplasting forsoeker 3 ganger ved vedvarende feil
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

    unset STUB_SCP_FAIL STUB_SSH_FAIL STUB_SFTP_FAIL STUB_SFTP_WRONG_SIZE STUB_SFTP_LS_SIZE STUB_SFTP_PUT_FAIL
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

@test "upload_with_retry prover 3 ganger ved vedvarende sftp-feil" {
    export STUB_SFTP_PUT_FAIL=1
    export BACKUP_RETRY_MAX=3
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"forsok 1/3"* ]]
    [[ "$output" == *"forsok 2/3"* ]]
}

@test "upload_with_retry logger 'etter 3 forsok' ved total feil" {
    export STUB_SFTP_PUT_FAIL=1
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

@test "upload_to_hetzner returnerer 1 naar full SFTP-feil (mkdir advarsel + put feiler)" {
    # Bade mkdir-batch og put feiler (SFTP nede) — status 1, advarsel med 'katalog' fra mkdir
    export STUB_SFTP_FAIL=1
    export STUB_SSH_FAIL=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 1 ]
    [[ "$output" == *"katalog"* ]]
}

@test "upload_to_hetzner lykkes naar SFTP mkdir-batch feiler men put lykkes (u571604-scenario)" {
    # StorageBox u571604: mkdir+ls-batch feiler (sftp exit 1 ved 'ls path'),
    # SSH er utilgjengelig (restricted shell). Gammel kode returnerte 1 pga
    # hard-gating paa mkdir. Ny kode: mkdir best-effort, put kjores uansett.
    export STUB_SFTP_LS_FAIL=1
    export STUB_SSH_FAIL=1
    export STUB_SFTP_LS_SIZE=7
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    printf 'content' > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lastet opp og verifisert"* ]]
}

@test "upload_with_retry respekterer BACKUP_RETRY_MAX=1 (ingen gjenforsok)" {
    export STUB_SFTP_PUT_FAIL=1
    export BACKUP_RETRY_MAX=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"feilet etter 1 forsok"* ]]
    [[ "$output" != *"Prover igjen"* ]]
}

@test "upload_with_retry respekterer BACKUP_RETRY_MAX=2 (ett gjenforsok)" {
    export STUB_SFTP_PUT_FAIL=1
    export BACKUP_RETRY_MAX=2
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"forsok 1/2"* ]]
    [[ "$output" == *"feilet etter 2 forsok"* ]]
    [[ "$output" != *"forsok 2/2"* ]]
}

@test "upload_to_hetzner feiler naar SFTP-subsystem er utilgjengelig (ingen SSH-fallback for opplasting)" {
    # StorageBox der SFTP er utilgjengelig (f.eks. u571604): mkdir bruker SSH-fallback,
    # men selve opplastingen (sftp put) feiler — ingen scp-fallback etter refaktorering.
    export STUB_SFTP_FAIL=1
    export STUB_SSH_FAIL=0
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    printf 'content' > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ADVARSEL"* ]]
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

@test "upload_to_hetzner lykkes i ren SFTP-only-modus uten scp i PATH" {
    # Verifiserer at opplasting lykkes selv om scp feiler — etter fiks skal
    # sftp put brukes for opplasting, ikke scp.
    export STUB_SCP_FAIL=1
    export STUB_SSH_FAIL=1
    export STUB_SFTP_FAIL=0
    export STUB_SFTP_LS_SIZE=7
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    printf 'content' > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lastet opp og verifisert"* ]]
}

@test "upload_with_retry prover 3 ganger ved vedvarende sftp put-feil" {
    export STUB_SFTP_PUT_FAIL=1
    export BACKUP_RETRY_MAX=3
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"forsok 1/3"* ]]
    [[ "$output" == *"forsok 2/3"* ]]
}

@test "upload_with_retry respekterer BACKUP_RETRY_MAX=1 med sftp put-feil (ingen gjenforsok)" {
    export STUB_SFTP_PUT_FAIL=1
    export BACKUP_RETRY_MAX=1
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    echo "content" > "$dummy"

    run upload_with_retry "$dummy"
    [[ "$output" == *"feilet etter 1 forsok"* ]]
    [[ "$output" != *"Prover igjen"* ]]
}

@test "sftp-kall inkluderer ConnectTimeout og ServerAlive for aa forhindre hengt lock-fd" {
    # Regresjonstest for incident 2026-06-07 (hwa/styreportal):
    # En hengt sftp-prosess arvet LOCK_FD og blokkerte cron-backups i 3 dager.
    # Verifiserer at SFTP_OPTS inneholder timeout-opsjoner slik at sftp aldri
    # henger uendelig og frigir låsen innen ~75 sekunder.
    local call_log
    call_log="$(mktemp)"
    export STUB_SFTP_CALL_LOG="$call_log"
    export STUB_SFTP_LS_SIZE=7
    load_backup_lib

    local dummy="$BACKUP_DIR/testprosjekt_20260101_120000.sql.gz.gpg"
    printf 'content' > "$dummy"

    run upload_to_hetzner "$dummy"
    [ "$status" -eq 0 ]

    local sftp_args
    sftp_args=$(cat "$call_log")
    [[ "$sftp_args" == *"ConnectTimeout=30"* ]] || {
        echo "FEIL: ConnectTimeout=30 mangler i sftp-kallet: $sftp_args" >&2
        return 1
    }
    [[ "$sftp_args" == *"ServerAliveInterval=15"* ]] || {
        echo "FEIL: ServerAliveInterval=15 mangler i sftp-kallet: $sftp_args" >&2
        return 1
    }
    [[ "$sftp_args" == *"ServerAliveCountMax=3"* ]] || {
        echo "FEIL: ServerAliveCountMax=3 mangler i sftp-kallet: $sftp_args" >&2
        return 1
    }

    rm -f "$call_log"
}
