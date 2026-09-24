#!/usr/bin/env bash
# reiniciar_web.sh — arranca o servidor web do Apex Harness de forma limpa.
#
# NOTA: nunca usar `pkill -f` nem um ciclo `kill` que corresponda a um padrao
# presente na propria linha de comando -- isso mata a shell que o executa. Aqui
# o PID e guardado num ficheiro e morto explicitamente.
set -uo pipefail
ROOT="/home/leonardo/apex_harness"
PIDF="/tmp/apex_web.pid"
PORT="${APEX_WEB_PORT:-7860}"
PY="/home/leonardo/.pyenv/versions/3.12.9/bin/python3"

# --- parar a instancia anterior (pelo PID guardado) -------------------------
if [[ -f "$PIDF" ]]; then
    OLD="$(cat "$PIDF" 2>/dev/null || true)"
    if [[ -n "$OLD" ]] && kill -0 "$OLD" 2>/dev/null; then
        kill -9 "$OLD" 2>/dev/null && echo "  parado pid $OLD"
    fi
    rm -f "$PIDF"
fi
sleep 1

# --- arrancar ---------------------------------------------------------------
cd "$ROOT"
PYTHONPATH="$ROOT" PYTHONDONTWRITEBYTECODE=1 APEX_WEB_PORT="$PORT" \
    setsid "$PY" -m apex_harness.server > "$ROOT/benchmarks/resultados/web_final.log" 2>&1 &
NEW=$!
echo "$NEW" > "$PIDF"

for _ in $(seq 1 40); do
    curl -sf "http://127.0.0.1:$PORT/api/project" >/dev/null 2>&1 && break
    kill -0 "$NEW" 2>/dev/null || { echo "  !! morreu"; tail -20 "$ROOT/benchmarks/resultados/web_final.log"; exit 1; }
    sleep 1
done

echo "  servidor web pid $NEW em http://127.0.0.1:$PORT"
