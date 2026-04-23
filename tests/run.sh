#!/bin/bash
#
# Wrapper for aa kjoere BATS-tester lokalt.
# Krever at `bats` er installert (apt install bats, brew install bats-core, osv.).

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v bats >/dev/null 2>&1; then
    echo "FEIL: bats er ikke installert. Installer via:" >&2
    echo "  Ubuntu/Debian: sudo apt install bats" >&2
    echo "  macOS:         brew install bats-core" >&2
    echo "  Manuelt:       https://github.com/bats-core/bats-core" >&2
    exit 1
fi

exec bats .
