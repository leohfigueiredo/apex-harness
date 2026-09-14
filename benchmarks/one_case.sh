#!/usr/bin/env bash
# one_case.sh — corre UMA configuração de llama-server e mede-a.
#
# Serve para isolar variáveis entre dois comandos que deviam ser equivalentes.
#
#   bench/one_case.sh <label> <modelo.gguf> [args extra do llama-server...]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRV="${LLAMA_SERVER:-$HOME/.local/bin/llama-server}"
PORT="${APEX_PORT:-8090}"
LABEL="$1"; shift
M="$1"; shift
LOG="$HERE/resultados/exact-$LABEL.log"
PIDF="/tmp/one_case_$LABEL.pid"

bash -c "cat '$M' > /dev/null" 2>/dev/null || true

setsid "$SRV" -m "$M" --host 127.0.0.1 --port "$PORT" "$@" > "$LOG" 2>&1 &
echo $! > "$PIDF"
PID=$(cat "$PIDF")

for _ in $(seq 1 600); do
    curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break
    kill -0 "$PID" 2>/dev/null || { echo "!! morreu"; tail -20 "$LOG"; exit 1; }
    sleep 1
done

# warmup obrigatorio (Vulkan compila pipelines na 1a request)
for _ in 1 2 3; do
    curl -s "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
        -d '{"model":"llama-local-model","messages":[{"role":"user","content":"hi"}],"max_tokens":16,"temperature":0}' >/dev/null
done

echo "===== $LABEL ====="
echo "CMD: $SRV -m $M --host 127.0.0.1 --port $PORT $*"
grep -E "n_threads =|listening|n_ctx_slot" "$LOG" | head -3
python3 "$HERE/apex_bench.py" --url "http://127.0.0.1:$PORT/v1" --port "$PORT" --label "$LABEL" \
    --prompt-tokens 512 --gen-tokens 256 --json "$HERE/resultados/$LABEL.json" 2>&1 | grep -E "^ *\[|best"

kill -9 -- "-$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ')" 2>/dev/null || kill -9 "$PID" 2>/dev/null
sleep 2
