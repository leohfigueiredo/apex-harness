# Por que a máquina reinicia, e como parar isso

Resposta curta: **os dois "reinícios" que você viu não têm a mesma causa, e nenhum
dos dois foi o GNOME.** Um foi crash real do kernel no driver amdgpu. O outro nem
foi reinício — foi o OOM killer do kernel matando a sessão inteira.

Os dois têm a mesma origem: **modelo grande demais para 45,65 GiB de RAM visível.**

---

## 1. O reinício de verdade — 17/09 às 21:47:32

```
BUG: unable to handle page fault for address: ffffcd2ce3817640
RIP: 0010:amdgpu_vm_pt_free+0x61/0xd0 [amdgpu]
     amdgpu_vm_pt_free_root+0x135/0x180 [amdgpu]
     amdgpu_vm_fini+0x31b/0x600 [amdgpu]
     amdgpu_driver_postclose_kms+0x1ab/0x290 [amdgpu]
     amdgpu_drm_release+0x5b/0xb0 [amdgpu]
Fixing recursive fault but reboot is needed!
```

Isto é um bug de verdade no driver: use-after-free no desmonte das page tables
da VM do amdgpu. Os `VM memory stats for proc Xwayland / nautilus / gnome-shell
is non-zero when fini` nas linhas anteriores mostram o caminho — a GPU foi
levada à exaustão e cada cliente DRM (Xwayland, nautilus, gnome-shell) fechou o
fd nessa hora.

O GNOME aparece na mensagem porque é um cliente da GPU, não porque seja a causa.
Ele morre de efeito colateral.

## 2. O "reinício" de 18/09 às 14:44 — não foi reinício

`uptime` na hora da auditoria: **22h40m sem parar**, desde 17/09 16:06. A máquina
não reiniciou. O que houve:

```
14:44:26  kernel: gmain invoked oom-killer: global_oom
14:44:26  systemd: user@1000.service: The kernel OOM killer killed some processes
14:44:45  systemd: org.gnome.Shell@ubuntu.service: The kernel OOM killer killed some processes
14:44:45  systemd: gnome-session-monitor / pipewire-pulse / xdg-desktop-portal / ...
14:45:09  gnome-shell: Shutting down GNOME Shell
14:45:20  systemd-logind: Removed session 52
14:45:27  gnome-shell[632651]: novo shell, sessão nova
```

**19 segundos de varredura, 8 processos mortos**: `lm-studio`, `antigravity-ide`,
`chrome-devtools` (2×), `language_server`, `python`, `lms`, `llama-server-fl`.
Depois o gdm subiu outra sessão. Visualmente é idêntico a um reinício; não é.

### O modelo exato

```
/run/media/leonardo/Windows/AIModels/_LMStudio_Links/puwaer/deepseek-v4-flash-reap/
    DeepSeek-V4-Flash-0731-reap-200b-IQ1_M.gguf     57 GB      criado 14:38
```

Baixado às 14:38. OOM às 14:44. Seis minutos.

### Por que o kernel não matou só o modelo

O OOM killer do kernel não sabe qual processo é o porcalhão. Ele pontua por
`oom_score` e varre o sistema. O `systemd-oomd` está ativo nesta máquina
(`enabled`, `active`), mas ele só age por **pressão de memória dentro de um
cgroup** — e essa pressão nunca chega a se formar antes de o kernel agir.

Resultado: em vez de morrer um processo, morre a sessão.

---

## 3. A conta que não fecha

O que a máquina tem hoje:

| recurso | valor |
|---|---|
| RAM física | 93,7 GB |
| carve-out UMA (BIOS) | **48,00 GiB** |
| RAM visível ao Linux | **45,65 GiB** |
| swap | 8 GiB |
| iGPU, memória DEVICE_LOCAL | 48,00 GiB (0,33 em uso) |

Orçamento seguro para um modelo (regra do `memguard.py`):

```
GPU  = (48,00 − 0,33) × 0,80      = 38,14 GiB   (20% p/ compositor + command submission)
CPU  = 42,08 − 10,00              = 32,08 GiB   (swap NÃO conta)
TETO                              = 70,22 GiB
```

Por que 80% do carve-out e não 100%: já foi medido nesta máquina que encher o
carve-out produz

```
amdgpu: The CS has been rejected (-12)
amdgpu_vm_validate() failed
Not enough memory for command submission!
```

e mata o gnome-shell. O anel de command submission e o compositor precisam de
folga.

Por que swap não conta: pesos são lidos **uma vez por token**. Qualquer byte de
peso que vá para swap é relido do disco a cada passo de decode. A máquina não
fica lenta — ela para. Foi contar swap como folga que fez o plano do DeepSeek
"caber no papel" e morrer na prática.

### Onde cada modelo cai

