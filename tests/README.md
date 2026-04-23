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
    common.bash              # Felles oppsett (SAFEKEEPER_ROOT osv.)
  check_requirements.bats    # Tester for manglende miljøvariabler
```

Flere testfiler, stub-binærer for `gpg`/`pg_dump`/`scp`/`ssh` og CI-integrasjon legges til i oppfølgende issues (se #4).
