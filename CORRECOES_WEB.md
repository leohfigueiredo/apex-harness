# Correções aplicadas — 2026-09-18

Backup dos originais: `backups/ANTES_DA_CORRECAO_WEB_2026-09-18_132813`

## Ficheiros alterados

- `apex_harness/server.py` — 475 linhas alteradas
- `apex_harness/core.py` — 97 linhas alteradas
- `apex_harness/web/app.js` — 22 linhas alteradas
- `apex_harness/cli.py` — import em falta (`Optional`)

## Reverter
```bash
cd ~/apex_harness
BK=$(head -1 backups/QUAL_E_O_ULTIMO_BACKUP.txt)
cp "$BK/server.py" apex_harness/server.py
cp "$BK/core.py"   apex_harness/core.py
cp "$BK/app.js"    apex_harness/web/app.js
```
