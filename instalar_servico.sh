#!/usr/bin/env bash
# instalar_servico.sh - faz o backend do llama-server subir sozinho no login.
#
# Resolve o problema do "harness parado": o harness web nao carrega modelo, ele
# so fala com 127.0.0.1:8080. Se o backend nao estiver de pe, o /api/status
# responde "offline", o turno trava e o botao de enviar nao volta. Depois de
# cada reboot era preciso arrancar o backend a mao.
#
# Uso:
#   ./instalar_servico.sh            # instala, ativa e arranca
#   ./instalar_servico.sh --remover  # desinstala
#   ./instalar_servico.sh --estado   # so mostra o estado
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/systemd/user"
UNIDADE="apex-backend.service"

estado() {
    echo "=== $UNIDADE ==="
    systemctl --user status "$UNIDADE" --no-pager 2>&1 | head -20
    echo
    echo "=== VRAM (18 GiB = GPU, 0,4 GiB = CPU disfarcado) ==="
    if [ -r /sys/class/drm/card1/device/mem_info_vram_used ]; then
        awk '{printf "%.2f GiB\n", $1/1073741824}' /sys/class/drm/card1/device/mem_info_vram_used
    else
        echo "  (mem_info_vram_used indisponivel)"
    fi
    echo
    echo "=== porta 8080 ==="
    curl -s -m 5 -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8080/v1/models
}

case "${1:-}" in
--estado)
    estado
    exit 0
    ;;
--remover)
    systemctl --user disable --now "$UNIDADE" 2>/dev/null
    rm -f "$DEST/$UNIDADE"
    systemctl --user daemon-reload
    echo "servico removido. O backend continua a funcionar ate ao proximo reboot"
    echo "se ainda estiver de pe -- pare com:  systemctl --user stop $UNIDADE"
    exit 0
    ;;
esac

# --- verificacoes antes de instalar -----------------------------------------
FALHA=0
echo "=== verificacoes ==="

if [ -e /dev/dri ]; then
    echo "  /dev/dri            OK"
else
    echo "  /dev/dri            AUSENTE -- o backend subiria em CPU"; FALHA=1
fi

if id -nG | tr ' ' '\n' | grep -qx render; then
    echo "  grupo render        OK"
else
    echo "  grupo render        FALTA -- rode: sudo usermod -aG render,video $USER"
    FALHA=1
fi

if id -nG | tr ' ' '\n' | grep -qx video; then
    echo "  grupo video         OK"
else
    echo "  grupo video         FALTA -- rode: sudo usermod -aG render,video $USER"
    FALHA=1
fi

MODELO_PADRAO="/run/media/leonardo/Windows/AIModels/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf"
if [ -f "$MODELO_PADRAO" ]; then
    echo "  modelo padrao       OK"
else
    echo "  modelo padrao       NAO ENCONTRADO: $MODELO_PADRAO"
    echo "                      (o servico espera 120s e desiste com codigo 4)"
fi

if [ -x "$AQUI/arrancar_backend.sh" ]; then
    echo "  arrancar_backend    OK"
else
    echo "  arrancar_backend    NAO EXECUTAVEL"; FALHA=1
fi

[ "$FALHA" = 0 ] || { echo; echo "corrija os pontos acima antes de instalar." >&2; exit 1; }

# --- instalar ---------------------------------------------------------------
echo
echo "=== instalando ==="
mkdir -p "$DEST"
install -m 644 "$AQUI/systemd/$UNIDADE" "$DEST/$UNIDADE"
echo "  $DEST/$UNIDADE"

systemctl --user daemon-reload
systemctl --user enable "$UNIDADE"

# Parar qualquer backend arrancado a mao, para nao haver dois na 8080.
if curl -sf -m 3 http://127.0.0.1:8080/v1/models >/dev/null 2>&1; then
    echo "  havia um backend manual na 8080; a parar"
    if [ -f "$AQUI/benchmarks/resultados/backend_8080.pid" ]; then
        P="$(cat "$AQUI/benchmarks/resultados/backend_8080.pid")"
        kill -9 -- "-$(ps -o pgid= -p "$P" 2>/dev/null | tr -d ' ')" 2>/dev/null || kill -9 "$P" 2>/dev/null
        rm -f "$AQUI/benchmarks/resultados/backend_8080.pid"
    fi
    sleep 3
fi

echo "  a arrancar (le 16 GiB do NTFS, pode levar um minuto)"
systemctl --user restart "$UNIDADE" 2>&1 | sed 's/^/  /' || true

echo
estado
