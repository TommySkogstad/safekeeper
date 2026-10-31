# Kilder til figurene i README

Figurene i `docs/visuelt/` er rendret fra sidene her med skillen `visuell-dokumentasjon`
(i misc-scripts). Endre kilden og render på nytt; ikke rediger GIF-ene direkte.

| Kilde | Gir | Avledet fra |
|-------|-----|-------------|
| `backupkjeden.html` | `backupkjeden.gif`, `-mork.gif`, `.mp4`, `.png` (hovedfiguren i README) | `backup-entrypoint.sh`, `Dockerfile` |

Render på nytt fra repo-rota (skriptet ligger i misc-scripts-repoet):

```bash
<misc-scripts>/skills/visuell-dokumentasjon/templates/render-gif.sh \
  docs/visuelt/kilder/backupkjeden.html docs/visuelt/backupkjeden
```

Stillbilder først (legges i `docs/visuelt/backupkjeden-test/`, ikke commit):
legg til `--test=5.8,10`. Åpne HTML-fila i en nettleser for å se animasjonen spille.
