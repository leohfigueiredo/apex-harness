#!/usr/bin/env bash
# testar_rocm.sh — vale a pena tentar ROCm em vez de Vulkan nesta maquina?
#
# Porque e preciso testar: o repositorio FoxEgregore/rdna35-llm-baremetal usa
# ROCm/HIP e reporta numeros bons no MESMO hardware que o teu. Mas o ROCm so
# compensa se o /dev/kfd existir e o HIP enumerar a GPU.
#
# IMPORTANTE: corre isto no TEU terminal, nao atraves de um agente -- agentes
# costumam correr dentro de sandboxes que montam um /dev minimo, e nesse caso
# /dev/dri e /dev/kfd aparecem como inexistentes mesmo quando existem.
#
#   bash ~/apex_harness/benchmarks/testar_rocm.sh
set -uo pipefail

ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; }
warn() { echo "  ⚠  $*"; }
info() { echo "  →  $*"; }

echo "=============================================================="
echo " O ROCm funciona nesta maquina?"
echo "=============================================================="
echo

PASS=0; FAIL=0

# ---------------------------------------------------------------- 1. /dev ---
echo "[1/6] Dispositivos"
if [[ -e /dev/kfd ]]; then
    ok "/dev/kfd existe  ($(stat -c '%a %U:%G' /dev/kfd 2>/dev/null))"
    PASS=$((PASS+1))
else
    bad "/dev/kfd NAO existe — sem isto o ROCm/HIP nao inicializa de todo"
    FAIL=$((FAIL+1))
fi
if compgen -G "/dev/dri/renderD*" > /dev/null; then
    ok "/dev/dri/renderD* existe  ($(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' '))"
    PASS=$((PASS+1))
else
    bad "/dev/dri/renderD* NAO existe"
    FAIL=$((FAIL+1))
fi

# ------------------------------------------------------------- 2. grupos ---
echo
echo "[2/6] Permissoes"
MISSING=""
for g in render video; do
    if id -nG | tr ' ' '\n' | grep -qx "$g"; then
        ok "pertence ao grupo '$g'"
    else
        bad "NAO pertence ao grupo '$g'  (a sessao nao apanhou a alteracao — precisa de re-login)"
        MISSING="$MISSING $g"
    fi
done
[[ -n "$MISSING" ]] && info "corrigir:  sudo usermod -aG render,video \$USER   e depois SAIR e ENTRAR de novo"
echo "  grupos da sessao: $(id -nG)"

# ------------------------------------------------------------ 3. rocminfo ---
echo
echo "[3/6] rocminfo (a prova de que a HSA ve um agente)"
if command -v rocminfo >/dev/null; then
    # `grep -c` devolve 0 E exit status 1 quando nao ha correspondencias; com um
    # `|| echo 0` a variavel ficava com "0\n0" e o teste aritmetico rebentava.
    AGENTS=$(rocminfo 2>/dev/null | grep -c "Agent" || true)
    AGENTS=$(printf '%s' "${AGENTS:-0}" | head -1 | tr -dc '0-9')
    AGENTS=${AGENTS:-0}
    GFX=$(rocminfo 2>/dev/null | grep -oE "gfx[0-9a-f]+" | sort -u | tr '\n' ' ')
    if [[ "$AGENTS" -gt 0 ]] 2>/dev/null; then
        ok "rocminfo encontrou $AGENTS agentes   |   gfx: ${GFX:-?}"
        PASS=$((PASS+1))
    else
        bad "rocminfo NAO encontrou agentes"
        rocminfo 2>&1 | grep -iE "error|unable|cannot" | head -3 | sed 's/^/       /'
        FAIL=$((FAIL+1))
    fi
else
    bad "rocminfo nao instalado"
    FAIL=$((FAIL+1))
fi

