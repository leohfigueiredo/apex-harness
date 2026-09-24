#!/usr/bin/env bash
# esperar_pronto.sh - ExecStartPost do apex-backend.service.
#
# POR QUE ISTO EXISTE
# -------------------
# `systemctl start` tem de significar "o modelo esta servindo", nao apenas "o
# processo foi lancado". Sem isto o servico aparece como ativo segundos depois
# do arranque enquanto o llama-server ainda esta a ler 16 GiB do NTFS, e quem
# abrir o harness nesse intervalo apanha "status": "offline" -- exatamente o
# sintoma de 18/09, em que o turno trava e o botao de enviar nunca reabilita.
#
# Tambem e a unica verificacao que apanha o pior modo de falha desta maquina:
# sem /dev/dri o llama-server aceita -ngl 999 e poe TUDO na CPU, sem erro
# nenhum. VRAM abaixo de 2 GiB e o sinal disso.
set -uo pipefail

PORT="${APEX_LLAMA_PORT:-8080}"
LIMITE="${APEX_READY_TIMEOUT:-600}"

for i in $(seq 1 "$LIMITE"); do
    if curl -sf -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
        echo "backend pronto na porta $PORT apos ${i}s"
        # Se o modelo foi pedido com offload, confirme que a GPU foi mesmo usada.
        if [ -r /sys/class/drm/card1/device/mem_info_vram_used ]; then
            vram="$(awk '{printf "%.2f", $1/1073741824}' /sys/class/drm/card1/device/mem_info_vram_used)"
            echo "VRAM em uso: ${vram} GiB"
            if [ "${vram%%.*}" -lt 2 ]; then
                echo "AVISO: VRAM em ${vram} GiB -- a GPU pode nao ter sido usada" >&2
                echo "AVISO: confirme que /dev/dri existe e que o utilizador esta nos grupos render/video" >&2
            fi
        fi
        exit 0
    fi
    sleep 1
done

echo "backend NAO ficou pronto em ${LIMITE}s" >&2
exit 1
