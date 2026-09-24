#!/usr/bin/env bash
# instalar_e_testar_rocm.sh — ROCm vs Vulkan, ponta a ponta.
#
# CONTEXTO (verificado em 2026-09-18):
#   * O ROCm 6.2.1 JA ESTA INSTALADO (hip-runtime, hipblas, hipblaslt, rocminfo,
#     rocm-smi, hipcc). NAO ha nada a instalar.
#   * O kernel JA expoe a GPU: /sys/class/kfd/kfd/topology/nodes/1 ->
#       gfx_target_version 110500 (= gfx1150), simd_count 32, 2x8 = 16 CUs
#   * O que falta e a SESSAO ter os grupos render/video. O /dev/kfd e
#     root:render modo 660, e o login atual e anterior ao `usermod -aG`.
#
# Corre isto DEPOIS de sair e entrar de novo (ou reiniciar).
#
#   bash ~/apex_harness/benchmarks/instalar_e_testar_rocm.sh
set -uo pipefail

ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; }
warn() { echo "  ⚠  $*"; }
info() { echo "  →  $*"; }
step() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }

MODEL="${1:-}"
ROOT="$HOME/apex_harness"
BUILD_DIR="$HOME/llama-hip"

step "0/6  Pre-requisitos"

# --- grupos ---------------------------------------------------------------
GOK=1
for g in render video; do
    if id -nG | tr ' ' '\n' | grep -qx "$g"; then
        ok "grupo '$g' ativo na sessao"
    else
        bad "grupo '$g' NAO ativo na sessao"
        GOK=0
    fi
done
if [[ "$GOK" == 0 ]]; then
    cat <<'EOF'

  >>> PARA AQUI. Nao vale a pena continuar. <<<

  O sistema ja te tem nos grupos, mas a sessao de login e anterior:

      sudo usermod -aG render,video "$USER"     # se ainda nao estiver feito
      # depois SAI da sessao e ENTRA de novo, ou reinicia

  Confirmar com:   id -nG | tr ' ' '\n' | grep -E '^(render|video)$'

EOF
    exit 1
fi

# --- /dev ----------------------------------------------------------------
if [[ -e /dev/kfd ]]; then
    ok "/dev/kfd existe  ($(stat -c '%a %U:%G' /dev/kfd))"
    if [[ -r /dev/kfd && -w /dev/kfd ]]; then ok "/dev/kfd legivel e escrevivel"; else bad "/dev/kfd sem permissao"; exit 1; fi
else
    bad "/dev/kfd nao existe"; exit 1
fi

for d in /dev/dri/renderD*; do
    [[ -e "$d" ]] && ok "$d  ($(stat -c '%a %U:%G' "$d"))"
done

# --- ROCm responde? -------------------------------------------------------
step "1/6  O ROCm acorda?"
if HSA_OVERRIDE_GFX_VERSION=11.5.0 rocminfo 2>/dev/null | grep -qiE "gfx1150|gfx11"; then
    ok "rocminfo enumera a GPU:"
    HSA_OVERRIDE_GFX_VERSION=11.5.0 rocminfo 2>/dev/null | grep -iE "Name:|gfx|Marketing" | head -6 | sed 's/^/       /'
else
    warn "rocminfo sem GPU. A tentar sem o override (ROCm >= 6.3 pode nao precisar)..."
    if rocminfo 2>/dev/null | grep -qiE "gfx11"; then
        ok "funciona SEM override — nao uses HSA_OVERRIDE_GFX_VERSION"
        export HSA_OVERRIDE_GFX_VERSION=""
    else
        bad "ROCm ainda nao ve a GPU"
        rocminfo 2>&1 | grep -iE "error|unable|cannot" | head -3 | sed 's/^/       /'
        cat <<'EOF'

  Possiveis causas:
    - o /dev/kfd acabou de aparecer mas o driver HSA ainda nao o apanhou -> reinicia
    - falta o pacote: sudo apt install rocm-hip-runtime
    - o kernel carregou o amdgpu sem KFD -> verifica: ls /sys/class/kfd
EOF
        exit 1
    fi
fi

# --- compilar llama.cpp com HIP -------------------------------------------
step "2/6  Compilar llama.cpp com HIPBLAS (gfx1150)"
if [[ -x "$BUILD_DIR/build/bin/llama-server" ]]; then
    ok "ja existe: $BUILD_DIR/build/bin/llama-server"
