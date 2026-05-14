# Safekeeper-tester

Automatiserte integrasjonstester for `backup-entrypoint.sh` og `restore.sh` basert på [BATS](https://github.com/bats-core/bats-core).

## Kjøre lokalt

```bash
# Installer BATS
sudo apt install bats          # Ubuntu/Debian
brew install bats-core         # macOS

# Kjør testene
./tests/run.sh
```

Eller direkte:

```bash
bats tests/
```

## Struktur

```
tests/
  run.sh                     # Wrapper for lokal kjøring
  helpers/
    common.bash              # Felles oppsett (SAFEKEEPER_ROOT, setup_stubs)
  stubs/
    pg_isready               # Stub for PostgreSQL-helsesjekk
    pg_dump                  # Stub som skriver dummy-SQL til stdout
    gpg                      # Stub som pipe-through stdin (virker for --symmetric og --decrypt)
    psql                     # Stub som konsumerer stdin (for restore-tester)
    scp                      # Stub med STUB_SCP_FAIL for Hetzner-retry-tester
    ssh                      # Stub med STUB_SSH_FAIL, returnerer tom stdout
    sleep                    # Stub som returnerer umiddelbart
  backup_files.bats          # Tester for backup_files() happy-path (.tar.gz.gpg, .sha256, chmod 600)
  check_requirements.bats    # Tester for manglende miljøvariabler
  cron.bats                  # Tester for cron-oppsett og safekeeper.env-generering
  encryption.bats            # Tester for GPG AES256-kryptering (round-trip)
  hetzner_cleanup.bats       # Tester for cleanup_hetzner (batching, ingen N+1 SSH, filnavn-validering)
  hetzner_retry.bats         # Tester for upload_with_retry (3 forsøk, feilmelding)
  restore.bats               # Tester for restore.sh (checksum, krav om nøkkel)
  retention.bats             # Tester for lokal backup-retention (sletting av gamle filer)
  run_backup.bats            # Tester for happy-path backup-flyt
```

## Stubs og scenariovariasjon

Stub-binærene i `tests/stubs/` prependes til `PATH` via `setup_stubs()` i `helpers/common.bash`. De støtter scenariovariasjon via miljøvariabler:

| Variabel | Effekt |
|----------|--------|
| `STUB_GPG_FAIL=1` | `gpg` returnerer 1 |
| `STUB_PGDUMP_FAIL=1` | `pg_dump` returnerer 1 |
| `STUB_PGISREADY_FAIL=1` | `pg_isready` returnerer 1 |
| `STUB_SCP_FAIL=1` | `scp` returnerer 1 (brukt i Hetzner-retry-tester) |
| `STUB_SSH_FAIL=1` | `ssh` returnerer 1 |
| `STUB_PSQL_FAIL=1` | `psql` returnerer 1 |

For testisolasjon kan `BACKUP_SUCCESS_FILE` settes til en mktemp-sti i stedet for den hardkodede `/tmp/last-backup-success`.

`hetzner_retry.bats` og `hetzner_cleanup.bats` sourcer `backup-entrypoint.sh` som bibliotek (main-kallet strippes bort) slik at `upload_with_retry` og `cleanup_hetzner` kan kalles direkte uten aa kjore en full backup-flyt.