| modelo | tamanho | precisa | veredito | medido |
|---|---|---|---|---|
| Qwen3-Coder-30B-A3B Q4_K_S | 16,26 GiB | 18,05 GiB | **OK** | **37,0 t/s** decode, 404 t/s prefill |
| Ternary-Bonsai-27B Q2_g64 | 7,06 GB | ~8 GiB | **OK** | ~7,6 t/s (estimado) |
| DeepSeek-V4-Flash reap-200b IQ1_M | 56,36 GiB | 57,70 GiB | **RECUSADO** | OOM global |
| Qwen3.8-Flash-Next-131B Q3KXL | 60,34 GiB | 62,00 GiB | **RECUSADO** | — |

O DeepSeek *cabe no teto* (57,70 < 70,22). Ele é recusado por outro motivo:
não cabe no iGPU, então sobrariam **19,56 GiB (61% da RAM do sistema) para a
CPU**, com o carve-out cheio a 100%. Offload parcial é exatamente a configuração
em que esta máquina já falhou duas vezes — e cujo modo de falha não é uma
exceção do llama.cpp, é OOM global ou BUG no kernel.

---

## 4. O que foi instalado para corrigir

### `memguard.py` — recusa antes de carregar

```bash
./memguard.sh                                     # orçamento atual
./memguard.sh modelo.gguf --ctx 32768 --kv-type q8_0
./memguard.sh modelo.gguf --ctx 32768 -- llama-server -m modelo.gguf ...
```

Sai com código 3 e **não executa** o comando se o veredito for RECUSADO.
Soma splits multi-parte (`-00001-of-00003`), calcula o KV cache pelo tipo
(`-ctk/-ctv`), e mostra quantas camadas vão para a GPU.

Testes: `apex_harness/tests/test_memguard.py` (11 casos, cobrindo as três
configurações reais acima).

### `proteger_sessao.sh` — rede de segurança para o desktop

O guard acima só protege o que passa por ele. Se o modelo for carregado pela
interface do LM Studio, ninguém consulta o guard. Este script instala o
`earlyoom`, que olha a memória livre do **sistema** e mata o maior consumidor
antes do kernel varrer tudo:

```bash
sudo ./proteger_sessao.sh
```

`--prefer` aponta para `llama-server|lms|lm-studio|python|ollama|koboldcpp`;
`--avoid` protege `gnome-shell|gdm|Xwayland|systemd|dbus-daemon|pipewire|sshd`.

---

## 5. O que fazer com o DeepSeek

O `DeepSeek-V4-Flash-0731-reap-200b-IQ1_M.gguf` de 57 GB **não roda** nesta
configuração. Não existe flag que resolva: o teto é 70 GiB e o modelo precisa
de 38,14 GiB no iGPU + 19,56 GiB na CPU com zero margem.

Ele só passaria a caber com o carve-out reduzido no BIOS para **16 GiB ou menos**:

- RAM visível sobe para ~77 GiB, teto CPU ~67 GiB, teto total ~67 GiB
  (sem offload, porque o iGPU fica sem espaço rápido)
- o modelo roda **100% na CPU**: 10,07 GiB de pesos ativos por token
- banda medida: 118 GB/s a 12 threads → teto teórico ~11,7 t/s, realista **6–8 t/s**

Ou seja: mesmo no melhor cenário o DeepSeek entrega ~7 t/s, contra **37 t/s** do
Qwen3-Coder-30B-A3B que já está na máquina e já foi medido. **Três a cinco vezes
mais lento**, com qualidade de quantização IQ1_M.

E a troca é excludente: carve-out pequeno (CPU rápido, GPU inútil) e carve-out
grande (GPU 2× mais rápido que a CPU) são requisitos opostos. Com 16 GiB de UMA
o Vulkan passa a ser 2,5× **mais lento** que a CPU — medido.

---

## 6. UMA: 48 GiB → 32 GiB — medido, e é uma troca ganha

Feito em 18/09 às 15:00. `mem_info_vram_total` = `34359738368` (32 GiB).
RAM visível subiu de **45,65 → 61,40 GiB**.

Medição limpa, mesmas flags nos dois casos (`-c 32768 -np 1 -fa on -ctk/-ctv
q8_0 -b 2048 -ub 512 --cache-reuse 256 -t 12`), modelo Qwen3-Coder-30B-A3B
Q4_K_S, prompt de 512 tokens:

| | prefill | decode | TTFT | VRAM |
|---|---|---|---|---|
| **48 GiB**, Vulkan `-ngl 999` | 404,81 t/s | 37,03 t/s | 914,6 ms | 40,76 GiB |
| **32 GiB**, Vulkan `-ngl 999` | **418,56 t/s** | **36,99 t/s** | **886,0 ms** | 18,21 GiB |
| **32 GiB**, CPU `-ngl 0` | 249,40 t/s | 19,60 t/s | 1467,2 ms | 0,64 GiB |

Vulkan continua ganhando da CPU por **1,89×** no decode e **1,68×** no prefill.
48 vs 32 GiB dá o mesmo desempenho — prefill e TTFT ficaram até um pouco
melhores — e você ganha **15,75 GiB de RAM visível**. Foi a escolha certa.

### A armadilha que quase produziu a conclusão oposta

Conferir isto de dentro de um sandbox que esconde `/dev/dri` dá um resultado
completamente falso, e **sem erro nenhum**:

