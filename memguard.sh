#!/usr/bin/env bash
# memguard.sh - confere se um modelo cabe ANTES de carregar.
#
# Por que existe: nesta maquina um modelo grande demais nao devolve
# "out of memory" do llama.cpp. Ele derruba a sessao inteira:
#
#   2026-09-17 21:47  BUG no amdgpu_vm_pt_free -> "reboot is needed!" -> reboot
#   2026-09-18 14:44  OOM global do kernel, 8 processos mortos, incluindo
#                     org.gnome.Shell@ubuntu.service -> desktop reiniciou
#
# Uso:
#   ./memguard.sh                                  # so o orcamento atual
#   ./memguard.sh modelo.gguf                      # veredito para o modelo
#   ./memguard.sh modelo.gguf --ctx 65536 --kv-type q8_0
#   ./memguard.sh --run -- llama-server -m x.gguf ...   # so executa se passar
#
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$AQUI/.venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

export PYTHONPATH="$AQUI${PYTHONPATH:+:$PYTHONPATH}"
exec "$PY" -m apex_harness.memguard "$@"
