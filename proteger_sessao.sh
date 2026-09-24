#!/usr/bin/env bash
# proteger_sessao.sh - instala uma rede de seguranca para o desktop NAO morrer
# quando um modelo grande demais for carregado.
#
# Por que precisa disso, se ja existe o memguard.sh:
#   O memguard so protege o que passa por ele. Se o modelo for carregado pela
#   interface do LM Studio, por outro app, ou por um comando digitado direto,
#   ninguem consulta o memguard -- e o desfecho medido nesta maquina e:
#
#     2026-09-17 21:47  BUG em amdgpu_vm_pt_free -> "reboot is needed!" -> reboot
#     2026-09-18 14:44  OOM global do kernel: 8 processos mortos, incluindo
#                       org.gnome.Shell@ubuntu.service -> desktop reiniciou
#
#   O OOM killer do kernel varre a maquina inteira: 8 processos morreram em 19
#   segundos. Ele nao sabe qual e o porcalhao. O systemd-oomd esta ativo, mas so
#   age por pressao de memoria em cgroup, e essa pressao nunca chega a se formar
#   antes da varredura do kernel.
#
#   O earlyoom resolve exatamente isso: ele olha a memoria livre do SISTEMA e,
#   antes do kernel agir, mata o processo errado -- o maior consumidor. Ou seja,
#   mata o llama-server/lm-studio e deixa o GNOME vivo.
#
# Uso:
#   sudo ./proteger_sessao.sh           # instala e ativa
#   sudo ./proteger_sessao.sh --remover # desfaz
#
set -euo pipefail

CONF=/etc/default/earlyoom
# O arquivo e lido pelo systemd como EnvironmentFile e depois sofre word-split
# em `ExecStart=/usr/bin/earlyoom $EARLYOOM_ARGS`. Por isso:
#   - o valor inteiro fica entre aspas duplas;
#   - as regexes NAO podem conter aspas nem espacos.
# -m 5  : age quando a RAM livre cair a 5%   (antes do kernel, que age a ~0%)
# -s 5  : age quando o swap livre cair a 5%
# -r 30 : relatorio a cada 30s (visivel no journalctl)
# --prefer: empurra o alvo para os carregadores de modelo
# --avoid : nunca mata o que sustenta a sessao grafica
ARGS='-m 5 -s 5 -r 30 --prefer ^(llama-server|lms|lm-studio|python3?|ollama|koboldcpp) --avoid ^(gnome-shell|gdm|gdm3|Xwayland|Xorg|systemd|systemd-logind|dbus-daemon|pipewire|wireplumber|sshd|NetworkManager)'

if [ "${1:-}" = "--remover" ]; then
    systemctl disable --now earlyoom 2>/dev/null || true
    apt-get remove -y earlyoom || true
    rm -f "$CONF"
    echo "earlyoom removido."
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Precisa de root. Rode:  sudo $0" >&2
    exit 1
fi

echo ">> instalando earlyoom"
apt-get update -qq
apt-get install -y earlyoom

echo ">> configurando $CONF"
{
  echo "# Gerado por proteger_sessao.sh"
  echo "# Mantem a sessao GNOME viva matando o maior consumidor de memoria antes"
  echo "# que o OOM killer do kernel varra a maquina inteira."
  printf 'EARLYOOM_ARGS="%s"\n' "$ARGS"
} > "$CONF"

echo ">> ativando"
systemctl enable --now earlyoom
sleep 2

echo
echo ">> estado"
systemctl is-active earlyoom && echo "   earlyoom ATIVO"
echo
echo "Memoria agora:"
free -h
echo
echo "Para ver as acoes do earlyoom:  journalctl -u earlyoom -f"
echo "Para testar (NAO rode se estiver com trabalho aberto):"
echo "   earlyoom -m 99 -r 5    # modo agressivo, so para ver a mensagem"
