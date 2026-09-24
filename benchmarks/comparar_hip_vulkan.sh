#!/usr/bin/env bash
# comparar_hip_vulkan.sh — mede ROCm/HIP vs Vulkan no MESMO modelo e com as
# MESMAS flags, para decidires com numeros em vez de opiniao.
#
# Nao compila nada se ja existir um build HIP utilizavel. Nao toca na BIOS,
# nao instala pacotes, nao altera configuracao nenhuma.
#
# Corre no TEU terminal:
#   bash ~/apex_harness/benchmarks/comparar_hip_vulkan.sh [modelo.gguf]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${APEX_HIP_PORT:-8092}"
RES="$HERE/resultados"
mkdir -p "$RES"

ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; }
warn() { echo "  ⚠  $*"; }
info() { echo "  →  $*"; }
step() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }

# ---------------------------------------------------------------- modelo ----
MODEL="${1:-}"
if [[ -z "$MODEL" ]]; then
    for c in \
      "$HOME/.lmstudio/models/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf" \
      "/mnt/HDD/AIModels/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf" \
      "$HOME/.lmstudio/models/lmstudio-community/Qwen2.5-Coder-7B-Instruct-GGUF/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf" \
      "/mnt/HDD/AIModels/lmstudio-community/Qwen2.5-Coder-7B-Instruct-GGUF/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf" ; do
        [[ -f "$c" ]] && { MODEL="$c"; break; }
    done
fi
[[ -z "$MODEL" || ! -f "$MODEL" ]] && { echo "uso: $0 <modelo.gguf>"; exit 2; }

step "0/4  Ambiente"
info "modelo: $(basename "$MODEL")  ($(du -h "$MODEL" | cut -f1))"
for g in render video; do
    id -nG | tr ' ' '\n' | grep -qx "$g" && ok "grupo $g ativo" || { bad "grupo $g em falta — sai e entra de novo"; exit 1; }
done
[[ -e /dev/kfd ]] && ok "/dev/kfd presente" || { bad "/dev/kfd ausente"; exit 1; }

# ------------------------------------------------------- encontrar builds ----
step "1/4  Builds disponiveis"

HIP_DIR=""
for d in "$HOME/llama-hip/build/bin" "$HOME/.unsloth/llama.cpp/build/bin" \
         "$HOME/llama.cpp/build-hip/bin" "$HOME/llama-flash-next/build/bin"; do
    if [[ -x "$d/llama-server" ]] && compgen -G "$d/libggml-hip.so*" > /dev/null; then
        HIP_DIR="$d"; break
    fi
done

VK_BIN="$(readlink -f "$(command -v llama-server 2>/dev/null || echo "$HOME/.local/bin/llama-server")")"
VK_DIR="$(dirname "$VK_BIN")"

if [[ -n "$HIP_DIR" ]]; then
    ok "HIP  : $HIP_DIR"
else
    bad "nenhum build HIP encontrado"
    cat <<'EOF'

  Compila um (10-30 min):

    git clone --depth 1 https://github.com/ggml-org/llama.cpp ~/llama-hip
    cmake -S ~/llama-hip -B ~/llama-hip/build \
          -DGGML_HIPBLAS=ON -DAMDGPU_TARGETS=gfx1150 \
          -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DLLAMA_CURL=OFF
    cmake --build ~/llama-hip/build -j"$(nproc)" --target llama-server
EOF
    exit 1
fi
[[ -x "$VK_BIN" ]] && ok "Vulkan: $VK_BIN" || { bad "llama-server Vulkan nao encontrado"; exit 1; }

# --------------------------------------------------------------- flags comuns
# Deliberadamente IGUAIS nos dois, para a comparacao ser honesta.
# Nota: NAO usamos os flags do repositorio FoxEgregore (--cache-type-k q4_0
# degrada a qualidade ~1400x, e a ausencia de --cache-reuse desliga a cache
# de prefixo). Usamos os que ja estao medidos como bons nesta maquina.
COMMON=(-c 32768 -np 1 -fa on -ctk q8_0 -ctv q8_0
        -b 2048 -ub 512 --cache-reuse 256 -sps 0.50
        --timeout 3600 --no-webui --metrics -t 12 -n 16384
        --alias llama-local-model)

