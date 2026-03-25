# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Prosjektoversikt

**Safekeeper** - Parametrisert Docker-image for automatisk PostgreSQL-backup med lokal lagring (NAS) og offsite-backup til Hetzner StorageBox (SSH/SCP). Brukes av alle Kotlin/Ktor-appene i portefoljen (lo-finans, biologportal, 6810, summa-summarum).

Alt styres via miljovariabler - ingen prosjektspesifikk kode. Samme image brukes av alle apper.

## Arkitektur

```
Docker Compose (per app)
    |
    +-- backup-container (safekeeper)
            |
            +-- pg_dump --> gzip --> GPG AES256 --> lokal fil (.sql.gz.gpg)
            |                                          |
            |                                          +-- SHA256 checksum (.sha256)
            |
            +-- SCP --> Hetzner StorageBox (offsite, EU)
            |              +-- SHA256-verifisering etter opplasting
            |              +-- Retry (3 forsok, eksponentiell backoff)
            |
            +-- cron (daglig schedule)
            +-- cleanup (retention lokalt + Hetzner)
```

**Baseimage:** `postgres:16-alpine` (gir tilgang til `pg_dump`, `pg_isready`, `psql`)

**Ekstra pakker:** bash, gzip, gnupg, openssh-client, tzdata

**Tidssone:** `Europe/Oslo`

### Filer

| Fil | Beskrivelse |
|-----|-------------|
| `backup-entrypoint.sh` | Hovedskript - backup, kryptering, opplasting, opprydding, cron |
| `restore.sh` | Gjenoppretting fra lokal backup-fil |
| `Dockerfile` | Docker-image basert pa postgres:16-alpine |

### Backup-flyt

1. Venter pa at PostgreSQL er klar (`pg_isready`)
2. `pg_dump` med `--no-owner --no-privileges --format=plain`
3. Komprimering med `gzip`
4. Kryptering med `gpg --symmetric --cipher-algo AES256`
5. Verifisering (dekrypterings-test av kryptert fil)
6. SHA256-checksum genereres
7. Opplasting til Hetzner StorageBox med checksum-verifisering
8. Opprydding av gamle backups (lokalt + Hetzner)

### Fil-backup (valgfritt)

Hvis `FILES_DIR` er satt, tas det ogsa backup av en filkatalog:
- `tar czf` --> GPG AES256 --> `.tar.gz.gpg`
- Samme opplastings- og oppryddingslogikk som database-backup

## Kommandoer

```bash
# Manuell backup (inne i container)
docker compose -f docker-compose.tunnel.yml exec backup /usr/local/bin/backup-entrypoint.sh backup

# List tilgjengelige backups
docker compose -f docker-compose.tunnel.yml exec backup restore.sh --list

# Gjenopprett fra fil
docker compose -f docker-compose.tunnel.yml exec backup restore.sh /backups/prosjekt_20260302_030000.sql.gz.gpg

# Se backup-logger
docker compose -f docker-compose.tunnel.yml logs backup

# Generer krypteringsnokkel
openssl rand -base64 32
```

## Miljovariabler

| Variabel | Beskrivelse | Default | Pakrevd |
|----------|-------------|---------|---------|
| `PROJECT_NAME` | Brukes i filnavn og logging | - | Ja |
| `DB_HOST` | Database-host | `postgres` | Nei |
| `DB_PORT` | Database-port | `5432` | Nei |
| `DB_NAME` | Databasenavn | `${PROJECT_NAME}` | Nei |
| `DB_USER` | Database-bruker | `${PROJECT_NAME}` | Nei |
| `DB_PASSWORD` | Database-passord | - | Ja |
| `BACKUP_DIR` | Lokal backup-katalog | `/backups` | Nei |
| `BACKUP_SCHEDULE` | Cron-uttrykk for automatisk backup | `0 5 * * *` | Nei |
| `BACKUP_RETENTION_DAYS` | Dager a beholde backups | `30` | Nei |
| `BACKUP_ENCRYPTION_KEY` | GPG-krypteringsnokkel (AES256) | - | Ja |
| `FILES_DIR` | Katalog for fil-backup (tom = deaktivert) | (tom) | Nei |
| `HETZNER_HOST` | Hetzner StorageBox hostname (tom = deaktivert) | (tom) | Nei |
| `HETZNER_USER` | Hetzner StorageBox brukernavn | (tom) | Nei |
| `HETZNER_PORT` | Hetzner SSH-port | `23` | Nei |
| `HETZNER_BACKUP_PATH` | Sti pa StorageBox | `backups/${PROJECT_NAME}` | Nei |

