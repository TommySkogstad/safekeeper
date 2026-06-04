#!/usr/bin/env bats
#
# Tester for GPG-krypteringsflyten i backup-entrypoint.sh.
# Bruker ekte gpg-binar (ikke stub) slik at round-trip og noekkel-validering
# faktisk verifiseres. For tester som kjorer hele run_backup, fjernes
# gpg-stuben fra et midlertidig stub-dir slik at ekte gpg brukes mens
# pg_dump/pg_isready/scp/ssh/sleep fortsatt mockes.

load 'helpers/common'

setup() {
    command -v gpg >/dev/null 2>&1 || skip "gpg ikke installert"

    BACKUP_DIR="$(mktemp -d)"
    BACKUP_SUCCESS_FILE="$(mktemp -u)"
    GNUPGHOME="$(mktemp -d)"
    chmod 700 "$GNUPGHOME"
    export BACKUP_DIR BACKUP_SUCCESS_FILE GNUPGHOME

    export PROJECT_NAME=enctest
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY="korrekt-noekkel-12345"
    unset HETZNER_HOST HETZNER_USER FILES_DIR
    unset STUB_GPG_FAIL STUB_PGDUMP_FAIL STUB_PGISREADY_FAIL
}

teardown() {
    rm -rf "$BACKUP_DIR" "$GNUPGHOME"
    rm -f "$BACKUP_SUCCESS_FILE"
    if [[ -n "${REAL_GPG_STUBS:-}" ]]; then
        rm -rf "$REAL_GPG_STUBS"
    fi
    return 0
}

# Setter opp et stub-dir uten gpg-stub, men med oevrige stubs
# (pg_dump, pg_isready, scp, ssh, sleep, psql). Brukes for tester
# som maa kjore ekte gpg, men trenger mock for andre verktoey.
setup_stubs_without_gpg() {
    REAL_GPG_STUBS="$(mktemp -d)"
    export REAL_GPG_STUBS
    cp "${SAFEKEEPER_ROOT}/tests/stubs/"* "$REAL_GPG_STUBS/"
    rm -f "$REAL_GPG_STUBS/gpg"
    export PATH="${REAL_GPG_STUBS}:${PATH}"
    # Stub pg_dump-output komprimert+kryptert er < 1024 bytes (prod-default).
    # Sett terskelen til 50 for tester (tom pg_dump gir ~20 bytes < 50).
    export MIN_BACKUP_SIZE_BYTES="${MIN_BACKUP_SIZE_BYTES:-50}"
}

@test "round-trip: ekte GPG --symmetric AES256 dekrypterer til identisk klartekst" {
    local plaintext="$BATS_TEST_TMPDIR/plain.txt"
    local cipher="$BATS_TEST_TMPDIR/cipher.gpg"
    local decrypted="$BATS_TEST_TMPDIR/decrypted.txt"
    printf 'safekeeper round-trip test data\n' > "$plaintext"

    gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$plaintext" > "$cipher"

    [ -s "$cipher" ]

    gpg --batch --yes --decrypt \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$cipher" > "$decrypted"

    diff "$plaintext" "$decrypted"
}

@test "feil passphrase feiler dekryptering av kryptert fil" {
    local plaintext="$BATS_TEST_TMPDIR/plain.txt"
    local cipher="$BATS_TEST_TMPDIR/cipher.gpg"
    printf 'sensitiv backup-data\n' > "$plaintext"

    gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$plaintext" > "$cipher"

    run gpg --batch --yes --decrypt \
        --passphrase-fd 3 3< <(printf '%s' "feil-noekkel-99999") \
        < "$cipher"
    [ "$status" -ne 0 ]
}

@test "run_backup produserer fil som kan dekrypteres med BACKUP_ENCRYPTION_KEY" {
    setup_stubs_without_gpg

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local backup_file
    backup_file=$(find "$BACKUP_DIR" -maxdepth 1 -name "enctest_*.sql.gz.gpg" | head -1)
    [ -n "$backup_file" ]
    [ -s "$backup_file" ]

    # Dekrypter -> gunzip skal levere stub-pg_dump-output uten feil
    run bash -c "gpg --batch --yes --decrypt \
        --passphrase-fd 3 3< <(printf '%s' \"\$BACKUP_ENCRYPTION_KEY\") \
        < \"$backup_file\" | gunzip -t"
    [ "$status" -eq 0 ]
}

@test "run_backup bruker AES256 som cipher (verifisert via gpg --list-packets)" {
    setup_stubs_without_gpg

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local backup_file
    backup_file=$(find "$BACKUP_DIR" -maxdepth 1 -name "enctest_*.sql.gz.gpg" | head -1)
    [ -n "$backup_file" ]

    # gpg --list-packets paa kryptert fil skal vise cipher 9 (AES256).
    # GnuPG bruker numerisk ID i list-packets-utskrift; 9 = AES256.
    local packets
    packets=$(gpg --batch --list-packets \
        --pinentry-mode loopback \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$backup_file" 2>&1)
    [[ "$packets" =~ cipher\ 9 ]] || [[ "$packets" =~ AES256 ]]
}

@test "fil-backup (FILES_DIR) produserer .tar.gz.gpg som kan dekrypteres og utpakkes" {
    setup_stubs_without_gpg

    FILES_DIR="$(mktemp -d)"
    export FILES_DIR
    printf 'innhold-fil-1\n' > "$FILES_DIR/fil1.txt"
    printf 'innhold-fil-2\n' > "$FILES_DIR/fil2.txt"

    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh" backup
    [ "$status" -eq 0 ]

    local files_backup
    files_backup=$(find "$BACKUP_DIR" -maxdepth 1 -name "enctest_files_*.tar.gz.gpg" | head -1)
    [ -n "$files_backup" ]
    [ -s "$files_backup" ]

    # Dekrypter + tar tzf skal liste de tilfoyde filene
    local listing
    listing=$(gpg --batch --yes --decrypt \
        --passphrase-fd 3 3< <(printf '%s' "$BACKUP_ENCRYPTION_KEY") \
        < "$files_backup" 2>/dev/null | tar tzf -)
    [[ "$listing" =~ fil1.txt ]]
    [[ "$listing" =~ fil2.txt ]]

    rm -rf "$FILES_DIR"
}
