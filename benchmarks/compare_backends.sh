#!/usr/bin/env bash
# compare_backends.sh — clean back-to-back CPU vs Vulkan decode comparison.
#
# NOTE ON PROCESS MANAGEMENT: this script deliberately never uses `pkill -f` or
# `grep <pattern>` on a pattern that also appears in its own command line. Doing
# so matches the harness's own shell and kills it (SIGKILL). PIDs are passed
# explicitly instead. This is the same class of bug as launcher.py:101.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRV="$HOME/.local/bin/llama-server"
PORT="${APEX_PORT:-8095}"
M="${1:?usage: compare_backends.sh <model.gguf>}"
RES="$HERE/resultados"
mkdir -p "$RES"

cat "$M" > /dev/null || true     # prewarm page cache

PIDFILE="/tmp/apex-cmp-${PORT}.pid"

stop_server() {
    if [[ -f "$PIDFILE" ]]; then
        local p; p="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
            kill -9 -- "-$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')" 2>/dev/null || kill -9 "$p" 2>/dev/null
        fi
        rm -f "$PIDFILE"
    fi
    sleep 2
}

start_and_measure() {
    local label="$1"; shift
    stop_server
    local log="/tmp/apex-cmp-$label.log"
    setsid "$SRV" -m "$M" --host 127.0.0.1 --port "$PORT" "$@" > "$log" 2>&1 &
    echo $! > "$PIDFILE"

    local ready=0
    for _ in $(seq 1 600); do
        if curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then ready=1; break; fi
        sleep 1
    done
    [[ "$ready" == 1 ]] || { echo "!!! $label failed to start"; tail -20 "$log"; return 1; }

    # Warmup is MANDATORY for Vulkan: the first request compiles pipelines and
    # would otherwise be charged to TTFT (observed: 87 s for a 512-token prompt).
    for _ in 1 2 3; do
        curl -s "http://127.0.0.1:$PORT/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            -d '{"model":"llama-local-model","messages":[{"role":"user","content":"hi"}],"max_tokens":16,"temperature":0}' >/dev/null
    done

    echo "--- $label ---"
    grep -iE "n_threads =|n_gpu_layers|offloaded|Flash Attention|resolve_fused_ops|type_k|type_v|ngram|spec" "$log" | head -12
    python3 "$HERE/apex_bench.py" \
        --url "http://127.0.0.1:$PORT/v1" --port "$PORT" --label "$label" \
        --prompt-tokens 512 4096 --gen-tokens 256 --json "$RES/$label.json"
    stop_server
}

COMMON=(-t 12 -tb 12 --cpu-mask 0xFFF --cpu-strict 1 -c 32768 -np 1 -fa on
        -ctk q8_0 -ctv q8_0 -b 2048 -ub 512 --cache-reuse 256 -sps 0.50
        --timeout 3600 --no-webui --metrics --alias llama-local-model)

start_and_measure "cpu_ngl0"    -ngl 0   "${COMMON[@]}" --spec-type ngram-simple
start_and_measure "vulkan_ngl999" -ngl 999 "${COMMON[@]}" --spec-type ngram-simple
start_and_measure "vulkan_nospec" -ngl 999 "${COMMON[@]}"

echo
echo "############ SUMMARY ############"
python3 - "$RES" <<'PY'
import json, sys, pathlib
rows = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    d = json.loads(f.read_text())
    for r in d.get("results", []):
        if r.get("error"):
            continue
        rows.append((r["label"], r["prompt_tokens"], r["srv_prefill_tps"] if "srv_prefill_tps" in r else r.get("srv_prompt_tps", 0), r.get("srv_predicted_tps", 0), r.get("effective_bw_gbs", 0)))
print(f"{'label':<20}{'pp':>7}{'prefill t/s':>13}{'decode t/s':>12}{'BW GB/s':>10}")
for lbl, pp, pre, dec, bw in rows:
    print(f"{lbl:<20}{pp:>7}{pre:>13.2f}{dec:>12.2f}{bw:>10.1f}")
PY
