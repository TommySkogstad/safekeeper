# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Prosjektoversikt

**Safekeeper** - Parametrisert Docker-image for automatisk PostgreSQL-backup med lokal lagring (NAS) og offsite-backup til Hetzner StorageBox (SSH/SCP). Brukes av alle Kotlin/Ktor-appene i portefoljen (biologportal, 6810, styreportal, smart-casual).

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

**Baseimage:** `postgres:16.14-alpine@sha256:16bc17c64a573ef34162af9298258d1aec548232985b33ed7b1eac33ba35c229` (gir tilgang til `pg_dump`, `pg_isready`, `psql`)

**Ekstra pakker:** bash, gzip, gnupg, openssh-client, tzdata

**Tidssone:** `Europe/Oslo`

### Filer

| Fil | Beskrivelse |
|-----|-------------|
| `backup-entrypoint.sh` | Hovedskript - backup, kryptering, opplasting, opprydding, cron |
| `restore.sh` | Gjenoppretting fra lokal backup-fil |
| `Dockerfile` | Docker-image basert pa postgres:16.14-alpine (pinnet til digest) |

### Backup-flyt

1. Venter pa at PostgreSQL er klar (`pg_isready`)
2. `pg_dump` med `--no-owner --no-privileges --format=plain`
3. Komprimering med `gzip`
4. Kryptering med `gpg --symmetric --cipher-algo AES256`
5. Minimumsstørrelse-validering (sikrer at backup-filen ikke er mistenkelig liten)
6. Verifisering (dekrypterings-test av kryptert fil)
7. SHA256-checksum genereres
8. Opplasting til Hetzner StorageBox med checksum-verifisering
9. Opprydding av gamle backups (lokalt + Hetzner)
10. Eventuell fil-backup (hvis `FILES_DIR` er satt) — samme operasjoner som ovenfor
11. Skriv `/tmp/last-backup-success` med timestamp (kun hvis BÅDE database-backup OG fil-backup er vellykkede)
12. Ved backup-feil: send proaktiv ntfy-varsling (hvis `NTFY_URL` er satt)

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
| `BACKUP_SCHEDULE` | Cron-uttrykk for automatisk backup (valideres ved oppstart — må ha 5 felt) | `0 5 * * *` | Nei |
| `BACKUP_RETENTION_DAYS` | Dager a beholde backups | `30` | Nei |
| `BACKUP_ENCRYPTION_KEY` | GPG-krypteringsnokkel (AES256) | - | Ja |
| `DB_WAIT_TIMEOUT` | Maks ventetid (sekunder) på PostgreSQL ved oppstart | `60` | Nei |
| `BACKUP_RETRY_MAX` | Maks antall Hetzner-opplastingsforsøk | `3` | Nei |
| `BACKUP_RETRY_DELAY` | Startverdien (sekunder) for eksponentiell backoff ved retry | `5` | Nei |
| `MIN_BACKUP_SIZE_BYTES` | Minimumsstørrelse (bytes) for backup-fil — fanger stille tomme dumps | `1024` | Nei |
| `FILES_DIR` | Katalog for fil-backup (tom = deaktivert) | (tom) | Nei |
| `HETZNER_HOST` | Hetzner StorageBox hostname (tom = deaktivert) | (tom) | Nei |
| `HETZNER_USER` | Hetzner StorageBox brukernavn | (tom) | Nei |
| `HETZNER_PORT` | Hetzner SSH-port | `23` | Nei |
| `HETZNER_BACKUP_PATH` | Sti pa StorageBox | `backups/${PROJECT_NAME}` | Nei |
| `NTFY_URL` | ntfy.sh-URL for proaktiv varsling ved backup-feil (tom = deaktivert) | (tom) | Nei |

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
- **Dato-ekstraksjon**: `cleanup_hetzner` bruker POSIX sed (ikke `grep -oP`), siden BusyBox grep i postgres:16.14-alpine ikke støtter Perl-regex

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

## Proaktiv varsling (ntfy)

Når `NTFY_URL` er konfigurert, sender safekeeper en ntfy-varsling umiddelbart ved backup-feil:

- **Trigger**: Backup-feil (database, fil-backup, eller offsite-opplasting)
- **Kanal**: ntfy.sh-URL (f.eks. `http://ntfy.tommytv.no/safekeeper` eller `https://ntfy.sh/mytopic`)
- **Innhold**: Feilmelding med projekt-navn, Priority=urgent, Tag=rotating_light (rødt lys emoji)
- **Hvis NTFY_URL er tom**: Ingen varsling sendes