## Sikkerhet

### Obligatorisk kryptering

Kryptering er **pakrevd** - backup feiler med feilmelding hvis `BACKUP_ENCRYPTION_KEY` mangler. Det finnes ingen mulighet til a ta ukrypterte backups.

### Passordhandtering

- **Database-passord**: Overleveres via `.pgpass`-fil (`chmod 600`), ikke synlig i prosessliste (ungar `PGPASSWORD` miljovariabel)
- **GPG-passphrase**: Overleveres via file descriptor (`--passphrase-fd 3`), ikke synlig i `ps`
- **SSH-nokkel**: Kopieres til `mktemp`-fil med `chmod 600` (montert nokkel kan ha feil eierskap)

### Opprydding

Sensitive filer ryddes opp via `trap EXIT`:
- SSH-nokkel (mktemp-fil)
- `.pgpass`-fil (mktemp-fil)

### SSH

- `StrictHostKeyChecking=accept-new` (TOFU-modell - aksepterer nye nokler, avviser endrede)
- `BatchMode=yes` (ingen interaktive prompts)
- Port 23 (Hetzner StorageBox standard)

### Filpermisjon

- Alle backup-filer: `chmod 600`
- Alle checksum-filer: `chmod 600`
- `.pgpass`: `chmod 600`
- SSH-nokkel kopi: `chmod 600`

### Checksum-verifisering

- SHA256-checksum genereres for alle backup-filer
- Checksum verifiseres etter opplasting til Hetzner
- Restore verifiserer checksum automatisk hvis `.sha256`-fil finnes

### Krypteringsnokkel

```bash
# Generer nokkel
openssl rand -base64 32
```

**VIKTIG**: Lagre krypteringsnokkelen sikkert utenfor systemet! Uten nokkelen kan backups ikke dekrypteres. Anbefalte steder:
- Passordbehandler (Bitwarden, 1Password)
- Fysisk notat i safe
- Ikke kun i `.env` - den er pa samme server som backupene

## CI/CD

GitHub Actions (`build.yml`) kjorer automatisk ved push og pull request:

| Jobb | Verktoey | Beskrivelse |
|------|----------|-------------|
| ShellCheck | `ludeeus/action-shellcheck` | Linter alle bash-skript |
| Hadolint | `hadolint/hadolint-action` | Linter Dockerfile |
| Docker Build | `docker/build-push-action` | Verifiserer at image bygges (push: false) |

Docker Build kjorer forst etter at ShellCheck og Hadolint er godkjent (`needs: [shellcheck, hadolint]`).

GitHub Actions (`issue-notify.yml`) sender push-varsling ved nye issues:

| Jobb | Verktoey | Beskrivelse |
|------|----------|-------------|
| Issue-varsling | ntfy (selvhostet) | Sender push-varsel nar GitHub-issues apnes |

- Kategoriserer issues som BUG, FEATURE eller ISSUE basert pa nokkelord i tittel/body
- BUG-nokkelord: feil, bug, crash, error, virker ikke, broken, fix
- FEATURE-nokkelord: endre, legg til, ny, feature, forbedring, onske
- Issues med Lisa-label far hoy prioritet (priority 4) og stjernemerke
- Varsler sendes til `ntfy.tommytv.no/github` med klikkbar lenke til issuet