```
$ llama-server --list-devices
Available devices:
  (none)                          <-- o Vulkan nem aparece

$ ls /dev/dri
No such file or directory

$ llama-server ... -ngl 999       # aceita -ngl 999 sem reclamar
```

O auto-fit do llama.cpp vê zero dispositivos, põe **todas as 48 camadas na CPU**,
e o `/api/models` continua reportando o modelo carregado normalmente:

```
common_params_fit_impl: getting device memory data for initial parameters:
load_tensors: layer 0  assigned to device CPU
load_tensors: layer 1  assigned to device CPU
...
```

Medido assim, o "Vulkan" deu 26,79 t/s e prefill 128,06 t/s, com VRAM em 0,41
GiB — números plausíveis, ~30% piores que a realidade, e que são de CPU.
`benchmarks/medir_uma.sh` existe para não repetir isso: checa `/dev/dri` e
`--list-devices` **antes** de medir e aborta com código 4 se a GPU estiver
invisível. A prova que ele usa é a VRAM (sem offload fica em ~0,6 GiB; com
offload, dezenas de GiB), porque contar linhas `assigned to device` não funciona
— o servidor só as imprime em `-lv 5`.

### Flags do plano que falhavam em silêncio

Duas linhas que o `hwtune` gerava e que **não faziam nada** nesta máquina:

| flag | o que acontecia |
|---|---|
| `-lm mmap+mlock` | `failed to mlock 436264960-byte buffer: Cannot allocate memory` — o hard limit de `RLIMIT_MEMLOCK` é 8192 KB e não sobe sem root. Caía para mmap normal. |
| `--prio 2 --prio-batch 2` | `failed to set process priority 2 : Permission denied` + `failed to set thread priority 2 : Operation not permitted` — **6180 vezes** num único log. Requer `CAP_SYS_NICE`. |

Corrigido: `plan_server_command()` agora detecta `RLIMIT_MEMLOCK` e `CapPrm`
bit 23, emite `-lm mmap` e omite o `--prio` quando não há capacidade. O
`--defrag-thold 0.1` também saiu — a b10456 já o marca como obsoleto.

---

## 7. Comandos

```bash
cd /home/leonardo/apex_harness

# orçamento atual
./memguard.sh

# o DeepSeek que derrubou a máquina
./memguard.sh "/run/media/leonardo/Windows/AIModels/_LMStudio_Links/puwaer/deepseek-v4-flash-reap/DeepSeek-V4-Flash-0731-reap-200b-IQ1_M.gguf" --ctx 32768

# o que roda bem
./memguard.sh "/run/media/leonardo/Windows/AIModels/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf" --ctx 32768

# proteger a sessão (precisa de sudo)
sudo ./proteger_sessao.sh

# ver o earlyoom agindo
journalctl -u earlyoom -f
```

```bash
# o backend sobe sozinho no login (unidade systemd de utilizador).
# Se precisar de o controlar a mao:
systemctl --user status  apex-backend.service
systemctl --user restart apex-backend.service
journalctl --user -u apex-backend -f

# conferir o estado num relance (VRAM + porta)
./instalar_servico.sh --estado

# subir a mao, sem systemd
./arrancar_backend.sh

# medir CPU vs Vulkan com prova de que a GPU foi usada
./benchmarks/medir_uma.sh
```

---

## 8. O backend sobe sozinho no login

Instalado em 18/09 às 15:36: `~/.config/systemd/user/apex-backend.service`
(`enabled` para `default.target`).

Sem isto, cada reboot reproduzia o problema: o harness **nao carrega modelo**, ele
so procura `127.0.0.1:8080/v1`. Sem backend, `/api/status` responde `"offline"`,
o turno nunca fecha, e o `finally` que reabilitaria o botao de enviar nunca corre
— ou seja, voce escreve o segundo comando e nao consegue enviar.

O que a unidade garante:

| | |
|---|---|
| `arrancar_backend.sh --foreground` | faz `exec`, nao `setsid &`, para o systemd ser dono do PID e conseguir supervisionar |
| `ExecStartPost=esperar_pronto.sh` | `systemctl start` so retorna quando o modelo esta mesmo a servir, e **falha se a VRAM ficar abaixo de 2 GiB** (o sinal de que a GPU nao foi usada) |
| `SuccessExitStatus=3 4` | recusa do memguard e resultado final, nao falha — evita ciclo de reinicio a tentar carregar algo que nunca cabe |
| `After=default.target` | arranca com a sessao, depois de `/run/media/leonardo/Windows` estar montado |

### Dois erros que a instalacao apanhou

1. **`SupplementaryGroups=render video` → `status=216/GROUP`.** Num serviço de
   *utilizador* o systemd nao consegue aplicar grupos suplementares e a unidade
   morre no arranque. Nao e preciso: um processo de utilizador herda os grupos da
   propria conta, e o `leonardo` ja esta em `render` e `video`.

2. **`MODELO="${1:-...}"` apanhava `--foreground` como se fosse o caminho do
   modelo.** O launcher agora faz um parse a sério dos argumentos.

