#!/usr/bin/env bats
#
# Tester for cleanup_hetzner() i backup-entrypoint.sh.
# Verifiserer at sletting av gamle Hetzner-backups gjøres via SFTP batch
# med minimalt antall sftp-prosess-kall.

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
    export BACKUP_RETENTION_DAYS=30

    STUB_SFTP_CALL_LOG="$(mktemp)"
    export STUB_SFTP_CALL_LOG

    unset STUB_SCP_FAIL STUB_SFTP_FAIL STUB_SFTP_LS_OUTPUT STUB_SFTP_RM_FAIL
}

teardown() {
    rm -rf "$BACKUP_DIR"
    rm -f "${STUB_SFTP_CALL_LOG:-}"
}

# ls -la-formatert linje (permissions links owner group size month day time name)
ls_la_line() {
    echo "-rw-r--r--    1 u12345  u12345      12345 Jan  1 2020 ${1}"
}

# Teller antall sftp-prosess-invokasjonar (linjer uten CMD:-prefiks i CALL_LOG)
sftp_process_count() {
    grep -v '^CMD:' "$STUB_SFTP_CALL_LOG" 2>/dev/null | wc -l | tr -d ' '
}

@test "cleanup_hetzner gjoor maks 2 SFTP-prosess-kall (ls-la + rm) for 3 gamle filer" {
    # Cutoff blir i dag - 30 dager; filer fra 2020 er garantert eldre
    local l1 l2 l3
    l1=$(ls_la_line "testprosjekt_20200101_030000.sql.gz.gpg")
    l2=$(ls_la_line "testprosjekt_20200102_030000.sql.gz.gpg")
    l3=$(ls_la_line "testprosjekt_20200103_030000.sql.gz.gpg")
    export STUB_SFTP_LS_OUTPUT="${l1}"$'\n'"${l2}"$'\n'"${l3}"

    load_backup_lib
    run cleanup_hetzner

    local call_count
    call_count=$(sftp_process_count)
    [[ "$call_count" -eq 2 ]]
}

@test "cleanup_hetzner gjoor ingen rm-kall hvis ingen filer er eldre enn cutoff" {
    # Filer fra fremtiden er garantert nyere enn cutoff
    local future_date
    future_date=$(date -d "+365 days" +%Y%m%d 2>/dev/null || date -v+365d +%Y%m%d 2>/dev/null || echo "20991231")
    export STUB_SFTP_LS_OUTPUT="$(ls_la_line "testprosjekt_${future_date}_030000.sql.gz.gpg")"

    load_backup_lib
    run cleanup_hetzner

    # Kun ls-la-kallet forventes — ingen rm
    ! grep -q '^CMD: rm ' "$STUB_SFTP_CALL_LOG" 2>/dev/null
}

@test "cleanup_hetzner gjoor ingen SFTP-kall naaar Hetzner ikke er konfigurert" {
    unset HETZNER_HOST

    load_backup_lib
    run cleanup_hetzner

    local call_count
    call_count=$(sftp_process_count)
    [[ "$call_count" -eq 0 ]]
}

@test "cleanup_hetzner avviser filnavn med spesialtegn og logger advarsel" {
    # Filnavn med semikolon (injeksjonsforsøk) skal avvises.
    # Bruker variabel for å unngå at semikolon tolkes av shell i command substitution.
    local malicious="testprosjekt_20200102_030000.sql.gz.gpg;malicious"
    local l1 l2 l3
    l1=$(ls_la_line "testprosjekt_20200101_030000.sql.gz.gpg")
    l2="-rw-r--r--    1 u12345  u12345      12345 Jan  2 2020 ${malicious}"
    l3=$(ls_la_line "testprosjekt_20200103_030000.sql.gz.gpg")
    export STUB_SFTP_LS_OUTPUT="${l1}"$'\n'"${l2}"$'\n'"${l3}"

    load_backup_lib
    run cleanup_hetzner

    # Filen med semikolon skal ikke være med i rm-kommandoen
    ! grep -q 'malicious' "$STUB_SFTP_CALL_LOG" 2>/dev/null
    # Advarsel skal være logget
    echo "$output" | grep -q "ADVARSEL"
}

@test "cleanup_hetzner logger advarsel naaar SFTP rm-kommando feiler" {
    export STUB_SFTP_LS_OUTPUT="$(ls_la_line "testprosjekt_20200101_030000.sql.gz.gpg")"
    export STUB_SFTP_RM_FAIL=1

    load_backup_lib
    run cleanup_hetzner

    [[ "$output" == *"ADVARSEL"* ]]
}

@test "cleanup_hetzner behandler gyldige filnavn normalt" {
    local l1 l2
    l1=$(ls_la_line "testprosjekt_20200101_030000.sql.gz.gpg")
    l2=$(ls_la_line "testprosjekt_20200102_030000.sql.gz.gpg")
    export STUB_SFTP_LS_OUTPUT="${l1}"$'\n'"${l2}"

    load_backup_lib
    run cleanup_hetzner

    # Begge filer skal markeres for sletting (rm-kall skal forekomme)
    grep -q '^CMD: rm ' "$STUB_SFTP_CALL_LOG" 2>/dev/null
}

@test "cleanup_hetzner returnerer feil og logger advarsel naaar dato-cutoff-kalkulasjon feiler" {
    export STUB_DATE_FAIL=1

    load_backup_lib
    run cleanup_hetzner

    [[ "$status" -ne 0 ]]
    echo "$output" | grep -q "ADVARSEL"
}

@test "cleanup_hetzner sletter gammel fil — dato-ekstraksjon med POSIX sed (BusyBox-kompatibel)" {
    # grep -oP (Perl-regex) støttes ikke i BusyBox grep (postgres:17-alpine).
    # Verifiserer at dato-ekstraksjon fungerer og at filen inkluderes i rm-kommandoen.
    export STUB_SFTP_LS_OUTPUT="$(ls_la_line "testprosjekt_20200101_030000.sql.gz.gpg")"

    load_backup_lib
    run cleanup_hetzner

    grep -q 'testprosjekt_20200101_030000.sql.gz.gpg' "$STUB_SFTP_CALL_LOG"
}

@test "cleanup_hetzner haandterer fulle stier i SFTP ls-output (Hetzner-format)" {
    # Noen Hetzner StorageBox-konfigurasjoner returnerer fulle stier i ls-output.
    # Uten basename-haandtering avvises slike filer med 'ugyldige tegn'-advarsel
    # og slettes aldri (skraff akkumulerer pa Hetzner).
    local full_path="backups/testprosjekt/testprosjekt_20200101_030000.sql.gz.gpg"
    local l1
    l1="-rw-r--r--    1 u12345  u12345      12345 Jan  1 2020 ${full_path}"
    export STUB_SFTP_LS_OUTPUT="${l1}"

    load_backup_lib
    run cleanup_hetzner

    # Skal IKKE logge advarsel om ugyldige tegn for denne filen
    ! echo "$output" | grep -q "Avvist filnavn"
    # Filen skal markeres for sletting
    grep -q 'testprosjekt_20200101_030000.sql.gz.gpg' "$STUB_SFTP_CALL_LOG"
}
