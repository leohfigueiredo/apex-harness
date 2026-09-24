#!/usr/bin/env bash
# medir_uma.sh - mede CPU vs Vulkan com os 32 GiB de UMA atuais, e PROVA que a
# GPU foi mesmo usada.
#
# POR QUE ISTO EXISTE
# -------------------
# Uma sessao de auditoria inteira mediu "Vulkan" sem GPU. O sandbox escondia
# /dev/dri, entao o llama-server nao enumerava dispositivo nenhum:
#
#     $ llama-server --list-devices
#     Available devices:
#       (none)
#
#     $ ls /dev/dri
#     No such file or directory
#
# e TODAS as 48 camadas iam para a CPU:
#
#     common_params_fit_impl: getting device memory data for initial parameters:
#     load_tensors: layer 0  assigned to device CPU
#     load_tensors: layer 1  assigned to device CPU
#     ...
#
# O resultado era uma linha "vulkan_ngl999" com numeros de CPU, VRAM em 0,41 GiB,
# e um relatorio inteiro tirado dali. Este script checa /dev/dri e --list-devices
# ANTES de medir, e ABORTA se a GPU nao estiver visivel -- em vez de produzir mais
# um numero que parece bom e nao e.
#
# Uso:  ./medir_uma.sh [modelo.gguf]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRV="${APEX_LLAMA_SERVER:-$HOME/.local/bin/llama-server}"
M="${1:-/run/media/leonardo/Windows/AIModels/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf}"
PORT="${APEX_PORT:-8094}"
RES="$HERE/resultados"
mkdir -p "$RES"

VRAM=/sys/class/drm/card1/device/mem_info_vram_used
GTT=/sys/class/drm/card1/device/mem_info_gtt_used
gib() { awk '{printf "%.2f", $1/1073741824}' "$1" 2>/dev/null || echo "?"; }

echo "=============================================================="
echo " PRE-VOO: a GPU esta mesmo visivel para este processo?"
echo "=============================================================="
FAIL=0
if [[ -e /dev/dri ]]; then
    echo "  /dev/dri            OK  ($(ls /dev/dri | tr '\n' ' '))"
else
    echo "  /dev/dri            AUSENTE  <-- a GPU esta invisivel"
    FAIL=1
fi
DEVS="$(timeout 60 "$SRV" --list-devices 2>&1 || true)"
echo "  --list-devices:"
echo "$DEVS" | sed 's/^/    /'
if echo "$DEVS" | grep -qiE "vulkan|rocm|hip"; then
    echo "  backend GPU         OK"
else
    echo "  backend GPU         NENHUM  <-- qualquer medicao seria CPU disfarcada"
    FAIL=1
fi

if [[ "$FAIL" == 1 ]]; then
    cat <<'EOF'

 ABORTADO. Sem /dev/dri e sem dispositivo Vulkan, o llama-server poe TODAS as
 camadas na CPU e ainda assim aceita -ngl 999. O numero sairia rotulado
 "vulkan" e seria CPU.

 Corra este script do SEU terminal (fora de qualquer sandbox/bwrap/container
 que esconda /dev/dri), ou verifique com:

     llama-server --list-devices     # tem de listar Vulkan0

EOF
    exit 4
fi

echo
echo "=============================================================="
echo " UMA / orcamento agora"
echo "=============================================================="
"$ROOT/memguard.sh"

COMMON=(-t 12 -tb 12 --cpu-mask 0xFFF --cpu-strict 1 -c 32768 -np 1 -fa on
        -ctk q8_0 -ctv q8_0 -b 2048 -ub 512 --cache-reuse 256 -sps 0.50
        --timeout 3600 --no-webui --metrics -n 16384 --alias llama-local-model)