### Operacao

```bash
./instalar_servico.sh --estado     # estado + VRAM + porta
./instalar_servico.sh              # reinstalar / atualizar
./instalar_servico.sh --remover    # desinstalar
```

Para trocar de modelo sem editar a unidade, use a variável de ambiente:

```bash
systemctl --user edit apex-backend.service    # cria um drop-in
# [Service]
# Environment=APEX_CTX=16384
# Environment=APEX_LLAMA_PORT=8080
```

---

## 9. Auditoria dos atalhos do desktop (18/09, 15:45)

Pergunta: *"o atalho do desktop está com todas as modificações?"* Resposta: **não
estava.** O bug era pior do que parecia.

### O monkeypatch nunca chegava ao call site

O `launcher.py` fazia, por esta ordem:

```python
from launcher_common import (..., launch_llama_server, ...)   # liga a funcao ANTIGA
...
import launcher_common as _lc
_apex_install(_lc)                                            # substitui SO no modulo
print("[Apex] Servidor optimizado activo")
```

`from X import nome` **copia a referência** para o namespace local. Substituir
`launcher_common.launch_llama_server` depois disso não muda o nome que o ficheiro
já tem ligado. A linha que arranca o servidor chama o nome local — portanto usava
a função **antiga**, enquanto imprimia "Servidor optimizado activo". Provado:

```
launch_llama_server is _lc.launch_llama_server   ->  False
hasattr(launch_llama_server, '__wrapped_original__')  ->  False
```

**Nenhum dos dois atalhos usava as flags afinadas.** A correção é importar o
módulo, aplicar o patch, e só então ligar os nomes. Depois disso: `True` / `True`.

### O que foi corrigido

