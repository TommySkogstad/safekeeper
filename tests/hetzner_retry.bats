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

@test "SFTP_OPTS bruker HETZNER_SFTP_CONNECT_TIMEOUT naar det er satt" {
    export HETZNER_SFTP_CONNECT_TIMEOUT=5
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
    [[ "$sftp_args" == *"ConnectTimeout=5"* ]] || {
        echo "FEIL: ConnectTimeout=5 mangler i sftp-kallet: $sftp_args" >&2
        return 1
    }

    rm -f "$call_log"
}

@test "SFTP_OPTS bruker HETZNER_SSH_ALIVE_INTERVAL og HETZNER_SSH_ALIVE_COUNT naar de er satt" {
    export HETZNER_SSH_ALIVE_INTERVAL=60
    export HETZNER_SSH_ALIVE_COUNT=5
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
    [[ "$sftp_args" == *"ServerAliveInterval=60"* ]] || {
        echo "FEIL: ServerAliveInterval=60 mangler i sftp-kallet: $sftp_args" >&2
        return 1
    }
    [[ "$sftp_args" == *"ServerAliveCountMax=5"* ]] || {
        echo "FEIL: ServerAliveCountMax=5 mangler i sftp-kallet: $sftp_args" >&2
        return 1
    }

    rm -f "$call_log"
}

@test "SFTP_OPTS bruker StrictHostKeyChecking=yes mot innbakt global known_hosts naar HETZNER_HOST_KEY ikke er satt" {
    unset HETZNER_HOST_KEY
    load_backup_lib

    # Default er alltid streng verifisering — flaatenoklene ligger i imagets
    # /etc/ssh/ssh_known_hosts (global known_hosts, leses uten eksplisitt opt)
    [[ "${SFTP_OPTS[*]}" == *"StrictHostKeyChecking=yes"* ]] || {
        echo "FEIL: StrictHostKeyChecking=yes mangler i SFTP_OPTS: ${SFTP_OPTS[*]}" >&2
        return 1
    }
    [[ "${SFTP_OPTS[*]}" != *"accept-new"* ]] || {
        echo "FEIL: accept-new (TOFU) skal ikke lenger brukes: ${SFTP_OPTS[*]}" >&2
        return 1
    }
    [[ "${SFTP_OPTS[*]}" != *"UserKnownHostsFile"* ]] || {
        echo "FEIL: UserKnownHostsFile skal ikke vaere satt uten HETZNER_HOST_KEY: ${SFTP_OPTS[*]}" >&2
        return 1
    }
}

@test "ssh_known_hosts i repo-roten inneholder flaatenokler for *.your-storagebox.de paa port 23 og 22" {
    local f="$BATS_TEST_DIRNAME/../ssh_known_hosts"
    [[ -f "$f" ]] || { echo "FEIL: ssh_known_hosts mangler i repo-roten" >&2; return 1; }
    grep -q '^\[\*\.your-storagebox\.de\]:23 ssh-ed25519 ' "$f" || {
        echo "FEIL: mangler [*.your-storagebox.de]:23-ed25519-linje" >&2; return 1; }
    grep -q '^\*\.your-storagebox\.de ssh-ed25519 ' "$f" || {
        echo "FEIL: mangler port-22-variant (*.your-storagebox.de)" >&2; return 1; }
    # Alle ikke-kommentar-linjer maa vaere gyldige known_hosts-linjer
    ssh-keygen -lf "$f" >/dev/null 2>&1 || {
        echo "FEIL: ssh_known_hosts har ugyldige linjer iflg. ssh-keygen -lf" >&2; return 1; }
}

