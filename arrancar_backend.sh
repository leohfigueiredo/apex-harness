#!/usr/bin/env bash
# arrancar_backend.sh - sobe o llama-server na 8080, que e a porta que o
# Apex Harness procura primeiro (core.detect_active_api_base).
#
# Por que isto e necessario: o harness NAO carrega modelo sozinho. Ele aponta
# para http://127.0.0.1:8080/v1 e, se nao houver nada la, o /api/status responde
# "offline" e o turno trava -- foi o que aconteceu depois dos reboots de 18/09,
# quando o LM Studio foi morto pelo OOM e nao voltou.
#
# Uso:
#   ./arrancar_backend.sh                    # modelo padrao (MoE, 37 t/s medido)
#   ./arrancar_backend.sh <outro.gguf>
#   MODO=cpu ./arrancar_backend.sh           # -ngl 0, so CPU
#   APEX_SPEC=1 ./arrancar_backend.sh        # LIGA --spec-type ngram-simple (off por omissao)
#
# O memguard roda ANTES: se o modelo nao couber, nada e carregado.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse dos argumentos: `--foreground` NAO pode ser confundido com o caminho do
# modelo (era o que acontecia com MODELO="${1:-...}").
FOREGROUND=0
MODELO=""
for arg in "$@"; do
    case "$arg" in
        --foreground|-f) FOREGROUND=1 ;;
        *)               MODELO="$arg" ;;
    esac
done
MODELO="${MODELO:-/run/media/leonardo/Windows/AIModels/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf}"

SRV="${APEX_LLAMA_SERVER:-$HOME/.local/bin/llama-server}"
PORT="${APEX_LLAMA_PORT:-8080}"
CTX="${APEX_CTX:-65536}"
LOG="$AQUI/benchmarks/resultados/backend_8080.log"
PIDF="$AQUI/benchmarks/resultados/backend_8080.pid"

[[ -x "$SRV" ]] || { echo "!! nao achei $SRV" >&2; exit 1; }

# O disco de modelos esta no /etc/fstab com `nofail`: se o NTFS vier sujo o
# kernel monta em somente-leitura, e no arranque da sessao o ficheiro pode ainda
# nao existir. Em --foreground esperamos la em baixo; aqui so avisamos.
if [[ ! -f "$MODELO" && "$FOREGROUND" != 1 ]]; then
    echo "!! nao achei $MODELO" >&2
    exit 1
fi

# --- ja existe um servidor nesta porta? -------------------------------------
if curl -sf -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
    echo "ja existe backend na $PORT:"
    curl -s -m 5 "http://127.0.0.1:$PORT/v1/models" | head -c 400
    echo
    exit 0
fi

# --- flags ---------------------------------------------------------------
# -t 12 / --cpu-mask 0xFFF  : 12 threads fisicos. Medido: as 12 threads tem de
#                             ser as 12 CORES (0-3,12-15,4-11,16-23), nunca 24
#                             threads SMT -- -t 24 cai de 13,73 para 0,35 t/s.
#                             NAO usar taskset: medido -97% de decode.
# -fa on + -ctk/-ctv q8_0   : obrigatorio para V-cache quantizado.
# -b 2048 -ub 512           : conjunto de REFERENCIA -- foi com estes que se
#                             mediu 37,03 t/s. Sobrescreva com UB=2048 p/ testar.
# --cache-reuse 256         : o agente reenvia system prompt + tools todo turno.
# --no-webui                : o harness traz a propria interface.
#
# DOIS FLAGS QUE JA CUSTARAM DESEMPENHO AQUI - nao repor:
#
#   -lm mmap+mlock   O hard limit de RLIMIT_MEMLOCK e 8192 KB e nao sobe sem
#                    root, entao o mlock FALHA:
#                      "failed to mlock 436264960-byte buffer: Cannot allocate
#                       memory / Try increasing RLIMIT_MEMLOCK"
#                    O modo fica em mmap normal e o flag so adiciona ruido.
#
#   --prio 2         Requer CAP_SYS_NICE:
#                      "failed to set process priority 2 : Permission denied"
#                      "failed to set thread priority 2 : Operation not permitted"
#                    Foram 6180 dessas num unico log, no caminho quente.
#                    Sem CAP_SYS_NICE o flag e inerte e so custa syscalls.
NGLA=999
[[ "${MODO:-gpu}" == "cpu" ]] && NGLA=0

