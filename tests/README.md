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
    crond                    # Stub som avslutter umiddelbart (for cron-oppsett-tester)
    date                     # Stub som videresender til real date; STUB_DATE_FAIL=1 feiler datoutregning
    gpg                      # Stub som pipe-through stdin (virker for --symmetric og --decrypt)
    pg_dump                  # Stub som skriver dummy-SQL til stdout
    pg_isready               # Stub for PostgreSQL-helsesjekk
    psql                     # Stub som konsumerer stdin (for restore-tester)
    sftp                     # Stub for SFTP-operasjoner (opplasting, verifisering, opprydding på Hetzner)
    sleep                    # Stub som returnerer umiddelbart
    ssh                      # Stub med STUB_SSH_FAIL, returnerer tom stdout
    wget                     # Stub for ntfy-varsling (logger kall til WGET_CALL_LOG)
  backup_files.bats          # Tester for backup_files() happy-path (.tar.gz.gpg, .sha256, chmod 600)
  check_requirements.bats    # Tester for manglende miljøvariabler og SHA256-digest på baseimage
  cron.bats                  # Tester for cron-oppsett og safekeeper.env-generering
  encryption.bats            # Tester for GPG AES256-kryptering (round-trip)
  hetzner_cleanup.bats       # Tester for cleanup_hetzner (batching, ingen N+1 SSH, filnavn-validering)
  hetzner_retry.bats         # Tester for upload_with_retry (3 forsøk, feilmelding)
  locking.bats               # Tester for flock-lås (lås tas/frigis, samtidig backup hopper over med ADVARSEL)
  ntfy.bats                  # Tester for proaktiv ntfy-varsling ved backup-feil
  restore.bats               # Tester for restore.sh (happy-path .sql/.sql.gz/.sql.gz.gpg, fil-backup, checksum, encryption, psql-feil)
  retention.bats             # Tester for lokal backup-retention (sletting av gamle filer)
  run_backup.bats            # Tester for happy-path backup-flyt
  manual/
    verify-dump-restore-matrix.sh  # Manuelt skript — ekte dump/restore mot postgres:16-alpine/17-alpine i Docker
```

## Manuelle verktøy

`tests/manual/verify-dump-restore-matrix.sh` verifiserer safekeeper-imagets `pg_dump`/`psql`-klient mot ekte `postgres:16-alpine`- og `postgres:17-alpine`-servere i midlertidige Docker-containere (unikt navngitt/nettverk, rydder opp selv). Dette er IKKE en BATS-test og plukkes ALDRI opp av `bats tests/` eller `./tests/run.sh` (som kun matcher `*.bats`) — krever ekte Docker og kjøres kun manuelt:

```bash
./tests/manual/verify-dump-restore-matrix.sh
```

Se [README.md](../README.md#dumprestore-kompatibilitet-mellom-postgresql-versjoner) for funn og begrensninger fra siste kjøring.

## Stubs og scenariovariasjon

Stub-binærene i `tests/stubs/` prependes til `PATH` via `setup_stubs()` i `helpers/common.bash`. De støtter scenariovariasjon via miljøvariabler:

| Variabel | Effekt |
|----------|--------|
| `STUB_DATE_FAIL=1` | `date` feiler ved datoutregning (`-d`/`-v`-flagg) — brukt i retention-tester |
| `STUB_GPG_FAIL=1` | `gpg` returnerer 1 ved kryptering |
| `STUB_GPG_FAIL_VERIFY=1` | `gpg` returnerer 1 ved dekryptering (verifisering av database-backup) |
| `STUB_GPG_FAIL_FILES=1` | `gpg` returnerer 1 ved kryptering av fil-backup |
| `STUB_GPG_FAIL_VERIFY_FILES=1` | `gpg` returnerer 1 ved dekryptering av fil-backup (verifisering) |
| `STUB_PGDUMP_FAIL=1` | `pg_dump` returnerer 1 |
| `STUB_PGISREADY_FAIL=always` | `pg_isready` returnerer 1 (brukt i ntfy-tester) |
| `STUB_PSQL_FAIL=1` | `psql` returnerer 1 |
| `STUB_SCP_FAIL=1` | No-op — ingen `scp`-stub finnes; variabelen eksporteres i én test som dokumentasjon på at opplasting ikke bruker `scp` |
| `STUB_SFTP_FAIL=1` | `sftp` returnerer 1 umiddelbart (tilkoblingsfeil) |
| `STUB_SFTP_MKDIR_FAIL=1` | `sftp` mkdir-kommandoer feiler (exit 1) |
| `STUB_SFTP_LS_OUTPUT` | Rå `ls -la`-formatert output for sftp ls-kommandoer |
| `STUB_SFTP_LS_SIZE` | Filstørrelse som returneres for `ls -la` enkeltfil (default: 7) |
| `STUB_SFTP_LS_EMPTY=1` | `sftp ls -la` returnerer ingen output — verifisering feiler |
| `STUB_SFTP_LS_FAIL=1` | Plain `sftp ls` (uten `-la`) feiler — simulerer u571604-scenario med restricted shell |
| `STUB_SFTP_WRONG_SIZE=1` | Returnerer feil filstørrelse (999999) — simulerer størrelsesmismatch etter opplasting |
| `STUB_SFTP_RM_FAIL=1` | `sftp rm`-kommandoer feiler (exit 1) |
| `STUB_SFTP_PUT_FAIL=1` | `sftp put`-kommandoer feiler (exit 1) |
| `STUB_SFTP_CALL_LOG` | Fil der sftp-stuben logger alle prosess-kall og batch-kommandoer |
| `STUB_SSH_FAIL=1` | `ssh` returnerer 1 |
| `WGET_CALL_LOG` | `wget` stub logger alle kall til denne fila (brukt i ntfy-tester) |

For testisolasjon kan `BACKUP_SUCCESS_FILE` settes til en mktemp-sti i stedet for den hardkodede `/tmp/last-backup-success`.

`backup_files.bats`, `hetzner_retry.bats`, `hetzner_cleanup.bats` og `run_backup.bats` bruker `load_backup_lib()` fra `helpers/common.bash` til å loade `backup-entrypoint.sh` som bibliotek. Denne funksjonen strippes main-kallet, `set -euo pipefail` og `trap cleanup EXIT` slik at funksjoner som `upload_with_retry`, `cleanup_hetzner` og `backup_files` kan kalles direkte uten aa kjore en full backup-flyt (og uten aa forstyrre BATSs feilhåndtering).
