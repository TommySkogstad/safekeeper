#!/usr/bin/env bats
#
# Tester for cron-oppsett i main() (uten backup-argument) i backup-entrypoint.sh.
# Verifiserer at /etc/safekeeper.env og /etc/crontabs/root skrives korrekt.
# Bruker stubs for pg_isready/pg_dump/gpg/crond.

load 'helpers/common'

setup() {
    setup_stubs

    BACKUP_DIR="$(mktemp -d)"
    BACKUP_SUCCESS_FILE="$(mktemp -u)"
    SAFEKEEPER_ENV_FILE="$(mktemp -u)"
    CRONTAB_FILE="$(mktemp -u)"
    export BACKUP_DIR BACKUP_SUCCESS_FILE SAFEKEEPER_ENV_FILE CRONTAB_FILE

    export PROJECT_NAME=testprosjekt
    export DB_PASSWORD=hemmelig
    export BACKUP_ENCRYPTION_KEY=testnokkel123
    unset HETZNER_HOST HETZNER_USER FILES_DIR
    unset STUB_GPG_FAIL STUB_PGDUMP_FAIL STUB_PGISREADY_FAIL
}

teardown() {
    rm -rf "$BACKUP_DIR"
    rm -f "$BACKUP_SUCCESS_FILE" "$SAFEKEEPER_ENV_FILE" "$CRONTAB_FILE"
}

@test "BACKUP_SCHEDULE lagres i crontab-fil" {
    export BACKUP_SCHEDULE="0 3 * * *"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh"
    [ "$status" -eq 0 ]

    [ -f "$CRONTAB_FILE" ]
    grep -q "0 3 \* \* \*" "$CRONTAB_FILE"
}

@test "standardverdi '0 5 * * *' brukes i crontab hvis BACKUP_SCHEDULE ikke er satt" {
    unset BACKUP_SCHEDULE
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh"
    [ "$status" -eq 0 ]

    [ -f "$CRONTAB_FILE" ]
    grep -q "0 5 \* \* \*" "$CRONTAB_FILE"
}

@test "safekeeper.env opprettes med eksporterte variabler" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh"
    [ "$status" -eq 0 ]

    [ -f "$SAFEKEEPER_ENV_FILE" ]
    grep -q "export PROJECT_NAME=" "$SAFEKEEPER_ENV_FILE"
    grep -q "export DB_PASSWORD=" "$SAFEKEEPER_ENV_FILE"
    grep -q "export BACKUP_ENCRYPTION_KEY=" "$SAFEKEEPER_ENV_FILE"
}

@test "safekeeper.env har chmod 600" {
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh"
    [ "$status" -eq 0 ]

    [ -f "$SAFEKEEPER_ENV_FILE" ]
    local perms
    perms=$(stat -c '%a' "$SAFEKEEPER_ENV_FILE")
    [ "$perms" = "600" ]
}

@test "safekeeper.env bevarer BACKUP_ENCRYPTION_KEY med enkle anfoerselstegn" {
    export BACKUP_ENCRYPTION_KEY="nokkel'med'enkle"
    run bash "$SAFEKEEPER_ROOT/backup-entrypoint.sh"
    [ "$status" -eq 0 ]

    [ -f "$SAFEKEEPER_ENV_FILE" ]
    # Sourcing av env-filen skal gi korrekt verdi
    # shellcheck disable=SC1090
    source "$SAFEKEEPER_ENV_FILE"
    [ "$BACKUP_ENCRYPTION_KEY" = "nokkel'med'enkle" ]
}