@test "SFTP_OPTS og SSH_OPTS bruker StrictHostKeyChecking=yes og pinnet known_hosts naar HETZNER_HOST_KEY er satt" {
    # Bruk en lokalt generert ed25519-nokkel formatert som known_hosts-linje —
    # innholdet trenger ikke vaere en ekte Hetzner-nokkel, kun gyldig ssh-keygen-format.
    local keyfile pubkey
    keyfile="$(mktemp -u)"
    ssh-keygen -t ed25519 -N '' -f "$keyfile" -q
    pubkey=$(cut -d' ' -f1,2 "${keyfile}.pub")
    export HETZNER_HOST_KEY="[u12345.your-storagebox.de]:23 ${pubkey}"
    load_backup_lib
    rm -f "$keyfile" "${keyfile}.pub"

    [[ "${SFTP_OPTS[*]}" == *"StrictHostKeyChecking=yes"* ]] || {
        echo "FEIL: StrictHostKeyChecking=yes mangler i SFTP_OPTS: ${SFTP_OPTS[*]}" >&2
        return 1
    }
    [[ "${SFTP_OPTS[*]}" == *"UserKnownHostsFile=${KNOWN_HOSTS_FILE}"* ]] || {
        echo "FEIL: UserKnownHostsFile peker ikke paa KNOWN_HOSTS_FILE: ${SFTP_OPTS[*]}" >&2
        return 1
    }
    [[ "${SSH_OPTS[*]}" == *"StrictHostKeyChecking=yes"* ]] || {
        echo "FEIL: StrictHostKeyChecking=yes mangler i SSH_OPTS: ${SSH_OPTS[*]}" >&2
        return 1
    }
    [[ -f "$KNOWN_HOSTS_FILE" ]] || {
        echo "FEIL: KNOWN_HOSTS_FILE ble ikke opprettet" >&2
        return 1
    }
    grep -qF "$pubkey" "$KNOWN_HOSTS_FILE" || {
        echo "FEIL: KNOWN_HOSTS_FILE inneholder ikke pinnet nokkel: $(cat "$KNOWN_HOSTS_FILE")" >&2
        return 1
    }
}

@test "ugyldig HETZNER_HOST_KEY feiler ved oppstart med tydelig feilmelding" {
    export HETZNER_HOST_KEY="dette-er-ikke-en-gyldig-known-hosts-linje"

    run bash -c "
        stripped=\$(sed 's|^main \"\\\$@\".*\$|:|' '${SAFEKEEPER_ROOT}/backup-entrypoint.sh')
        eval \"\$stripped\"
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"HETZNER_HOST_KEY er ikke en gyldig known_hosts-linje"* ]] || {
        echo "FEIL: forventet feilmelding om ugyldig HETZNER_HOST_KEY, fikk: $output" >&2
        return 1
    }
}

@test "HETZNER_HOST_KEY uten vertsdel (kun nokkel-type + blob) avvises med tydelig feilmelding" {
    local keyfile pubkey
    keyfile="$(mktemp -u)"
    ssh-keygen -t ed25519 -N '' -f "$keyfile" -q
    pubkey=$(cut -d' ' -f1,2 "${keyfile}.pub")
    export HETZNER_HOST_KEY="${pubkey}"
    rm -f "$keyfile" "${keyfile}.pub"

    run bash -c "
        stripped=\$(sed 's|^main \"\\\$@\".*\$|:|' '${SAFEKEEPER_ROOT}/backup-entrypoint.sh')
        eval \"\$stripped\"
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"HETZNER_HOST_KEY mangler vertsdel"* ]] || {
        echo "FEIL: forventet feilmelding om manglende vertsdel, fikk: $output" >&2
        return 1
    }
}

@test "ugyldig HETZNER_HOST_KEY rydder likevel opp SSH_KEY og KNOWN_HOSTS_FILE via cleanup-trap" {
    # Regresjonstest for QA-funn (#190): trap cleanup EXIT ble tidligere registrert
    # ETTER HETZNER_HOST_KEY-valideringen, saa error()/exit 1 ved ugyldig nokkel
    # lekket bade den tomme SSH_KEY-mktemp-filen og KNOWN_HOSTS_FILE i /tmp.
    local isolated_tmpdir
    isolated_tmpdir="$(mktemp -d)"
    export HETZNER_HOST_KEY="dette-er-ikke-en-gyldig-known-hosts-linje"

    TMPDIR="$isolated_tmpdir" run bash -c "
        stripped=\$(sed 's|^main \"\\\$@\".*\$|:|' '${SAFEKEEPER_ROOT}/backup-entrypoint.sh')
        eval \"\$stripped\"
    "
    [ "$status" -ne 0 ]

    local leftover
    leftover=$(find "$isolated_tmpdir" -type f)
    [[ -z "$leftover" ]] || {
        echo "FEIL: cleanup-trap ryddet ikke opp mktemp-filer ved valideringsfeil: $leftover" >&2
        rm -rf "$isolated_tmpdir"
        return 1
    }
    rm -rf "$isolated_tmpdir"
}
