# Felles oppsett for BATS-tester i safekeeper.
#
# Lastes via `load 'helpers/common'` i .bats-filer.

SAFEKEEPER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SAFEKEEPER_ROOT