else
    command -v cmake >/dev/null || { bad "cmake nao instalado"; exit 1; }
    command -v hipcc  >/dev/null || { bad "hipcc nao instalado"; exit 1; }
    mkdir -p "$BUILD_DIR"
    if [[ ! -d "$BUILD_DIR/.git" ]]; then
        info "a clonar llama.cpp (shallow)..."
        git clone --depth 1 https://github.com/ggml-org/llama.cpp "$BUILD_DIR" || { bad "clone falhou"; exit 1; }
    fi
    info "a configurar com -DGGML_HIPBLAS=ON -DAMDGPU_TARGETS=gfx1150 ..."
    cmake -S "$BUILD_DIR" -B "$BUILD_DIR/build" \
        -DGGML_HIPBLAS=ON \
        -DAMDGPU_TARGETS=gfx1150 \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_NATIVE=ON \
        -DLLAMA_CURL=OFF \
        > /tmp/hip_cmake.log 2>&1 || { bad "cmake falhou"; tail -20 /tmp/hip_cmake.log | sed 's/^/       /'; exit 1; }
    info "a compilar (pode levar 10-30 min)..."
    cmake --build "$BUILD_DIR/build" -j"$(nproc)" --target llama-server llama-bench \
        > /tmp/hip_build.log 2>&1 || { bad "build falhou"; tail -25 /tmp/hip_build.log | sed 's/^/       /'; exit 1; }
    ok "compilado: $BUILD_DIR/build/bin/llama-server"
fi

# --- o build HIP ve a GPU? -------------------------------------------------
step "3/6  O build HIP enumera a GPU?"
HIP_SRV="$BUILD_DIR/build/bin/llama-server"
OUT=$(HSA_OVERRIDE_GFX_VERSION=11.5.0 "$HIP_SRV" --list-devices 2>&1 || true)
echo "$OUT" | head -6 | sed 's/^/  /'
if echo "$OUT" | grep -qiE "ROCm[0-9]|gfx11"; then
    ok "HIP ENUMERA A GPU"
else
    bad "HIP nao enumera a GPU"
    cat <<'EOF'

  Nao vale a pena continuar: o backend HIP nao ve o dispositivo.
  Fica no Vulkan, que funciona.

  Nota conhecida: em APUs gfx1150 ha relatos de o ROCm alocar apenas a VRAM
  dedicada e ignorar o GTT, ficando ~60% mais lento que o Vulkan:
    https://github.com/lemonade-sdk/llamacpp-rocm/issues/57
EOF
    exit 1
fi

# --- comparar -------------------------------------------------------------
step "4/6  Modelo para o teste"
if [[ -z "$MODEL" ]]; then
    for c in \
      "$HOME/.lmstudio/models/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf" \
      "/mnt/HDD/AIModels/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf" \
      "$HOME/.lmstudio/models/lmstudio-community/Qwen2.5-Coder-7B-Instruct-GGUF/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf" ; do
        [[ -f "$c" ]] && { MODEL="$c"; break; }
    done
fi
[[ -z "$MODEL" || ! -f "$MODEL" ]] && { bad "indica um modelo:  $0 <modelo.gguf>"; exit 1; }
info "modelo: $(basename "$MODEL")"

step "5/6  Benchmark: HIP (ROCm) vs Vulkan"
HIP_BENCH="$BUILD_DIR/build/bin/llama-bench"
VK_SRV="$(command -v llama-server || echo "$HOME/.local/bin/llama-server")"
VK_BENCH="$(dirname "$(readlink -f "$VK_SRV")")/llama-bench"

echo
echo "  --- HIP / ROCm ---"
HSA_OVERRIDE_GFX_VERSION=11.5.0 GEMM_MAX_HW_QUEUES=4 ROCBLAS_USE_HIPBLASLT=1 \
HSA_ENABLE_SDMA=0 HIP_FORCE_DEV_KERNARG=1 \
    "$HIP_BENCH" -m "$MODEL" -p 512 -n 128 -ngl 99 -r 2 -o md 2>&1 | grep -E "pp512|tg128|backend|error" | sed 's/^/    /'

if [[ -x "$VK_BENCH" ]]; then
    echo
    echo "  --- Vulkan (o teu atual) ---"
    "$VK_BENCH" -m "$MODEL" -p 512 -n 128 -ngl 999 -r 2 -o md 2>&1 | grep -E "pp512|tg128|backend|error" | sed 's/^/    /'
else
    warn "llama-bench Vulkan nao encontrado em $VK_BENCH"
fi

step "6/6  Como decidir"
cat <<'EOF'
  Compara o tg128 (decode) e o pp512 (prefill) das duas seccoes.

  Regra: se o HIP nao ganhar por >=10% em AMBOS, fica no Vulkan.
  O ROCm so compensa se o ganho justificar perderes a integracao com o
  LM Studio (que usa Vulkan e onde os teus modelos ja estao indexados).

  ⚠️  NAO copies os flags do repositorio FoxEgregore sem pensar:
        --cache-type-k q4_0    -> qualidade ~1400x pior que q8_0 (medido)
        sem --cache-reuse      -> desliga a cache de prefixo
        -c 4096                -> pequeno: o harness envia ~4000 tokens de prompt
        --host 0.0.0.0         -> expoe o servidor a rede
        pkill -f llama-server  -> mata qualquer llama-server
EOF