medir() {
    local label="$1"; shift
    echo
    echo "--- $label ---"
    local log="$RES/uma-$label.log"
    setsid "$SRV" -m "$M" --host 127.0.0.1 --port "$PORT" "$@" > "$log" 2>&1 &
    local pid=$!
    local ok=0
    for _ in $(seq 1 900); do
        kill -0 "$pid" 2>/dev/null || break
        curl -sf -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { ok=1; break; }
        sleep 1
    done
    if [[ "$ok" != 1 ]]; then
        echo "  !! nao subiu"; tail -15 "$log" | sed 's/^/     /'
        kill -9 -- "-$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" 2>/dev/null
        return 1
    fi

    # Warmup obrigatorio no Vulkan: o primeiro pedido compila pipelines.
    for _ in 1 2 3; do
        curl -s -m 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            -d '{"model":"llama-local-model","messages":[{"role":"user","content":"hi"}],"max_tokens":16,"temperature":0}' >/dev/null 2>&1
    done

    # Prova de que a GPU foi usada.
    #
    # Contar linhas "assigned to device" NAO serve: o servidor so as imprime em
    # -lv 5, entao em verbosidade normal da sempre "0 / 0" e o aviso dispara em
    # falso. A prova que de facto distingue e a VRAM: sem offload o processo fica
    # em ~0,6 GiB (so o desktop), com offload sobe para as dezenas de GiB.
    local vram_gib
    vram_gib="$(awk -v v="$(cat "$VRAM" 2>/dev/null || echo 0)" 'BEGIN{printf "%.2f", v/1073741824}')"
    echo "  VRAM em uso durante a medicao: ${vram_gib} GiB"
    echo "  GTT  em uso durante a medicao: $(gib "$GTT") GiB"
    if [ "${vram_gib%%.*}" -lt 2 ]; then
        echo "  !! VRAM em ~${vram_gib} GiB: nada foi para o dispositivo."
        echo "     Qualquer numero abaixo e CPU, mesmo com -ngl 999."
    else
        echo "  OK: ${vram_gib} GiB na VRAM -- offload confirmado."
    fi

    /home/leonardo/apex_harness/.venv/bin/python "$HERE/apex_bench.py" \
        --url "http://127.0.0.1:$PORT/v1" --port "$PORT" --label "$label" \
        --prompt-tokens 512 --gen-tokens 256 --json "$RES/uma-$label.json" 2>&1 \
        | grep -E "^ *\[|best " | sed 's/^/  /'

    kill -9 -- "-$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" 2>/dev/null || kill -9 "$pid" 2>/dev/null
    sleep 3
}

medir "cpu_ngl0"     -ngl 0   "${COMMON[@]}"
medir "vulkan_ngl999" -ngl 999 "${COMMON[@]}"

echo
echo "=============================================================="
echo " VEREDICTO"
echo "=============================================================="
/home/leonardo/apex_harness/.venv/bin/python - "$RES" <<'PY'
import json, pathlib, sys
rows = {}
for f in pathlib.Path(sys.argv[1]).glob("uma-*.json"):
    d = json.loads(f.read_text())
    for r in d.get("results", []):
        if not r.get("error"):
            rows[r["label"]] = (r.get("srv_prompt_tps", 0), r.get("srv_predicted_tps", 0),
                                r.get("ttft_ms", 0))
cpu = rows.get("cpu_ngl0")
vk = rows.get("vulkan_ngl999")
if cpu and vk:
    print(f"  CPU   prefill {cpu[0]:7.2f} t/s   decode {cpu[1]:6.2f} t/s   TTFT {cpu[2]:7.1f} ms")
    print(f"  Vulkan prefill {vk[0]:7.2f} t/s   decode {vk[1]:6.2f} t/s   TTFT {vk[2]:7.1f} ms")
    print()
    for nome, i in (("decode", 1), ("prefill", 0)):
        r = vk[i] / cpu[i] if cpu[i] else 0
        v = "Vulcan GANHA" if r > 1.15 else ("CPU ganha" if r < 0.87 else "EMPATE")
        print(f"  {nome:8s} Vulkan/CPU = {r:.2f}x   -> {v}")
    print()
    if vk[1] / cpu[1] < 1.15:
        print("  GPU praticamente nao contribui. Neste estado o offload nao esta")
        print("  compensando: ou o carve-out e pequeno demais para o backend alocar,")
        print("  ou a GPU nao esta visivel. Confira a VRAM acima: se ficou perto de")
        print("  0,4 GiB, nada foi para o dispositivo.")
PY