Dette moegner operatoerer til a reagere raskt ved backup-problemer, i stedet for a stole pa manuelle sjekker eller healthcheck-timeouts.

## CI/CD

GitHub Actions (`build.yml`) kjorer automatisk ved push og pull request:

| Jobb | Verktoey | Beskrivelse |
|------|----------|-------------|
| ShellCheck | `ludeeus/action-shellcheck` | Linter alle bash-skript |
| Hadolint | `hadolint/hadolint-action` | Linter Dockerfile |
| BATS | `bats-core/bats-action` | Kjorer integrasjonstester |
| Docker Build | `docker/build-push-action` | Verifiserer at image bygges (push: false) |

Docker Build kjorer forst etter at ShellCheck, Hadolint og BATS er godkjent (`needs: [shellcheck, hadolint, bats]`).

**Dependabot**: Konfigurert i `.github/dependabot.yml` for automatisk oppdatering av GitHub Actions (ukentlig, mandag 08:00) med auto-merge pga. auto-merge-policyen.

GitHub Actions (`issue-notify.yml`) sender push-varsling ved nye issues:

| Jobb | Verktoey | Beskrivelse |
|------|----------|-------------|
| Issue-varsling | ntfy (selvhostet) | Sender push-varsel nar GitHub-issues apnes |

- Kategoriserer issues som BUG, FEATURE eller ISSUE basert pa nokkelord i tittel/body
- BUG-nokkelord: feil, bug, crash, error, virker ikke, broken, fix
- FEATURE-nokkelord: endre, legg til, ny, feature, forbedring, onske
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
- **Eksplisitte advarsler ved kritiske operasjoner**: Operasjoner som `mkdir`, `rm`, `find -delete` og checksum-verifikasjoner må aldri silently feile med `|| true`. I stedet: logg `ADVARSEL` med kontekst og returner feilkode. Eksempler: mkdir som mislykkes skal sjekke `test -d` og advare hvis både create og verify feiler; rm som mislykkes skal advare om rettigheter; find som mislykkes skal advare om disk-problemer.
- **Healthcheck**: Containeren skriver `/tmp/last-backup-success` med timestamp når BÅDE database-backup og fil-backup (hvis konfigurert) er vellykkede. Healthcheck-vinduet (antall sekunder siden siste vellykkede backup) styres av consumer-appens docker-compose og er ikke en safekeeper-variabel — typisk 93600 (26 timer).
- **Retry-logikk**: Hetzner-opplasting prover `BACKUP_RETRY_MAX` ganger (default 3) med eksponentiell backoff (startverdi `BACKUP_RETRY_DELAY` sekunder, default 5s).
- **Retention**: Gamle backups slettes automatisk bade lokalt og pa Hetzner etter `BACKUP_RETENTION_DAYS`.
- **Initial backup**: Ved oppstart kjores en backup umiddelbart for cron settes opp.
- **Linting**: ShellCheck for bash, Hadolint for Dockerfile. Begge ma passere i CI.
- **Integrasjonstester**: BATS-tester for `backup-entrypoint.sh` og `restore.sh`. Se `tests/README.md` for detaljer og kjøring av tester lokalt.

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
| biologportal | `/mnt/nas-apps/biologportal/backups` | u554595 (Helsinki) | `50 1 * * *` |
| 6810 | `/mnt/nas-apps/6810/backups` | Venter pa opprettelse | `0 2 * * *` |
| styreportal | `/mnt/nas-apps/styreportal/backups` | Venter pa opprettelse | `30 1 * * *` |
| maskemester | `/mnt/nas-apps/maskemester/backups` | Ikke satt opp | `0 5 * * *` |
| vinforalle | `/mnt/nas-apps/vinforalle/backups` | Ikke satt opp | `0 5 * * *` |
| smart-casual | — | — | Ikke konfigurert |

### Kryssrepo-avhengigheter

Safekeeper er et delt bibliotek/image som brukes av alle Kotlin-appene. Naar ny funksjonalitet legges til, opprett GitHub issue paa safekeeper FORST, deretter issues paa alle apper som skal bruke endringen med `Blokkert av: TommySkogstad/safekeeper#nummer` i issue-bodyen. Issue-triage haandterer avhengighetsrekkefoelgen automatisk.

### Forutsetninger

- Safekeeper-repoet klones til `~/git/safekeeper` pa serveren
- Appen refererer til `../safekeeper` i Docker Compose `build.context`
- SSH-nokkel (`id_ed25519`) monteres som read-only volum
- NAS-katalog monteres som bind mount for `/backups`
- PostgreSQL-containeren ma ha healthcheck (safekeeper venter med `pg_isready`)