| | antes | depois |
|---|---|---|
| `LD_PRELOAD=libdrm_amdgpu.so.1` | injetado num processo Vulkan | removido |
| `HSA_OVERRIDE_GFX_VERSION`, `HSA_ENABLE_SDMA`, `HIP_VISIBLE_DEVICES`, `AMD_GPU_BUILD_TARGET` | bloco ROCm inerte no binário Vulkan, com o comentário *"CRÍTICO: previne crash do kernel"* | removidos |
| `RADV_PERFTEST=coop_matrix,nogttspill` | `coop_matrix` não é ganho estável (llama.cpp#16339) | removido |
| `--cpu-strict 1`, `--no-webui`, `--metrics`, `--timeout 3600`, `-n 16384` | ausentes | presentes |
| `-lm` | ausente | `mmap` (mlock é impossível, ver secção 6) |
| `pkill -9 -f llama-server` | matava o `apex-backend.service` e podia matar a própria shell | `stop_backend_8080()`: systemd → pidfile → `fuser` |

### A regressão que quase passou despercebida

Ao verificar o comando real, apareceu `--spec-type ngram-simple` a ser ligado
**no Swift-Qwen3.8-27B** — que é o modelo pré-selecionado do atalho, e exatamente
o caso medido como **0,28× (3× mais lento)**: aceitação 0,00% (0/96), decode
3,375 → 1,191 t/s.

O `hwtune` **já tinha esse aviso escrito nos comentários** e emitia o flag na
mesma. Avisar e continuar a fazer a coisa errada é pior do que não avisar: deixa
a impressão de que o risco foi tratado.

Corrigido com deteção automática a partir do **próprio chat template do GGUF**,
não do nome (renomear o ficheiro não pode mudar o comportamento do motor):

```
Swift-Qwen3.8-27B     template 8952 chars -> '<think', 'enable_thinking'  => PENSA
Qwen3-Coder-30B-A3B   template 6896 chars -> so 'reasoning'               => nao pensa
```

`reasoning` sozinho dá falso positivo — aparece no template do modelo de código.
O marcador que separa é `<think` / `enable_thinking`.

Verificação do comando real de cada modelo:

| modelo | spec-type | env sujo | --prio |
|---|---|---|---|
| Swift-Qwen3.8-27B | DESLIGADO | nenhum | omitido |
| Qwen3-Coder-30B-A3B | ngram-simple | nenhum | omitido |

Testes: `apex_harness/tests/test_hwtune.py` (7 casos, cobrindo a deteção de
modelo de raciocínio, o `--prio` sem `CAP_SYS_NICE`, o `RLIMIT_MEMLOCK` pequeno e
o `--defrag-thold` obsoleto).

Backups dos ficheiros originais em `backups/ANTES_DO_ATALHO_20260918_154203/`.

---

## 10. O botão de enviar morria depois da primeira pergunta (18/09, 16:00)

Sintoma: a primeira pergunta responde, e a partir daí clicar em Enviar **e**
premir Enter não fazem nada.

### Causa: o `/api/chat` nunca fechava o stream SSE

O `_handle_post_chat` respondia com

```python
self.send_header("Connection", "keep-alive")
```

O `BaseHTTPRequestHandler` trata este cabeçalho de forma especial: ao ver
`keep-alive` põe `self.close_connection = False`. Mas uma resposta SSE **não tem
`Content-Length`** — o único terminador que o browser conhece é o EOF do socket.

Do lado do cliente, `web/app.js`:

```js
while (true) {
  const { value, done } = await reader.read();
  if (done) break;          // nunca acontecia
}
...
} finally {
  isGenerating = false;
  btnSend.disabled = false; // nunca corria
}
```

E o guarda que bloqueia tudo:

```js
if (!message || isGenerating) return;    // app.js:265
```

Medido: `/api/chat` pendurava **170 s** (timeout do curl) em vez de fechar —
**mesmo quando a resposta era um sucesso completo com o evento `done` já
enviado**. Não era um problema só do caminho de erro; era de todos.

### Correcção

- Servidor: `Connection: close`, e um `finally` que garante **sempre** um evento
  terminal e `self.close_connection = True`, mesmo se o `agent.step()` rebentar a
  meio.
- Cliente (segunda barreira): o loop deixa de depender do EOF e sai ao ver `done`
  ou `error`, com `reader.cancel()`.
- `_serve_static_file` passa `Cache-Control: no-store`: sem isto o browser
  guardava `app.js` em cache e continuava a correr JavaScript antigo depois de o
  ficheiro em disco ser corrigido — o que faz uma correcção parecer que não
  funcionou.

Medição depois da correcção:

| | antes | depois |
|---|---|---|
| `/api/chat` sucesso | pendura 170 s | fecha em **2,1 s** |
| `/api/chat` erro | pendura 170 s | fecha em **2,6 s** |
| pedido seguinte a um erro | não é possível | **funciona** |
| 3 mensagens seguidas | 1ª só | **todas**, 15,8 s / 0,4 s / 0,4 s |

Os 408 ms das mensagens 2 e 3 são o reaproveitamento do prefixo KV (a linha 1 paga
o prefill). **É preciso recarregar a página no browser** uma vez, para apanhar o
`app.js` novo.

### O que NÃO consegui determinar

Porque é que o servidor do atalho "Apex Web Harness" não subiu às 15:50, depois de
parar o `apex-backend.service`. A única evidência que sobrou é
`/tmp/llama-server-8080.log` com **0 bytes**: o ficheiro foi criado (portanto o
launcher chegou a construir o comando) mas nunca recebeu nada, porque o atalho web
nunca chamou `stream_server_output()` para drenar o pipe. O registo que explicaria
o falhanço era exactamente o que não estava a ser escrito.

Testei duas hipóteses e **ambas foram refutadas** com medição:

- *O pipe enche e bloqueia o servidor.* Falso: mesmo com um modelo de 11,8 GiB o
  llama-server b10456 só produz ~1,7 KB de log em verbosidade normal, muito
  abaixo dos ~64 KB do buffer.
- *O servidor morre com EPIPE no primeiro pedido depois de o launcher sair.*
  Falso: sobreviveu ao pedido, nos dois modos.

O que ficou corrigido na mesma, porque é correcto independentemente da causa:

| | antes | depois |
|---|---|---|
| log do servidor no atalho web | **0 bytes** (inútil) | conteúdo real |
| `stdout` do llama-server | pipe sem leitor | ficheiro (`log_to_file=True`) |
| servidor do atalho falha ao subir | 8080 fica **morta** | rede de segurança repõe o `apex-backend.service` |

A rede de segurança é o que importa para ti: mesmo que o modelo escolhido no
atalho não arranque, a 8080 nunca fica sem backend — e sem backend o harness
respondia `"offline"` e o botão prendia.

---

## 11. Contagem de tokens na janela (18/09, 16:45)

Pedido: contagem de tokens na parte de baixo (leitura e escrita) e caixa de texto
que cresce enquanto se escreve.

### O número que estava lá era falso

`server.py:379` fazia:

```python
est_tokens = total_chars // 4
```

Divisão de caracteres por 4. Serve para inglês corrente; em português anda perto
de 3 caracteres por token e em código erra mais. Medido com o tokenizer real:

| texto | `len//4` dizia | tokens reais |
|---|---|---|
| `def soma(a,b): return a+b` | **6** | **11** |
| `Ola mundo, isto e um teste de contagem de tokens.` | 12 | 13 |

Quase metade, num caso. E o `usage` já vinha do servidor: o llama-server manda um
chunk final com `choices` VAZIO e `usage`/`timings` preenchidos, que o loop de
leitura descartava com `if not chunk.choices: continue`. Era só preciso não o
deitar fora.

### O que a barra mostra

```
📖 Leitura  [contexto] + [msg]     ✍️ Escrita  [última] · [sessão]     contexto % · t/s · ♻ cache
```

- **Leitura** = o que o MODELO lê: os tokens do contexto (o último prompt enviado,
  do `usage.prompt_tokens`) mais os da mensagem que está a ser escrita, contados
  pelo tokenizer real do modelo via `/api/tokenize`.
- **Escrita** = o que o modelo escreveu, na última resposta e somado na sessão.
- **♻ cache** = quanto do prompt veio do KV cache. Medido num teste de 3 turnos:
  `leitura=5933, cache=5920, novo=0` — **99,8%** servido da cache.

### Ficheiros

| ficheiro | mudança |
|---|---|
| `core.py` | `stream_options={"include_usage": True}`, `_capture_usage()`, `on_usage`, contadores de sessão |
| `server.py` | `/api/tokenize` (proxy para o `/tokenize` do llama-server), campos novos no `/api/status`, evento SSE `usage` |
| `index.html` | barra `.token-bar` na `footer` |
| `style.css` | barra, `align-items: flex-end`, `max-height: 40vh` (era 120px) |
| `app.js` | auto-crescimento da caixa, contagem com debounce, eventos `usage` |

Se o backend não souber tokenizar, o `/api/tokenize` devolve a estimativa marcada
com `estimated: true` — a interface mostra-a na mesma, sem fingir que é exata.

### O erro "resposta vazia"

No mesmo ensaio apareceu, e a causa era real, não cosmética.

Um modelo de raciocínio servido pelo llama-server manda o pensamento em
`delta.reasoning_content` e a resposta em `delta.content` — são campos
independentes. Medido:

```
reasoning_content = 98 chars   ("The user wants me to say only ok...")
content           =  2 chars   ("ok")
```

O `step()` só acumulava `delta.content`. Quando o modelo terminava sem chegar a
escrever `content`, o acumulador ficava vazio, **o raciocínio era deitado fora**, o
turno morria com "resposta vazia" e nada ficava no histórico.

Corrigido: o raciocínio é acumulado à parte e, se não houver resposta nenhuma,
é usado como resposta em vez de se perder. Testado em
`apex_harness/tests/test_reasoning_only.py`.

**Nota:** o modelo `Instinct-Python-Coder-Gemma4-12B` responde mal a este system
prompt — em vários turnos produziu só o bloco de pensar, sem resposta. A correção
impede que isso custe o turno, mas a causa é o modelo, não o harness.

---

## 12. Loop degenerativo, especulação inútil e qual o melhor modelo (18/09, 17:35)

### O sintoma

O raciocínio repetia indefinidamente: `pode ajustar o curriculo...` → plano em
inglês → `pode ajustar o curriculo...` → plano em inglês. Sem nunca produzir
resposta, e o harness ficava "a trabalhar" para sempre.

### Causa 1: amostragem sem penalização de repetição

Parâmetros efetivos durante o loop:

```
temperature        0.2   <- o harness impõe isto (o servidor usa 0.8)
repeat_penalty     1.0   <- DESLIGADO
frequency_penalty  0.0   <- DESLIGADO
presence_penalty   0.0   <- DESLIGADO
```

Temperatura 0.2 + zero penalização: a sequência repetida tem sempre a
probabilidade mais alta e **nada empurra o modelo para fora do ciclo**. É a
receita clássica para um loop degenerativo.

Medido neste servidor, com um prompt feito para induzir repetição:

| | repetições da mesma linha |
|---|---|
| sem penalização | **2** |
| `repeat_penalty=1.15` | **1** |
| `dry_multiplier=1.1` | **1** |

Corrigido: `ApexAgent(repeat_penalty=1.1)`, enviado em `extra_body` (é extensão
do llama-server, não faz parte do esquema OpenAI). 1.1 é suave de propósito:
quebra o ciclo sem estragar repetição legítima (código, nomes, listas). Se um
backend recusar o campo, o pedido é repetido sem ele — a contagem de tokens é um
extra, não pode custar a resposta.

### Causa 2: a especulação estava a custar desempenho

`--spec-type ngram-simple` estava ligado por omissão. O ganho de 1,95× foi medido
num prompt **sintético** de código. Na carga **real** do harness, lido no
`/metrics` do próprio servidor:

```
spec_decode_num_accepted_tokens_total  22
spec_decode_num_draft_tokens_total    144      ->  15,3%
```

Muito abaixo dos ~60% que o `hwtune` documenta como necessários. Cada draft
rejeitado paga uma passagem de verificação a mais sem devolver nada.

Corrigido: desligado por omissão (`APEX_SPEC=1` para ligar e testar num workload
concreto, confirmando a linha `draft acceptance = X` no log).

### O pedido preso bloqueava tudo

O servidor arranca com `-np 1` — **uma única slot**. Enquanto o pedido em loop
estava a ser gerado, qualquer medição externa ficava **em fila**, e era isso que
produzia leituras absurdas (prefill 17,93 t/s, TTFT a variar 10–29 s para o mesmo
prompt). Não era o sistema a estar lento; era contenção.

Confirmado por amostragem do `/metrics`: `requests_processing 1`, e
`tokens_predicted_total` a subir 1230 → 1277 em 20 s = **2,35 t/s**.

### Resultado

| | antes | depois |
|---|---|---|
| decode | 18,28 t/s | **36,80 t/s** |
| prefill | 228,50 t/s | **415,82 t/s** |
| drafts especulativos | 144 (15,3% aceites) | **0** |
| `requests_processing` | 1 (preso) | **0** |

### Qual o melhor modelo dos que tem

O decode nesta APU é limitado por **banda**: lê-se `pesos_ativos_por_token` a
~60 GB/s. Por isso um modelo de 30B pode ser 10× mais rápido que um de 12B —
o que importa não é o tamanho, é quanto se lê por token.

| modelo | tamanho | ativo/token | t/s | |
|---|---|---|---|---|
| **Qwen3-Coder-30B-A3B** | 16,26 G | **1,63 G** | **37,0** | ✅ medido |
| gemma-4-26B-A4B-QAT | 13,45 G | 2,07 G | ~29 | MoE, nunca usado |
| Nemotron-3.5-Lightning-30B-A3B | 22,83 G | 2,28 G | ~26 | MoE, nunca usado |
| GLM-4.7-Flash | 16,89 G | 3,43 G | ~18 | MoE |
| Qwen3-Coder-Next | 31,03 G | 5,17 G | ~12 | offload parcial |
| Instinct-Gemma4-12B | 11,80 G | 11,80 G | ~5 | denso |
| Muse-Glimmer-30B | 15,61 G | 15,61 G | ~4 | denso |
| granite-4.2-30b | 15,57 G | 15,57 G | ~4 | denso |
| Swift-Qwen3.8-27B Q4 | 16,79 G | 16,79 G | ~3,6 | denso |
| Swift-Qwen3.8-27B Q6 | 21,31 G | 21,31 G | ~2,8 | denso |
| Qwen3.8-Flash-Next-131B | 60,34 G | 10,05 G | ~6 | não cabe |
| DeepSeek reap-200b | 56,36 G | 10,07 G | ~6 | não cabe (o que reiniciou a máquina) |

Os modelos escolhidos pelo utilizador (Muse-Glimmer, Instinct) e o que estava
pré-selecionado no atalho (Swift) eram **os quatro mais lentos de todos**.

Alterado: `PREFERRED_MODEL_NAME` passou de `Swift-Qwen3.8-27B-Q4_K_M.gguf` para
`Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf`. O Swift continua selecionável — isto
só decide qual vem com o botão já marcado.

**Nota:** `Ternary-Bonsai-2-27B-PQ2_0.gguf` **não carrega** —
`llama_model_loader: failed to load model`, confirmado no log. Usa o tipo de
quantização 142/143, que só existe no fork da PrismML. O oficial
`Ternary-Bonsai-27B-Q2_g64.gguf` (formato ggml Q2_0) carregaria.

---

## 13. Bonsai 2, o seletor que não avisa, e visão (18/09, 18:05)

### O que aconteceu

O Bonsai 2 foi escolhido no atalho e **falhou ao carregar**:

```
llama_model_load: error loading model: llama_model_loader: failed to load model
  from .../prism-ml/Ternary-Bonsai-2-27B-gguf/Ternary-Bonsai-2-27B-PQ2_0.gguf
srv llama_server: exiting due to model loading error
```

O atalho parou o `apex-backend.service`, tentou arrancar o servidor dele, o
servidor morreu — e a 8080 ficou sem backend. A rede de segurança repôs o
serviço, mas entretanto o harness respondeu erro.

### Porque falhou

Lido do cabeçalho GGUF:

| ficheiro | tensores | tipo |
|---|---|---|
| `Ternary-Bonsai-2-27B-PQ2_0.gguf` | 402 de 851 | **142** (PQ2_0) |
| `Ternary-Bonsai-2-27B-PTQ1_0.gguf` | 402 de 851 | **143** (PTQ1_0) |
| `Qwen3-Coder-30B-A3B-Q4_K_S.gguf` | — | 0, 12, 13, 14 (padrão) |

O enum `ggml_type` do llama.cpp mainline vai de 0 (F32) a 39 (MXFP4). **142 e 143
só existem no fork da PrismML.** Os dois ficheiros que estavam no disco são
desses formatos.

### O que ficou corrigido

`hwtune.read_gguf_tensor_types()` lê os tipos do cabeçalho e
`unsupported_quant_types()` devolve os que o mainline não conhece. O seletor de
modelos passa a mostrá-los como:

```
⛔ NAO CARREGA · prism-ml/Ternary-Bonsai-2-27B-gguf/Ternary-Bonsai-2-27B-PQ2_0.gguf
   [PQ2_0 (PrismML), so fork PrismML]
```

Assim vê-se **antes** de escolher, em vez de descobrir depois de esperar.

O ficheiro oficial `Ternary-Bonsai-27B-Q2_g64.gguf` (7,06 GB) usa o `Q2_0` do
ggml — tipo 35, mainline — e carregaria normalmente.

### O botão de enviar NÃO estava preso

Reproduzido com o backend em baixo, com o servidor web atual:

```
curl exit=0   (fechou, não pendurou)   2816 ms
Connection: close
data: {"type": "error", "content": "API Error: Failed to communicate ..."}
segundo pedido: curl exit=0
```

Fecha em 2,8 s e o pedido seguinte funciona — o botão recupera. O que se viu foi
o efeito da falha de carregamento, não uma regressão do SSE.

### Visão: o Qwen3 não aceita imagens, e o harness também não

- **Qwen3 é texto apenas.** Correto.
- O **Bonsai 2 tem projetor de visão** (`Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf`,
  601 MB), portanto o *modelo* saberia ver imagens.
- **Mas o Apex Harness não consegue enviar imagens de forma nenhuma:**
  `/api/chat` aceita só `{"message": "<texto>"}`, não há upload na interface, e o
  `_handle_post_model` **rejeita explicitamente** ficheiros `mmproj`:
  *"e um projetor de visao multimodal, nao um modelo de linguagem"*.

  O selo `vision` que aparece na lista de modelos vem dos metadados do LM Studio
  e é apenas informativo — não há caminho nenhum para lhe entregar uma imagem.

  Para haver visão seria preciso: campo de upload/colar, conteúdo multimodal no
  `messages`, e arrancar o llama-server com `--mmproj`. É trabalho por fazer.

---

## 14. Visão: imagens no harness (18/09, 18:40)

### Como funciona

Um modelo só vê imagens se o llama-server arrancar com `-mm/--mmproj FILE`. O
próprio servidor responde a isso no `/props`:

```json
"modalities": {"vision": false, "video": false, "audio": false}
```

Com projetor carregado passa a `"vision": true`. É esse o sinal que o harness usa
— não há adivinhas sobre que modelo "deve" saber ver.

### O que foi implementado

| peça | o que faz |
|---|---|
| `hwtune.find_mmproj()` | procura `*mmproj*.gguf` ao lado do modelo |
| `arrancar_backend.sh` | liga `-mm` sozinho quando encontra projetor; `APEX_MMPROJ=` força um caminho |
| `server.py:/api/vision` | lê `modalities` do `/props` e diz à interface se há visão |
| `server.py:/api/chat` | aceita `images: ["data:image/…"]`; **recusa com uma frase clara** se o backend não tiver visão |
| `core.step(images=…)` | monta `content` como lista de blocos (`text` + `image_url`) |
| `core.message_text()` | achata conteúdo multimodal em texto, para contagem de tokens, RAG e compactação |
| `index.html` / `style.css` / `app.js` | botão 🖼️, colar com Ctrl+V, arrastar para a caixa, miniaturas com × |

O botão fica **desativado** quando não há visão, com uma explicação — em vez de
existir e falhar a seguir.

### Redução no cliente

Uma foto de telemóvel tem vários MB; em base64 é um corpo de pedido enorme e
muitos tokens de visão. `app.js` reduz para **1280 px no lado maior** antes de
enviar. PNG pequeno fica PNG (texto de captura de ecrã nítido); o resto vai a
JPEG. Imagens já pequenas passam sem recompressão. Limite: 6 imagens por mensagem,
12 MB por data URL já codificada (validado também no servidor).

### O que NÃO consegui verificar

**O caminho da imagem até ao modelo, de ponta a ponta.** Não existe no disco
nenhum modelo multimodal que carregue: o único projetor é o do Bonsai 2
(`Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf`), e os ficheiros do Bonsai 2 que lá estão
usam quantizações da PrismML que o llama.cpp mainline recusa.

Verificado por teste: deteção do projetor, construção da mensagem multimodal,
achatamento do conteúdo, e a recusa clara quando não há visão
(`tests/test_vision.py`, 6 casos). Por verificar: o `-mm` a carregar a sério e o
modelo a descrever uma imagem.

### O Bonsai 2 serve para o teu cenário?

Lido do GGUF: `arch=qwen35`, 64 camadas, GQA 4, **suporta ferramentas**, e é
**modelo de raciocínio** (`<think`, `enable_thinking`).

| | Bonsai 2 27B | Qwen3-Coder-30B-A3B |
|---|---|---|
| tipo | **denso** | MoE (1,63 GiB ativos/token) |
| pesos/token | ~7 GiB | 1,63 GiB |
| t/s estimado | **~8,6** | **37,0** (medido) |
| ferramentas | sim | sim |
| raciocínio | sim (mais tokens por turno) | não |
| visão | **sim, com mmproj** | não |
| quantização | ternária 2-bit | Q4_K |

**Não, para o teu uso principal.** É ~4,3× mais lento, e por ser de raciocínio
gasta ainda mais tokens por turno — com o system prompt de ~4–6 mil tokens do
harness, cada turno sai caro. A quantização ternária de 2 bits também é um
terreno em que a qualidade reclamada (98,2% do FP16) é afirmação do autor, não
medida aqui.

**Onde faz sentido:** tarefas de imagem. É o único modelo que tens que pode ver, e
para isso é preciso primeiro o ficheiro oficial:

```bash
hf download prism-ml/Ternary-Bonsai-27B-gguf Ternary-Bonsai-27B-Q2_g64.gguf \
  --local-dir /run/media/leonardo/Windows/AIModels/prism-ml/Ternary-Bonsai-27B-gguf
```

O `Q2_g64` usa o `Q2_0` do ggml (tipo 35, mainline) e carrega. Depois é só
escolhê-lo no atalho: o `find_mmproj` encontra o projetor que já tens ao lado e
liga o `-mm` sozinho.