medir() {
    local label="$1"; local srv="$2"; local envstr="$3"; shift 3
    local log="$RES/hipvk-$label.log"
    info "a arrancar [$label] ..."
    # shellcheck disable=SC2086
    setsid env $envstr "$srv" -m "$MODEL" --host 127.0.0.1 --port "$PORT" "$@" \
        > "$log" 2>&1 &
    local pid=$!

    local ready=0
    for _ in $(seq 1 900); do
        kill -0 "$pid" 2>/dev/null || { bad "[$label] morreu"; tail -20 "$log" | sed 's/^/       /'; return 1; }
        curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { ready=1; break; }
        sleep 1
    done
    [[ "$ready" == 1 ]] || { bad "[$label] nao ficou pronto"; return 1; }

    echo "  --- [$label] dispositivo que o backend escolheu ---"
    grep -iE "ROCm[0-9]|Vulkan[0-9]|device|backend" "$log" | head -4 | sed 's/^/       /'

    python3 "$HERE/apex_bench.py" --url "http://127.0.0.1:$PORT/v1" --port "$PORT" \
        --label "$label" --prompt-tokens 512 --gen-tokens 256 \
        --json "$RES/hipvk-$label.json" 2>&1 | grep -E "^ *\[|best" | sed 's/^/       /'

    kill -9 -- "-$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" 2>/dev/null || kill -9 "$pid" 2>/dev/null
    sleep 3
}

step "2/4  Medir HIP / ROCm"
HSA_ENV="HSA_OVERRIDE_GFX_VERSION=11.5.0 GPU_MAX_HW_QUEUES=4 ROCBLAS_USE_HIPBLASLT=1 HSA_ENABLE_SDMA=0 HIP_FORCE_DEV_KERNARG=1"
medir "HIP" "$HIP_DIR/llama-server" "$HSA_ENV" -ngl 999 "${COMMON[@]}"

step "3/4  Medir Vulkan"
medir "VULKAN" "$VK_BIN" "" -ngl 999 "${COMMON[@]}"

step "4/4  Veredicto"
python3 - "$RES" <<'PY'
import json, sys, pathlib
d = {}
for f in pathlib.Path(sys.argv[1]).glob("hipvk-*.json"):
    try: j = json.loads(f.read_text())
    except Exception: continue
    for r in j.get("results", []):
        if not r.get("error"):
            d[r["label"]] = (r.get("srv_prompt_tps", 0), r.get("srv_predicted_tps", 0), r.get("ttft_ms", 0))
if "HIP" in d and "VULKAN" in d:
    hp, hd, ht = d["HIP"]; vp, vd, vt = d["VULKAN"]
    print(f"  {'':10}{'prefill t/s':>13}{'decode t/s':>12}{'TTFT ms':>10}")
    print(f"  {'HIP':<10}{hp:>13.2f}{hd:>12.2f}{ht:>10.0f}")
    print(f"  {'VULKAN':<10}{vp:>13.2f}{vd:>12.2f}{vt:>10.0f}")
    print()
    if vd > 0 and vp > 0:
        print(f"  HIP vs Vulkan:  decode {hd/vd:.2f}x   prefill {hp/vp:.2f}x")
        if hd > vd * 1.1 and hp > vp * 1.1:
            print("  >>> HIP ganha por >=10% em ambos: vale a pena mudar de backend.")
        elif hd < vd and hp < vp:
            print("  >>> Vulkan ganha: FICA no Vulkan.")
        else:
            print("  >>> Empate tecnico. Fica no Vulkan: ja tens o LM Studio integrado")
            print("      e os teus modelos indexados por ele.")
else:
    print("  (faltam resultados; ver os logs em benchmarks/resultados/hipvk-*.log)")
PY