# Decodificacao especulativa por n-gram: DESLIGADA por omissao.
#
# O ganho de 1,95x foi medido num prompt sintetico de codigo. Na carga REAL do
# harness -- system prompt, 17 esquemas de ferramentas, chamadas de ferramenta --
# a aceitacao lida no /metrics do proprio servidor foi:
#
#     spec_decode_num_accepted_tokens_total 22
#     spec_decode_num_draft_tokens_total   144        ->  15,3%
#
# Abaixo dos ~60% que o hwtune documenta como necessarios para o draft
# compensar. Abaixo disso cada draft rejeitado paga uma passagem de verificacao
# a mais e nao devolve nada -- o flag estava a custar desempenho.
#
# Para o testar num workload concreto:  APEX_SPEC=1 ./arrancar_backend.sh
# e confirmar no log a linha `draft acceptance = X`. Abaixo de ~0.6, desligue.
SPEC=()
[[ "${APEX_SPEC:-0}" == "1" ]] && SPEC=(--spec-type ngram-simple)

# ---------------------------------------------------------------- visao (mmproj)
# Um modelo multimodal so ve imagens se o llama-server arrancar com -mm. Sem
# isto o modelo e texto apenas e o /props responde `modalities: {vision: false}`.
#
# Procura-se um projetor ao lado do modelo (`*mmproj*.gguf`). Medido:
# Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf, 601 MB, mesma pasta dos ficheiros do
# Bonsai 2. Se nao houver nenhum, nao se passa nada -- e o caso normal.
MMPROJ="${APEX_MMPROJ:-}"
if [[ -z "$MMPROJ" ]]; then
    MMPROJ="$("$AQUI/.venv/bin/python" -c "
import sys
sys.path.insert(0, '$AQUI')
try:
    from apex_harness.hwtune import find_mmproj
    print(find_mmproj('$MODELO') or '')
except Exception:
    print('')
" 2>/dev/null)"
fi
MM=()
if [[ -n "$MMPROJ" && -f "$MMPROJ" ]]; then
    MM=(-mm "$MMPROJ")
    echo ">> visao: projetor multimodal $MMPROJ"
fi

ARGS=(-m "$MODELO" --host 127.0.0.1 --port "$PORT"
      -t 12 -tb 12 --cpu-mask 0xFFF --cpu-strict 1
      -ngl "$NGLA" -c "$CTX" -np 1
      -fa on -ctk q8_0 -ctv q8_0
      -b 2048 -ub "${UB:-512}" --cache-reuse 256 -sps 0.50
      "${SPEC[@]}"
      "${MM[@]}"
      --timeout 3600 --no-webui --metrics --alias llama-local-model -n 16384)

echo ">> memguard"
"$AQUI/memguard.sh" "$MODELO" --ctx "$CTX" --kv-type q8_0 || {
    rc=$?
    if [[ $rc -eq 3 ]]; then
        echo ">> modelo RECUSADO pelo memguard -- backend nao foi carregado." >&2
        # Codigo 3 e um resultado definitivo, nao uma falha transitoria. O
        # servico systemd marca-o em SuccessExitStatus para nao entrar em ciclo
        # de reinicio tentando carregar um modelo que nunca vai caber.
        exit 3
    fi
}

# --- modo systemd -----------------------------------------------------------
# Com --foreground nao destacamos o processo: fazemos exec, para que o systemd
# seja o dono do PID e consiga supervisionar, reiniciar e parar o servidor.
# Um `setsid ... &` seguido de saida faria o systemd achar que o servico
# terminou e matar o cgroup inteiro.
if [[ "$FOREGROUND" == 1 || "${APEX_FOREGROUND:-0}" == "1" ]]; then
    # O disco de modelos esta no /etc/fstab com nofail: se o NTFS vier sujo, o
    # kernel monta em somente-leitura e o ficheiro pode ainda nao existir quando
    # a sessao grafica arranca. Esperamos em vez de falhar de imediato.
    for i in $(seq 1 120); do
        [[ -f "$MODELO" ]] && break
        [[ $i -eq 1 ]] && echo ">> a espera do modelo aparecer: $MODELO"
        sleep 1
    done
    [[ -f "$MODELO" ]] || { echo "!! modelo nao apareceu: $MODELO" >&2; exit 4; }

    echo ">> exec (systemd) $SRV na porta $PORT"
    exec "$SRV" "${ARGS[@]}"
fi

echo ">> subindo $SRV na porta $PORT"
setsid "$SRV" "${ARGS[@]}" > "$LOG" 2>&1 &
NOVO=$!
echo "$NOVO" > "$PIDF"
echo "   pid $NOVO   log $LOG"

echo ">> aguardando ficar pronto (carregar 16 GiB do disco USB demora)"
for i in $(seq 1 600); do
    if curl -sf -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
        echo ">> PRONTO em ${i}s"
        curl -s -m 5 "http://127.0.0.1:$PORT/v1/models"; echo
        exit 0
    fi
    kill -0 "$NOVO" 2>/dev/null || {
        echo "!! processo morreu. ultimas linhas do log:" >&2
        tail -25 "$LOG" >&2
        exit 1
    }
    sleep 1
done

echo "!! timeout de 600s. ultimas linhas:" >&2
tail -25 "$LOG" >&2
exit 1
