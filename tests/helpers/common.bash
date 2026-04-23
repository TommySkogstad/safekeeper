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
}
