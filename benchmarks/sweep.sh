#!/usr/bin/env bash
# sweep.sh — A/B benchmark runner for Apex Harness llama-server configurations.
#
# Starts llama-server with a given flag set, waits for readiness, runs
# apex_bench.py against it, then tears the server down. Results are appended to
# bench/results/sweep.csv so configurations can be compared directly.
#
# Usage:
#   bench/sweep.sh <path-to.gguf> [extra llama-server args...]
#   bench/sweep.sh model.gguf --label baseline
#   bench/sweep.sh model.gguf --label tuned -t 12 --cpu-mask 0x0f0f
#
# Environment:
#   APEX_PORT       default 8080
#   APEX_PROMPTS    default "512 4096"
#   APEX_GEN        default "256"
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
LLAMA_SERVER="${LLAMA_SERVER:-$HOME/.local/bin/llama-server}"
PORT="${APEX_PORT:-8080}"
PROMPTS="${APEX_PROMPTS:-512 4096}"
GEN="${APEX_GEN:-256}"
RESULTS="$HERE/resultados"
mkdir -p "$RESULTS"

MODEL="${1:-}"; shift || true
if [[ -z "$MODEL" || ! -f "$MODEL" ]]; then
    echo "usage: $0 <model.gguf> [llama-server args...]" >&2
    exit 2
fi

LABEL="sweep"
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

LOG="/tmp/apex-sweep-$PORT.log"
echo "=== [$LABEL] starting llama-server ==="
echo "    model: $(basename "$MODEL")"
echo "    args : ${ARGS[*]:-<defaults>}"

# shellcheck disable=SC2086
"$LLAMA_SERVER" -m "$MODEL" --host 127.0.0.1 --port "$PORT" \
    --alias llama-local-model "${ARGS[@]}" > "$LOG" 2>&1 &
SRV=$!
trap 'kill -9 $SRV 2>/dev/null' EXIT

# ---- wait for readiness -------------------------------------------------- #
for _ in $(seq 1 900); do
    if ! kill -0 "$SRV" 2>/dev/null; then
        echo "!!! server died; tail of log:"; tail -30 "$LOG"; exit 1
    fi
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
    sleep 1
done

if ! curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "!!! server never became ready; tail of log:"; tail -30 "$LOG"; exit 1
fi

# Record the effective runtime parameters llama.cpp actually chose.
{
    echo "--- effective config for [$LABEL] ---"
    grep -iE "n_threads|n_threads_batch|cpu_mask|cpu_strict|n_gpu_layers|offloaded|flash_attn|n_ctx|n_batch|n_ubatch|type_k|type_v|mmap|mlock|KQ|V cache|CPU_MASK|CU_MASK|no_kv_offload|spec|draft" "$LOG" | head -40
} > "$RESULTS/$LABEL.config.txt" 2>/dev/null

# ---- measure ------------------------------------------------------------- #
echo "=== [$LABEL] benchmarking ==="
python3 "$HERE/apex_bench.py" \
    --url "http://127.0.0.1:$PORT/v1" \
    --label "$LABEL" \
    --port "$PORT" \
    --prompt-tokens $PROMPTS \
    --gen-tokens $GEN \
    --csv "$RESULTS/sweep.csv" \
    --json "$RESULTS/$LABEL.json"

echo "=== [$LABEL] effective config ==="
cat "$RESULTS/$LABEL.config.txt"

kill -9 $SRV 2>/dev/null
wait $SRV 2>/dev/null
echo "=== [$LABEL] done (log: $LOG) ==="