```bash
# Sjekk CI-status
gh run list --repo TommySkogstad/safekeeper --limit 5
```

## Konvensjoner

- **Obligatorisk kryptering**: Alle backups ma krypteres med GPG AES256. Aldri fjern dette kravet.
- **Ingen prosjektspesifikk kode**: Alt styres via miljovariabler. Ikke legg til logikk som er spesifikk for en enkelt app.
- **Norsk logging**: Alle loggmeldinger er pa norsk.
- **set -euo pipefail**: Alle skript bruker streng feilhandtering.
- **Healthcheck**: Containeren skriver `/tmp/last-backup-success` med timestamp ved vellykket backup. Healthcheck sjekker at siste backup var innen 26 timer (93600 sekunder).
- **Retry-logikk**: Hetzner-opplasting prover 3 ganger med eksponentiell backoff (5s, 10s, 20s).
- **Retention**: Gamle backups slettes automatisk bade lokalt og pa Hetzner etter `BACKUP_RETENTION_DAYS`.
- **Initial backup**: Ved oppstart kjores en backup umiddelbart for cron settes opp.
- **Linting**: ShellCheck for bash, Hadolint for Dockerfile. Begge ma passere i CI.

## Integrasjon med andre apper

Safekeeper brukes som `backup`-service i `docker-compose.tunnel.yml` (produksjon) i hver app. Typisk oppsett:

```yaml
backup:
  build:
    context: ../safekeeper
    dockerfile: Dockerfile
  restart: unless-stopped
  healthcheck:
    test: ["CMD-SHELL", "test -f /tmp/last-backup-success && [ $(($(date +%s) - $(cat /tmp/last-backup-success))) -lt 93600 ]"]
    interval: 60s
    timeout: 10s
    retries: 3
    start_period: 30s
  environment:
    PROJECT_NAME: mittprosjekt
    DB_HOST: postgres
    DB_PASSWORD: ${DB_PASSWORD:?Sett DB_PASSWORD i .env}
    BACKUP_ENCRYPTION_KEY: ${BACKUP_ENCRYPTION_KEY:?Sett BACKUP_ENCRYPTION_KEY i .env}
    BACKUP_SCHEDULE: ${BACKUP_SCHEDULE:-0 3 * * *}
    HETZNER_HOST: ${HETZNER_HOST:-}
    HETZNER_USER: ${HETZNER_USER:-}
    HETZNER_PORT: ${HETZNER_PORT:-23}
    HETZNER_BACKUP_PATH: ${HETZNER_BACKUP_PATH:-backups/mittprosjekt}
  volumes:
    - /mnt/nas-apps/mittprosjekt/backups:/backups
    - /home/bruker/.ssh/id_ed25519:/root/.ssh/id_ed25519:ro
  depends_on:
    postgres:
      condition: service_healthy
  networks:
    - internal
```

### Apper som bruker safekeeper

| App | NAS-sti | Hetzner StorageBox | Schedule |
|-----|---------|-------------------|----------|
| biologportal | `/mnt/nas-apps/biologportal/backups` | u554595 (Helsinki) | `0 3 * * *` |
| lo-finans | `/mnt/nas-apps/lo-finans/backups` | Venter pa opprettelse | `0 5 * * *` |
| 6810 | `/mnt/nas-apps/6810/backups` | Venter pa opprettelse | `0 5 * * *` |
| summa-summarum | `/mnt/nas-apps/summa-summarum/backups` | Venter pa opprettelse | `0 5 * * *` |

### Forutsetninger

- Safekeeper-repoet klones til `~/git/safekeeper` pa serveren
- Appen refererer til `../safekeeper` i Docker Compose `build.context`
- SSH-nokkel (`id_ed25519`) monteres som read-only volum
- NAS-katalog monteres som bind mount for `/backups`
- PostgreSQL-containeren ma ha healthcheck (safekeeper venter med `pg_isready`)
