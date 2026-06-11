# Felles oppsett for BATS-tester i safekeeper.
#
# Lastes via `load 'helpers/common'` i .bats-filer.

SAFEKEEPER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SAFEKEEPER_ROOT

# Prepender tests/stubs til PATH slik at tester kjorer stub-binaerer
# for pg_isready, pg_dump, gpg og sleep i stedet for ekte verktoy.
# Kalles fra setup() i .bats-filer som trenger stubs.
setup_stubs() {
    export PATH="${SAFEKEEPER_ROOT}/tests/stubs:${PATH}"
    # Stub pg_dump skriver bare ~88 bytes komprimert — langt under prod-default 1024.
    # Sett terskelen til 50 for tester (STUB_PGDUMP_EMPTY=1 gir ~20 bytes, som er < 50).
    export MIN_BACKUP_SIZE_BYTES="${MIN_BACKUP_SIZE_BYTES:-50}"
}

# Laster backup-entrypoint.sh som bibliotek uten main og uten set -euo pipefail
# (set -euo pipefail og trap cleanup EXIT forstyrrer BATS sin feilhåndtering i testsuiten).
load_backup_lib() {
    local stripped
    stripped=$(sed 's|^main "\$@".*$|:|; s|^set -euo pipefail.*$|:|; s|^trap cleanup EXIT.*$|:|' "$SAFEKEEPER_ROOT/backup-entrypoint.sh")
    eval "$stripped"
    echo "dummy-ssh-key" > "$SSH_KEY"
}
