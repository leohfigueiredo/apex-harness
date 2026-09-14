#!/usr/bin/env bash
# check_uma.sh — diz-te quanto da tua RAM está presa no carve-out da iGPU.
#
# Corre ANTES e DEPOIS de mudar a BIOS, para confirmares o ganho.
#
#   bash bench/check_uma.sh
set -uo pipefail

gib() { python3 -c "print(f'{$1/1024**3:.2f}')"; }

echo "=============================================================="
echo " APEX — DIAGNÓSTICO DA MEMÓRIA (iGPU vs Sistema)"
echo "=============================================================="
echo

# --- RAM que o Linux vê ---
mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_total_gib=$(python3 -c "print(f'{$mem_total_kb/1024/1024:.2f}')")
echo "  RAM visível ao Linux .............. ${mem_total_gib} GiB"

# --- Carve-out da iGPU (BIOS reserva isto e o Linux nunca o vê) ---
vram_file=$(ls /sys/class/drm/card[0-9]*/device/mem_info_vram_total 2>/dev/null | head -1)
gtt_file=$(ls /sys/class/drm/card[0-9]*/device/mem_info_gtt_total 2>/dev/null | head -1)

if [[ -n "$vram_file" ]]; then
    vram=$(cat "$vram_file")
    vram_gib=$(gib "$vram")
    echo "  VRAM reservada à iGPU (BIOS) ...... ${vram_gib} GiB"
    echo "                                      ^ este valor é definido na BIOS"
else
    vram_gib=0
    echo "  VRAM reservada à iGPU ............. (não detetado)"
fi

if [[ -n "$gtt_file" ]]; then
    gtt_gib=$(gib "$(cat "$gtt_file")")
    echo "  GTT (RAM partilhada c/ a iGPU) .... ${gtt_gib} GiB"
fi

# --- Total físico estimado ---
echo
python3 - "$mem_total_gib" "$vram_gib" <<'PY'
import sys
mem=float(sys.argv[1]); vram=float(sys.argv[2])
print(f"  Estimativa de RAM FÍSICA total .... {mem+vram:.1f} GiB  ({mem:.1f} sistema + {vram:.1f} iGPU)")
PY

# --- Veredicto ---
echo
echo "--------------------------------------------------------------"
python3 - "$vram_gib" <<'PY'
import sys
vram=float(sys.argv[1])
if vram >= 8:
    print("  VEREDICTO: carve-out GRANDE.")
    print()
    print("  Estes ~%.0f GiB estão dedicados à iGPU e o CPU NÃO lhes toca," % vram)
    print("  mesmo quando a GPU está parada. Se não estiveres a correr")
    print("  modelos totalmente offloaded para a GPU, é capacidade perdida.")
    print()
    print("  Ação: na BIOS, baixar 'UMA Frame Buffer Size' para 512M.")
    print("        Ganhas ~%.0f GiB de RAM para o sistema." % (vram-0.5))
else:
    print("  VEREDICTO: carve-out PEQUENO — já está no valor recomendado.")
    print("  Não há nada a fazer na BIOS.")
PY

# --- Impacto prático ---
echo
echo "--------------------------------------------------------------"
echo " IMPACTO PRÁTICO"
echo "--------------------------------------------------------------"
avail_gib=$(awk '/^MemAvailable:/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
echo "  RAM disponível agora .............. ${avail_gib} GiB"
echo "  Page cache em uso ................. $(awk '/^Cached:/{printf "%.1f", $2/1024/1024}' /proc/meminfo) GiB"
echo
echo "  Os teus modelos estão em discos MECÂNICOS:"
lsblk -d -o NAME,ROTA,SIZE,MODEL 2>/dev/null | awk 'NR==1 || $2==1' | sed 's/^/    /'
echo "  (ROTA=1 significa disco rotativo)"
echo
echo "  Mais RAM = mais page cache = os modelos ficam em cache depois da"
echo "  1ª leitura, em vez de serem relidos do disco a cada arranque."
echo
echo "=============================================================="