# -------------------------------------------------------------- 4. rocm-smi --
echo
echo "[4/6] rocm-smi"
if command -v rocm-smi >/dev/null; then
    if rocm-smi --showproductname 2>/dev/null | grep -qiE "gfx|radeon|890"; then
        ok "rocm-smi identifica a GPU"
        rocm-smi --showproductname 2>/dev/null | grep -iE "series|model|sku" | head -3 | sed 's/^/       /'
        PASS=$((PASS+1))
    else
        warn "rocm-smi nao identificou a GPU (pode ser so falta de permissoes)"
        rocm-smi --showproductname 2>&1 | head -4 | sed 's/^/       /'
    fi
else
    bad "rocm-smi nao instalado"
fi

# ------------------------------------------- 5. um build HIP enumera a GPU? --
echo
echo "[5/6] Um llama.cpp com HIP ve a GPU?  (o teste decisivo)"
HIP_BUILD=""
for d in "$HOME/.unsloth/llama.cpp/build/bin" "$HOME/llama-flash-next/build/bin" \
         "$HOME/llama.cpp/build/bin" "/usr/local/bin"; do
    [[ -x "$d/llama-server" ]] && { HIP_BUILD="$d"; break; }
done

if [[ -n "$HIP_BUILD" ]]; then
    info "a testar $HIP_BUILD/llama-server"
    OUT=$(HSA_OVERRIDE_GFX_VERSION=11.5.0 timeout 60 "$HIP_BUILD/llama-server" --list-devices 2>&1)
    echo "$OUT" | head -6 | sed 's/^/       /'
    if echo "$OUT" | grep -qiE "ROCm[0-9]|gfx[0-9]"; then
        ok "HIP ENUMERA A GPU — o ROCm e viavel!"
        PASS=$((PASS+1))
    else
        warn "este build nao enumera a GPU (pode ser build Vulkan, ou sem suporte)"
    fi
else
    warn "nao encontrei nenhum llama-server para testar"
fi

# ------------------------------------------------------------------ 6. veredicto
echo
echo "=============================================================="
if [[ "$FAIL" -eq 0 ]]; then
    echo " VEREDICTO: ROCm PARECE VIAVEL ($PASS verificacoes passaram)"
    echo "=============================================================="
    cat <<'EOF'

  Vale a pena compilar o llama.cpp com HIP e comparar com o Vulkan:

    git clone https://github.com/ggml-org/llama.cpp
    cd llama.cpp && mkdir build-hip && cd build-hip
    cmake .. -DGGML_HIPBLAS=ON -DAMDGPU_TARGETS=gfx1150 \
             -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON
    make -j"$(nproc)" llama-server llama-bench

  Depois mede os DOIS lado a lado, com o mesmo modelo e as mesmas flags:

    ~/apex_harness/benchmarks/compare_backends.sh <modelo.gguf>

  ⚠️  NAO copies os flags do repositorio FoxEgregore sem pensar. Vários deles
      sao piores do que os que ja tens:
        --cache-type-k q4_0   -> qualidade ~1400x pior que q8_0 (medido)
        (sem --cache-reuse)   -> desliga a cache de prefixo que acabou de ser corrigida
        -c 4096               -> pequeno de mais (o harness envia ~4000 tokens so de prompt)
        --chat-template chatml-> forcado, e fragil
        --host 0.0.0.0        -> expoe o servidor a rede local
        pkill -f llama-server -> mata qualquer llama-server, de qualquer aplicacao
EOF
else
    echo " VEREDICTO: ROCm NAO esta pronto nesta maquina ($FAIL verificacoes falharam)"
    echo "=============================================================="
    cat <<'EOF'

  Fica no Vulkan + LM Studio, que funcionam e que ja estao configurados.
  O caminho para mais velocidade nesta maquina nao e o ROCm, e sim:

    1. Reserva UMA em 16-32 GiB  (o prefill precisa da GPU: 11 t/s em CPU
       contra 60-100 t/s com offload)
    2. Modelo MoE (A3B/A4B) em vez de denso  -> ~10x o teto de decode
    3. Prefixo de prompt estavel  -> a cache KV vale ~20x por turno
       (ja corrigido no harness)
EOF
fi
echo
echo "  (nota: o ROCm tambem nao faz nada pelo KV cache nem pelo prefill de um"
echo "   modelo denso — esses sao limitados por banda de memoria, nao por GPU.)"
