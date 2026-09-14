#!/usr/bin/env bash
# ab_test.sh — A/B/C comparison of llama-server configurations for Apex Harness.
#
# Deliberately avoids `pkill -f`: pattern-based killing matches the harness's own
# command line and can also kill unrelated llama-server instances (LM Studio,
# another agent). We track PIDs explicitly instead.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRV="${LLAMA_SERVER:-$HOME/.local/share/llama.cpp/llama-b10456/llama-server}"
PORT="${APEX_PORT:-8090}"
M="${1:?usage: ab_test.sh <model.gguf>}"
mkdir -p "$HERE/resultados"

# Prewarm into page cache so we measure compute, not NTFS/HDD read speed.
echo "[prewarm] $M"
cat "$M" > /dev/null || true

SERVER_PID=""
SERVER_PGID=""
cleanup() {
    # Kill the whole PROCESS GROUP: `setsid` gives each server its own group, so
    # this reaps the server even when it was reached through taskset/env wrappers.
    if [[ -n "$SERVER_PGID" ]]; then
        kill -9 -"$SERVER_PGID" 2>/dev/null || true
        SERVER_PGID=""
    fi
}
trap cleanup EXIT INT TERM

run_case() {
    local label="$1"; shift
    local log="/tmp/apex-ab-$label.log"
    echo
    echo "##################### $label #####################"
    printf 'CMD: %s\n' "$*"

    cleanup
    SERVER_PID=""

    # setsid -> new session/process group; run through bash -c because the case
    # is a multi-line command string, not an argv vector.
    setsid bash -c "$*" > "$log" 2>&1 &
    SERVER_PID=$!
    SERVER_PGID="$SERVER_PID"          # setsid makes pid == pgid

    # llama-server's /health can answer 200 while the model is still loading, and
    # /props only exists at the ROOT (not under /v1). Poll /v1/models: it only
    # responds once weights are in place.
    local ready=0
    for _ in $(seq 1 1800); do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "!!! server died during load. tail:"; tail -25 "$log"; cleanup; SERVER_PID=""; return 1
        fi
        if curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then ready=1; break; fi
        sleep 1
    done
    if [[ "$ready" != 1 ]]; then
        echo "!!! not ready in 1800s. tail:"; tail -25 "$log"; cleanup; SERVER_PID=""; return 1
    fi

    echo "--- effective runtime params (from server log) ---"
    grep -iE "n_threads|n_threads_batch|n_gpu_layers|offloaded|flash_attn|n_ctx |n_batch|n_ubatch|type_k|type_v|mmap|mlock|cpu_mask|draft|spec|load_tensors" "$log" | head -40
    echo "--- measured ---"
    python3 "$HERE/apex_bench.py" \
        --url "http://127.0.0.1:$PORT/v1" --port "$PORT" --label "$label" \
        --prompt-tokens 512 4096 --gen-tokens 256 \
        --csv "$HERE/resultados/sweep.csv" --json "$HERE/resultados/$label.json"
    local rc=$?
    cleanup; SERVER_PID=""
    sleep 2
    return $rc
}

# ---------------------------------------------------------------- CASES -----
# Each case_* function PRINTS the command line to run. run_case executes it via
# `setsid bash -c` so the whole server process group can be reaped afterwards.

# CASE A - Exactly what launcher_common.launch_llama_server() does today:
#   taskset -c 0-7 (spans Zen5 + Zen5c!), ROCm env vars the Vulkan binary
#   ignores, LD_PRELOAD of libdrm, q4_0 KV, -b 1024, no explicit -t.
case_a() {
    cat <<EOF
taskset -c 0-7 env HSA_OVERRIDE_GFX_VERSION=11.5.0 HSA_ENABLE_SDMA=0 HIP_VISIBLE_DEVICES=0 \\
  AMD_GPU_BUILD_TARGET=gfx1150 LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libdrm_amdgpu.so.1 \\
  RADV_PERFTEST=coop_matrix,nogttspill AMD_VULKAN_ICD=RADV \\
  "$SRV" -m "$M" --host 127.0.0.1 --port $PORT \\
  -ngl 99 -c 32768 -np 1 -fa on -b 1024 -ub 512 \\
  --temp 0.3 -n 16384 -ctk q4_0 -ctv q4_0 --cache-reuse 64 -sps 0.50 \\
  --alias llama-local-model
EOF
}

# CASE B - Fix affinity: no taskset, explicit -t 12 across all 12 physical cores,
# drop the dead ROCm env and the LD_PRELOAD, q8_0 KV, -b 2048.
case_b() {
    cat <<EOF
"$SRV" -m "$M" --host 127.0.0.1 --port $PORT \\
  -ngl 99 -c 32768 -np 1 -fa on -b 2048 -ub 512 -t 12 \\
  --temp 0.3 -n 16384 -ctk q8_0 -ctv q8_0 --alias llama-local-model
EOF
}

# CASE C - Restricted to the 4 fast Zen 5 cores + their SMT siblings (0-3,12-15),
# vs B's 12 physical cores. Isolates the hybrid-core effect.
case_c() {
    cat <<EOF
"$SRV" -m "$M" --host 127.0.0.1 --port $PORT \\
  -ngl 99 -c 32768 -np 1 -fa on -b 2048 -ub 512 \\
  -t 8 --cpu-mask 0x0f0f --cpu-strict 1 \\
  --temp 0.3 -n 16384 -ctk q8_0 -ctv q8_0 --alias llama-local-model
EOF
}

# CASE D - Pure CPU baseline, explicit 12 threads, no GPU offload at all.
case_d() {
    cat <<EOF
"$SRV" -m "$M" --host 127.0.0.1 --port $PORT \\
  -ngl 0 -c 32768 -np 1 -fa on -b 2048 -ub 512 -t 12 \\
  --temp 0.3 -n 16384 -ctk q8_0 -ctv q8_0 --alias llama-local-model
EOF
}

run_case "A_current_launcher" "$(case_a)"
run_case "B_t12_ngl99"        "$(case_b)"
run_case "C_zen5_only_0f0f"   "$(case_c)"
run_case "D_cpu_t12_ngl0"     "$(case_d)"

echo
echo "############ SUMMARY ############"
if [[ -f "$HERE/resultados/sweep.csv" ]]; then
    column -s, -t "$HERE/resultados/sweep.csv" 2>/dev/null | cut -c1-200 || cat "$HERE/resultados/sweep.csv"
fi
