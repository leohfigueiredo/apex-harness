#!/usr/bin/env bash
# comparar_atalhos.sh — A/B entre as flags do atalho ORIGINAL e do OTIMIZADO.
#
# Mede exatamente o que cada atalho produz, no estado ATUAL da maquina
# (carve-out UMA de 0.5 GiB), com o mesmo modelo e as mesmas condicoes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRV="$HOME/.local/bin/llama-server"
PORT=8090
M="${1:?uso: comparar_atalhos.sh <modelo.gguf>}"
RES="$HERE/resultados"
mkdir -p "$RES"
bash -c "cat '$M' > /dev/null" 2>/dev/null || true

run() {
    local label="$1"; shift
    local log="$RES/atalho-$label.log"
    setsid "$@" > "$log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 600); do
        curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break
        kill -0 "$pid" 2>/dev/null || { echo "!! $label morreu"; tail -15 "$log"; return 1; }
        sleep 1
    done
    for _ in 1 2 3; do
        curl -s "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
            -d '{"model":"llama-local-model","messages":[{"role":"user","content":"hi"}],"max_tokens":16,"temperature":0}' >/dev/null
    done
    echo "===== $label ====="
    grep -E "n_threads =|listening" "$log" | head -2 | sed 's/^/   /'
    python3 "$HERE/apex_bench.py" --url "http://127.0.0.1:$PORT/v1" --port "$PORT" \
        --label "$label" --prompt-tokens 512 --gen-tokens 256 \
        --json "$RES/atalho-$label.json" 2>&1 | grep -E "^ *\[|best"
    kill -9 -- "-$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" 2>/dev/null || kill -9 "$pid" 2>/dev/null
    sleep 3
}

# ---- ORIGINAL: exatamente o que o atalho antigo produz ---------------------
run ORIGINAL \
    taskset -c 0-7 "$SRV" -m "$M" --host 0.0.0.0 --port $PORT \
    -ngl 99 -c 32768 -np 1 -fa on -b 1024 -ub 512 --temp 0.3 -n 16384 \
    -ctk q4_0 -ctv q4_0 --cache-reuse 64 -sps 0.50 --alias llama-local-model \
    -md /usr/share/ollama/.ollama/models/blobs/sha256-29d8c98fa6b098e200069bfb88b9508dc3e85586d20cba59f8dda9a808165104 \
    -ngld 99 --spec-draft-n-max 5 --spec-draft-n-min 2

# ---- OTIMIZADO: exatamente o que o atalho novo produz ----------------------
run OTIMIZADO \
    "$SRV" -m "$M" --host 127.0.0.1 --port $PORT \
    -t 12 -tb 12 --cpu-mask 0xFFF --cpu-strict 1 -ngl 0 -c 32768 -np 1 -fa on \
    -ctk q8_0 -ctv q8_0 -b 2048 -ub 512 --cache-reuse 256 -sps 0.50 \
    --spec-type ngram-simple --timeout 3600 --no-webui --metrics \
    -n 16384 --alias llama-local-model

echo
echo "############ RESULTADO ############"
python3 - "$RES" <<'PY'
import json, sys, pathlib
rows = {}
for f in pathlib.Path(sys.argv[1]).glob("atalho-*.json"):
    d = json.loads(f.read_text())
    for r in d.get("results", []):
        if not r.get("error"):
            rows[r["label"]] = (r.get("srv_prompt_tps", 0), r.get("srv_predicted_tps", 0))
if not rows:
    print("  (sem resultados)"); raise SystemExit
print(f"  {'atalho':<12}{'prefill t/s':>13}{'decode t/s':>12}")
for k, (p, d) in rows.items():
    print(f"  {k:<12}{p:>13.2f}{d:>12.2f}")
if "ORIGINAL" in rows and "OTIMIZADO" in rows:
    po, do = rows["ORIGINAL"]; pn, dn = rows["OTIMIZADO"]
    print()
    if do > 0:
        print(f"  OTIMIZADO vs ORIGINAL:  decode {dn/do:.2f}x   prefill {pn/po:.2f}x" if po > 0 else "")
PY
