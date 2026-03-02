# Safekeeper

Parametrisert Docker-image for PostgreSQL-backup med:
- Lokal backup (NAS via bind mount)
- Offsite backup til Hetzner StorageBox (SSH/SCP)
- GPG-kryptering (AES256)
- Automatisk opprydding (retention)
- Restore-funksjonalitet

Alt styres via miljovariabler - ingen prosjektspesifikk kode.

## Miljøvariabler

| Variabel | Beskrivelse | Default | Påkrevd |
|----------|-------------|---------|---------|
| `PROJECT_NAME` | Brukes i filnavn og logging | - | Ja |
| `DB_HOST` | Database-host | `postgres` | Nei |
| `DB_PORT` | Database-port | `5432` | Nei |
| `DB_NAME` | Databasenavn | `${PROJECT_NAME}` | Nei |
| `DB_USER` | Database-bruker | `${PROJECT_NAME}` | Nei |
| `DB_PASSWORD` | Database-passord | - | Ja |
| `BACKUP_DIR` | Lokal backup-katalog | `/backups` | Nei |
| `BACKUP_SCHEDULE` | Cron-uttrykk | `0 5 * * *` | Nei |
| `BACKUP_RETENTION_DAYS` | Dager a beholde backups | `30` | Nei |
| `BACKUP_ENCRYPTION_KEY` | GPG-krypteringsnokkel | (tom = ingen) | Nei |
| `HETZNER_HOST` | Hetzner StorageBox hostname | (tom = deaktivert) | Nei |
| `HETZNER_USER` | Hetzner StorageBox brukernavn | (tom) | Nei |
| `HETZNER_PORT` | Hetzner SSH-port | `23` | Nei |
| `HETZNER_BACKUP_PATH` | Sti pa StorageBox | `backups/${PROJECT_NAME}` | Nei |

## Bruk i docker-compose

```yaml
backup:
  build:
    context: ../safekeeper
    dockerfile: Dockerfile
  restart: unless-stopped
  healthcheck:
    test: ["CMD-SHELL", "pgrep -f backup-entrypoint || exit 1"]
    interval: 60s
    timeout: 10s
    retries: 3
    start_period: 30s
  environment:
    PROJECT_NAME: mittprosjekt
    DB_HOST: postgres
    DB_PORT: 5432
    DB_NAME: ${DB_NAME:-mittprosjekt}
    DB_USER: ${DB_USER:-mittprosjekt}
    DB_PASSWORD: ${DB_PASSWORD:?Sett DB_PASSWORD i .env}
    BACKUP_RETENTION_DAYS: ${BACKUP_RETENTION_DAYS:-30}
    BACKUP_SCHEDULE: ${BACKUP_SCHEDULE:-0 3 * * *}
    BACKUP_DIR: /backups
    BACKUP_ENCRYPTION_KEY: ${BACKUP_ENCRYPTION_KEY:-}
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

## Hetzner StorageBox oppsett

### 1. Bestill StorageBox

Bestill en Hetzner StorageBox (f.eks. BX11) fra [hetzner.com/storage/storage-box](https://www.hetzner.com/storage/storage-box).

### 2. Aktiver SSH-tilgang

1. Logg inn pa [Hetzner Robot](https://robot.hetzner.com/)
2. Ga til **Storage Box** → **Settings**
3. Aktiver **SSH support** (External reachability)
4. Merk: SSH bruker port **23** (ikke 22)

### 3. Legg til SSH-nokkel

```bash
# Kopier din offentlige nokkel til StorageBox
ssh-copy-id -p 23 -s uXXXXXX@uXXXXXX.your-storagebox.de
```

### 4. Test tilkobling

```bash
ssh -p 23 uXXXXXX@uXXXXXX.your-storagebox.de ls
```

### 5. Konfigurer miljovariabler

Legg til i `.env`:

```bash
HETZNER_HOST=uXXXXXX.your-storagebox.de
HETZNER_USER=uXXXXXX
HETZNER_PORT=23
HETZNER_BACKUP_PATH=backups/mittprosjekt
```

## Manuell backup

```bash
docker compose -f docker-compose.tunnel.yml exec backup /usr/local/bin/backup-entrypoint.sh backup
```

## Gjenoppretting

```bash
# List tilgjengelige backups
docker compose -f docker-compose.tunnel.yml exec backup restore.sh --list

# Gjenopprett fra fil
docker compose -f docker-compose.tunnel.yml exec backup restore.sh /backups/mittprosjekt_20260302_030000.sql.gz.gpg
```

## Kryptering

Generer nokkel:
```bash
openssl rand -base64 32
```

Sett `BACKUP_ENCRYPTION_KEY` i `.env`. Lagre nokkelen sikkert utenfor systemet!
