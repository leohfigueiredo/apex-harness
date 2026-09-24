#!/usr/bin/env bash
# Mede decode/prefill reais dos MoE candidatos, com as mesmas flags.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRV="$HOME/.local/bin/llama-server"
PORT=8093
RES="$HERE/resultados"; mkdir -p "$RES"
COMMON=(-t 12 -tb 12 --cpu-mask 0xFFF --cpu-strict 1 -c 32768 -np 1 -fa on
        -ctk q8_0 -ctv q8_0 -b 2048 -ub 512 --cache-reuse 256 -sps 0.50
        --timeout 3600 --no-webui --metrics -n 4096 --alias llama-local-model)
medir() {
  local rot="$1"; shift; local m="$1"; shift
  echo; echo "########## $rot"
  local log="$RES/cand-$rot.log"
  setsid "$SRV" -m "$m" --host 127.0.0.1 --port $PORT -ngl 999 "${COMMON[@]}" "$@" > "$log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 400); do kill -0 $pid 2>/dev/null || break; curl -sf -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 1; done
  if ! curl -sf -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then echo "  !! nao subiu"; tail -6 "$log"|sed 's/^/    /'; kill -9 -- "-$(ps -o pgid= -p $pid|tr -d ' ')" 2>/dev/null; return; fi
  for _ in 1 2 3; do curl -s -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model":"llama-local-model","messages":[{"role":"user","content":"hi"}],"max_tokens":8,"temperature":0}' >/dev/null 2>&1; done
  awk '{printf "  VRAM: %.2f GiB\n", $1/1073741824}' /sys/class/drm/card1/device/mem_info_vram_used
  /home/leonardo/apex_harness/.venv/bin/python "$HERE/apex_bench.py" --url "http://127.0.0.1:$PORT/v1" --port $PORT \
      --label "$rot" --prompt-tokens 512 --gen-tokens 128 --json "$RES/cand-$rot.json" 2>&1 | grep -E "^ *\[|best " | sed 's/^/  /'
  kill -9 -- "-$(ps -o pgid= -p $pid|tr -d ' ')" 2>/dev/null || kill -9 $pid 2>/dev/null; sleep 4
}
A=/run/media/leonardo/Windows/AIModels
medir "gemma4-26B-A4B" "$A/lmstudio-community/gemma-4-26B-A4B-it-QAT-GGUF/gemma-4-26B-A4B-it-QAT-Q4_0.gguf"
medir "nemotron-30B-A3B" "$A/lmstudio-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-Q4_K_M.gguf"
medir "qwen3-coder-30B-A3B" "$A/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf"
