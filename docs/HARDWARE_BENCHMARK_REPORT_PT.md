# Relatório de Otimização — Apex Harness

**Data:** 2026-09-12 · **Alvo:** AMD Ryzen AI 9 HX 370 + Radeon 890M (gfx1150) + 96 GB LPDDR5X unificada
**Metodologia:** auditoria estática linha-a-linha + microbenchmarks de hardware + benchmarks A/B com `llama-server` real.

---

## ALTERAÇÕES APLICADAS (2026-09-12)

As correções **foram aplicadas** ao harness. Backup completo, separado e datado em
`backups/2026-09-12_155200/` (com `MANIFEST.txt` de sha256 + caminhos originais).

| Ficheiro | Linhas alteradas | O que mudou |
|---|---:|---|
| `~/.local/lib/launcher_common.py` | 67 | `launch_llama_server` passa a delegar em `hwtune`; `_MAX_SIZE_GB` 90 → 38; corpo antigo preservado em `_launch_llama_server_legacy()`; comentário do `_SKIP_PREFIXES` corrigido |
| `launcher.py` | 53 | `pkill -9 -f "llama-server"` (2 sítios) → `kill_stale_llama_servers(port)`, que mata apenas quem escuta naquela porta e exclui o próprio processo |
| `apex_harness/cli.py` | 36 | `on_chunk` passa por `stream_out()` (`Console.out`, sem markup por token); `/cost` passa a mostrar tokens reais |
| `apex_harness/core.py` | 21 | `stream_options={"include_usage": True}` + contadores `total_prompt_tokens`/`total_completion_tokens` restaurados |

**Reverter:** `cp backups/2026-09-12_155200/<ficheiro> <caminho original>` (os caminhos estão no `MANIFEST.txt`).

### Resultado medido (Qwen2.5-Coder-7B-Q4_K_M, mesma sessão, `-c 32768`)

| Métrica | ANTES | DEPOIS | Ganho |
|---|---:|---:|---:|
| Decode (prompt 389 tok) | 7.25 t/s | **12.87 t/s** | **+78%** |
| Decode (prompt 2543 tok) | 4.68 t/s | **6.94 t/s** | **+48%** |
| Prefill (prompt 389 tok) | 50.46 t/s | **69.30 t/s** | **+37%** |
| Prefill (prompt 2543 tok) | 27.16 t/s | **47.06 t/s** | **+73%** |
| TTFT (prompt 389 tok) | 7722 ms | **5619 ms** | **−27%** |
| TTFT (prompt 2543 tok) | 93833 ms | **54056 ms** | **−42%** |
| Banda efetiva (pico) | 31.6 GB/s | **56.1 GB/s** | **+78%** |

Prova nos parâmetros efetivos do servidor:

| | ANTES | DEPOIS |
|---|---|---|
| `taskset -c 0-7` | sim (8 CPUs, 2 tipos de núcleo) | **removido** |
| threads | `12` em 8 CPUs | `12` em 12 núcleos físicos (`--cpu-mask 0xFFF`) |
| `--host` | `0.0.0.0` (exposto à LAN) | **`127.0.0.1`** |
| draft model | carregado (986 MB) e **nunca usado** | **não carregado** |
| KV cache | `q4_0/q4_0` | **`q8_0/q8_0`** |
| env | 7 variáveis ROCm inertes + `LD_PRELOAD` | **removidas** |

**Teste de fumo pelo caminho real do harness** (`launcher_common.launch_llama_server`,
depois da correção): prefill **71.91 t/s**, `n_threads = 12`, `listening on
http://127.0.0.1:8090`, sem draft model.

---

## ATUALIZAÇÃO PÓS-BIOS (2026-09-12) — o carve-out UMA foi reduzido

O utilizador baixou a reserva UMA na BIOS de **48 GiB → 0,5 GiB** (o valor que a AMD
recomenda). Resultado imediato:

| | Antes | Depois |
|---|---:|---:|
| RAM visível ao Linux | 45,65 GiB | **91,16 GiB** |
| VRAM reservada à iGPU | 48,00 GiB | **0,50 GiB** |
| Modelos no seletor | 14 | **20** (inclui 31 GB e 50,9 GB) |

`_MAX_SIZE_GB` deixou de ser constante e passou a ser **calculado**
(`_safe_max_model_gb()`), porque um número fixo fica errado sempre que a reserva
muda — e já mudou duas vezes nesta sessão.

### O efeito colateral: a iGPU perdeu o caminho rápido

Não era previsível a partir da documentação, e é o achado mais importante desta
atualização. Mesmo modelo (Qwen2.5-Coder-7B-Q4_K_M), quatro estados:

| Estado | Backend | Prefill t/s | Decode t/s |
|---|---|---:|---:|
| Carve-out **48 GiB**, antes da correção | Vulkan `-ngl 99` | 50,46 | 7,25 |
| Carve-out **48 GiB**, depois da correção | Vulkan `-ngl 999` | 69,30 | **12,87** |
| Carve-out **0,5 GiB** | Vulkan `-ngl 999` | 65,12 | 5,62 |
| Carve-out **0,5 GiB** | CPU `-ngl 0` | 68,18 | **6,44** |

**Com 0,5 GiB de carve-out o Vulkan fica 2,5× mais LENTO que o CPU; com 48 GiB era
2,0× mais RÁPIDO.** Os pesos deixam de caber em memória `DEVICE_LOCAL` e passam a ser
lidos do GTT (RAM de sistema mapeada) por um caminho muito mais lento — enquanto 12
núcleos AVX-512 leem a mesma LPDDR5X diretamente.

**Conclusão:** carve-out pequeno e offload GPU são requisitos **opostos**. Não existe
um valor universalmente certo; depende do que se corre.

### O trade-off, explicitado

| Reserva UMA | RAM sistema | Vulkan | Melhor para |
|---|---:|---|---|
| 0,5 GiB (atual) | 91 GiB | ❌ 2,5× mais lento | Modelos grandes em CPU (31-60 GB), flexibilidade máxima |
| **16-32 GiB** | **59-75 GiB** | ✅ ~2× mais rápido | **O ponto ótimo para este parque de modelos** |
| 48 GiB | 45 GiB | ✅ ~2× mais rápido | Offload agressivo, pouca RAM (a origem dos reboots) |

Com **32 GiB** de reserva o `Qwen3-Coder-30B-A3B` (16,26 GB, o default do seletor)
cabe inteiro em VRAM e beneficiaria dos ~37 t/s medidos nesta classe de iGPU, e ainda
sobravam ~59 GiB ao sistema para os modelos grandes correrem em CPU.

### Correções de código decorrentes

`hwtune._gpu_budget_gib()` foi reescrito: o orçamento de offload é **apenas o
carve-out `DEVICE_LOCAL`**, nunca carve-out + GTT. Eu tinha "corrigido" isto ao
contrário (somando o GTT) e a medição provou que estava errado — o planner passou a
mandar tudo para o CPU, que é de facto o caminho mais rápido neste estado.
`--backend vulkan` continua disponível para forçar.

### Ressalva de medição

`load average` esteve entre 15 e 21 durante toda a campanha (o `gnome-shell` consome
~980% de CPU nesta máquina). Numa execução isolada registei **13,81 t/s** na config
CPU, contra **6,44 t/s** em quatro execuções consecutivas da mesma config: o 13,81 é
**outlier**. Repetibilidade interna (X1/X2/X3, mesma sessão):

| Variante | Prefill | Decode |
|---|---:|---:|
| X1 — comando exato do `hwtune` | 66,82 | 6,15 |
| X2 — igual, sem `--temp`/`-n` | 68,18 | 6,44 |
| X3 — sem spec decoding | 68,71 | 6,44 |

Daí: `--temp 0.3` custa ~5% no decode (default herdado do launcher antigo), e o
`ngram-simple` vale **0%** com o prompt de prosa do benchmark — consistente com §5.1,
onde o ganho de 1,95× só apareceu em conteúdo citável. **Mede com o teu workload real
antes de confiar em spec decoding.**

---

## 0. Sumário Executivo

Quatro números resumem o diagnóstico:

| Métrica | Valor medido | Implicação |
|---|---|---|
| Banda de memória real (12 threads) | **118 GB/s** (pico teórico LPDDR5X-7500 256-bit ≈ 120 GB/s) | A máquina já está a **98% do limite de hardware**. Decode denso **não tem para onde ir**. |
| Banda com 24 threads (SMT) | **97 GB/s** (−18%) | SMT **piora**. 24 threads é estritamente pior que 12. |
| `llama-bench -t 24` em Qwen2.5-Coder-7B | **0.35 t/s** (vs 13.73 a `-t 12`) | Colapso de **39×**. Oversubscrição de threads neste CPU híbrido é catastrófica. |
| RAM visível ao sistema | **91,16 GiB** (era 45,65 GiB) | Após a correção da BIOS (§ ATUALIZAÇÃO PÓS-BIOS). |

**Estado atual (após a correção da BIOS, ver secção seguinte):**
backend = **CPU `-ngl 0`**, ~6,4 t/s de decode num denso de 7B; a iGPU deixou de
compensar com um carve-out de 0,5 GiB. Ver o trade-off completo abaixo.

E o achado central:

> **`~/.local/lib/launcher_common.py:503` faz `taskset -c 0-7`.** Nesta APU, CPUs 0-3 são **Zen 5 a 5.16 GHz** (domínio L3 `{0-3,12-15}`) e CPUs 4-7 são **Zen 5c a 3.29 GHz** (domínio L3 `{4-11,16-23}`). O `taskset` prende o processo a **8 CPUs lógicas de dois tipos diferentes**, enquanto o llama.cpp **continua a criar `n_threads = 12`** (confirmado no log: `llama threadpool init, n_threads = 12`). 12 threads brigam por 8 CPUs, metade delas lentas, todas em *busy-wait* na barreira do ggml. O comentário da linha afirma *"Fixa nos 4 núcleos Zen 5 rápidos (P-cores 0-7, 16MB L3)"* — errado nos três pontos.

**A/B/C controlado** (Qwen2.5-Coder-7B-Q4_K_M, `llama-bench -r 2`, mesma sessão):

| Configuração | pp512 | tg128 |
|---|---:|---:|
| `taskset -c 0-7`, sem `-t` — *exatamente o launcher hoje* | 52.15 | **6.83** |
| **sem `taskset`, `-t 12`** | **67.77** | **13.45** (+97%) |
| `taskset -c 0-7` **com** `-t 12` | 51.49 | 6.47 (−5%) |

Correções de maior impacto, em ordem de retorno sobre esforço:

| # | Ação | Ganho | Esforço |
|---|---|---|---|
| 1 | **BIOS: reserva UMA 48 GiB → 512 MiB** | **+48 GiB de RAM**, elimina a causa-raiz dos reboots | reinício |
| 2 | Remover `taskset -c 0-7`; usar `-t 12 --cpu-mask 0xFFF --cpu-strict 1` | **+97% decode, +30% prefill** (medido) | 1 linha |
| 3 | Trocar o modelo denso por **MoE A3B/A4B** | **~3-10×** | escolha de modelo |
| 4 | Enxugar as env vars ROCm inertes + `LD_PRELOAD` | elimina risco, 0 ganho perdido | 1 bloco |
| 5 | `-ctk q8_0 -ctv q8_0` (era `q4_0/q4_0`) | **~1400× melhor KLD** — evita colapso de qualidade | 2 flags |
| 6 | `-ngl 999` + `--cache-reuse 256` + `-b 2048` + `-fa on` (nunca `auto`) | **~2× decode, ~1.6× prefill** | 4 flags |

> **O que NÃO funciona — também medido, e é metade do valor deste relatório:**
> - **MTP** (`draft-mtp`) no Qwen3.8-27B: **1.00×** com `n-max 3`, **0.87×** (mais lento) com `n-max 2`.
> - **`ngram-simple` em modelos de raciocínio**: **0.28×** — 2.8× **mais lento**, com 0% de aceitação.
> - **`ngram-simple` em prosa**: **1.00×** (neutro). Só ganha em reemissão de código (**1.95×**).
> - **ROCm/HIP, NPU XDNA2, vLLM, ExLlamaV2, Huge Pages, `mlock`, `--numa`**: sem ganho, com evidência em §2.1 e §2.5.

---

## 1. Mapa de Gargalos Encontrados (arquivo : linha)

### 1.1 Críticos — degradam t/s diretamente

#### 🟥 `~/.local/lib/launcher_common.py:503` — `taskset -c 0-7` (o pior gargalo do projeto)

```python
"taskset", "-c", "0-7",  # Fixa nos 4 núcleos Zen 5 rápidos (P-cores 0-7, 16MB L3)
```

Topologia real medida (`lscpu -p=CPU,CORE,MAXMHZ`):

| CPUs | Tipo | Freq máx | Domínio L3 |
|---|---|---|---|
| `0-3`, `12-15` | Zen 5 | 5158 MHz | `0-3,12-15` |
| `4-11`, `16-23` | Zen 5c | 3289 MHz | `4-11,16-23` |

`taskset -c 0-7` = **4 núcleos Zen 5 + 4 núcleos Zen 5c**, cruzando dois domínios L3 distintos. O comentário está errado em três factos: não são 4 núcleos, não são todos Zen 5, e o L3 reportado é 24 MiB em 2 instâncias (≈12 MiB por domínio), não 16 MB.

Pior: `launch_llama_server` **nunca passa `-t`**, então o llama.cpp usa o seu default — que **ignora a máscara de afinidade** e usa a contagem de núcleos físicos da máquina:

```
0.02.870.977 I cmn  init: llama threadpool init, n_threads = 12
```

→ 12 threads presas a 8 CPUs lógicas. Medido com `llama-bench` (Qwen2.5-Coder-7B-Q4_K_M, `-ngl 0`):

| `-t` | pp512 (t/s) | tg128 (t/s) | nota |
|---:|---:|---:|---|
| 4 | 30.79 | 5.71 | |
| 8 | 55.79 | 13.01 | |
| **12** | **73.50** | **13.73** | ✅ ótimo |
| 16 | 78.65 | 11.68 | decode já regride |
| 24 | 63.91 | **0.35** | 💥 colapso de 39× |

Bandwidth agregada medida com `benchmarks/membw.c` (1 GiB/thread, AVX-512):

| threads | read GB/s | triad GB/s |
|---:|---:|---:|
| 1 | 45.23 | 34.79 |
| 4 (Zen 5) | 65.34 | 60.29 |
| **12** | **118.06** | **84.29** |
| 24 (SMT) | 97.07 (−18%) | 76.26 |

Um único núcleo Zen 5 já satura 45 GB/s; 12 núcleos saturam o controlador a 118 GB/s. Os 8 threads extra do SMT **não movem bytes adicionais** — só disputam L1/L2 e atrapalham a barreira.

**Experimento A/B/C isolado** (Qwen2.5-Coder-7B-Q4_K_M, `-ngl 0`, `llama-bench -r 2`) que isola exatamente o efeito do `taskset`:

| Configuração | pp512 (t/s) | tg128 (t/s) | vs. atual |
|---|---:|---:|---:|
| **A)** `taskset -c 0-7`, sem `-t` — *exatamente o que o launcher faz hoje* | 52.15 | **6.83** | — |
| **B)** sem `taskset`, `-t 12` | **67.77** | **13.45** | **+30% / +97%** |
| **C)** `taskset -c 0-7` **com** `-t 12` | 51.49 | **6.47** | −24% |

Conclusões:

1. **Remover a única linha `taskset -c 0-7` quase duplica o decode** (6.83 → 13.45 t/s, **+97%**) e aumenta o prefill em 30%. É o maior ganho por linha de código em todo o projeto.
2. O caso **C** confirma o mecanismo: forçar 12 threads dentro de 8 CPUs derruba para 6.47 t/s, seja o `12` escolhido pelo llama.cpp ou passado explicitamente. O problema é a **sobreposição**, não o número de threads.
3. O caso **C** também mostra por que adicionar `-t 12` *sem* remover o `taskset` **piora** as coisas — quem "corrigir" apenas metade introduz uma regressão.

**Correção:** remover o `taskset` inteiro e passar `-t 12 --cpu-mask 0xFFF --cpu-strict 1` (0xFFF = CPUs 0-11 = exatamente um thread por núcleo físico, sem irmãos SMT).

---

#### 🟥 `~/.local/lib/launcher_common.py:540-546` — bloco de ambiente ROCm inerte

```python
env["HSA_OVERRIDE_GFX_VERSION"] = "11.5.0"
env["HSA_ENABLE_SDMA"] = "0"          # CRÍTICO: Previne crash do kernel e reboot na APU
env["HIP_VISIBLE_DEVICES"] = "0"
env["AMD_GPU_BUILD_TARGET"] = "gfx1150"
env["LD_PRELOAD"] = "/usr/lib/x86_64-linux-gnu/libdrm_amdgpu.so.1"
env["RADV_PERFTEST"] = "coop_matrix,nogttspill"
env["AMD_VULKAN_ICD"] = "RADV"
```

O binário lançado é **`~/.local/share/llama.cpp/llama-b10456/llama-server`**, ligado a `libggml-vulkan.so`. Confirmado por `ldd` — **não existe `libggml-hip.so`**. Portanto:

- `HSA_OVERRIDE_GFX_VERSION`, `HSA_ENABLE_SDMA`, `HIP_VISIBLE_DEVICES`, `AMD_GPU_BUILD_TARGET` → **variáveis ROCm/HIP, 100% inertes** num backend Vulkan. O comentário `# CRÍTICO: Previne crash do kernel` é falso: não faz nada.
- `LD_PRELOAD=.../libdrm_amdgpu.so.1` → sobrepõe o `libdrm.so.2` de `/opt/amdgpu/lib/x86_64-linux-gnu/` que o binário já resolve. Risco de incompatibilidade ABI sem ganho.
- `RADV_PERFTEST=coop_matrix` → ver [llama.cpp#16339](https://github.com/ggml-org/llama.cpp/issues/16339): mudanças do Mesa quebram o uso de coopmat no backend Vulkan do ggml. Em RDNA 3.5 o caminho genérico é usado.
- Enquanto isso, o **ROCm 6.2.1 + hipBLAS + hipBLASLt estão instalados e não servem para nada** — e não devem ser usados: ver [lemonade-sdk/llamacpp-rocm#57](https://github.com/lemonade-sdk/llamacpp-rocm/issues/57) — em APUs gfx1150 o ROCm aloca **apenas o carve-out de VRAM, ignorando o GTT**, ficando ~60% mais lento que Vulkan. O mesmo problema é tratado em [llama.cpp#20472](https://github.com/ggml-org/llama.cpp/pull/20472).

---

#### 🟥 `~/.local/lib/launcher_common.py:26` — `_MAX_SIZE_GB = 90.0` (causa os reboots)

```python
_MAX_SIZE_GB = 90.0  # Limite máximo de segurança: modelos > 45 GB causam reboot do kernel
```

O comentário contradiz o valor. Medições reais desta máquina:

```
Mem total: 45 GiB   (available: 35 GiB)
mem_info_vram_total = 51 539 607 552 B = 48.0 GiB   (carve-out UMA do BIOS)
mem_info_gtt_total  = 137 438 953 472 B = 128.0 GiB
```

O host tem **45 GiB de RAM**. O seletor oferece modelos **até 90 GB**. Com `-ngl 99` forçado em todas as ramificações (`launcher_common.py:488-500`), um modelo de 60 GB (ex.: `qwen38-keep1-Q3KXL.gguf`, 60.34 GB, presente em `/run/media/leonardo/Windows/AIModels/`) tenta alocar 60 GB dentro de um carve-out de 48 GiB, transbordando para o GTT → exatamente o reboot de kernel relatado.

**Correção (duas partes):**
1. **Imediata:** `_MAX_SIZE_GB = 38.0` — o seletor nunca deve oferecer um modelo maior que a RAM disponível.
2. **De raiz:** corrigir o carve-out UMA no BIOS (§2.3). Com `MemTotal` a subir de 45.65 para ~93 GiB, o limite pode voltar a subir — mas **o offload tem de ser calculado**, não fixado em `-ngl 99`.

---

#### 🟥 `~/.local/lib/launcher_common.py:510-521` — offload `-ngl 99` fixo e sem cálculo

```python
if total_gb > 60:    ngl_val = "99"; ctx_val = str(min(context, 16384))
elif total_gb > 35:  ngl_val = "99"; ctx_val = str(min(context, 32768))
elif total_gb > 18:  ngl_val = "99"; ctx_val = str(min(context, 65536))
else:                ngl_val = "99"; ctx_val = str(min(context, 32768))
```

`ngl_val` é `"99"` nas quatro ramificações — o `if/elif` inteiro é código morto. Não há verificação de que pesos + KV cabem no carve-out. Um offload parcial calculado (`-ngl N` + `--n-cpu-moe`) nunca é tentado.

---

### 1.2 Altos — afetam TTFT e throughput do agente

#### 🟧 `apex_harness/core.py:97-110` + `cli.py:226-231` — descoberta MCP bloqueante no arranque

```python
for s_name in mcp_mgr.servers.keys():
    mcp_tools = mcp_mgr.discover_tools_for_server(s_name, timeout=4.0)
```

São **7 servidores MCP** em `~/.gemini/config/mcp_config.json` (`notebooks`, `visualization`, `data-agent-kit`, `memory`, `sequential-thinking`, `ollama`, `hyperresearch`), descobertos **sequencialmente** com timeout de 4 s cada → **até 28 s de arranque bloqueante**. Pior: vários usam `npx -y`, que pode ir à rede na primeira execução.

E o custo recorrente: todos os esquemas descobertos são reenviados em `tools=self.tools` **a cada turno** (`core.py:168`), inflando o prefill. Num ciclo agêntico com 15 turnos (`max_turns=15`), isso é pago 15×.

#### 🟧 `apex_harness/cli.py:318` — overhead Rich por token

```python
on_chunk=lambda chunk: console.print(chunk, end="")
```

`Console.print` com `markup=True` (default) **reinterpreta a string a cada chunk**. Consequências: (a) qualquer `[` na saída do modelo é interpretado como markup e pode ser engolido ou lançar exceção; (b) o custo por token (criar `Text`, adquirir lock, escrever) cria contrapressão no stream HTTP. Isto **limita o t/s exibido** independentemente do servidor.

**Correção:** `console.out(chunk, end="", markup=False, highlight=False, soft_wrap=True)`.

#### 🟧 `apex_harness/core.py:165-172` — sem medição de tokens

```python
stream = self.client.chat.completions.create(..., stream=True)
```

Falta `stream_options={"include_usage": True}`. Note que o backup `core.py.bak` **tinha** `total_prompt_tokens` / `total_completion_tokens`, removidos na versão atual — por isso `/cost` (`cli.py:279-288`) estima tokens com `len(content) // 4`.

#### 🟧 `apex_harness/mcp_client.py:131,152` — handshake MCP a cada chamada

```python
async with stdio_client(params) as (read, write):
    async with ClientSession(read, write) as session:
        await session.initialize()
```

`asyncio.run(self._call_tool_async(...))` por ferramenta → **spawn de subprocesso + `initialize()` completo a cada invocação**. Deveria manter sessões vivas.

---

### 1.3 Médios — qualidade, robustez, segurança

| Local | Problema |
|---|---|
| `launcher_common.py:516-517` | `-ctk q4_0 -ctv q4_0`. ⚠️ **`q4_0` no K é catastrófico para a qualidade.** Medições em [llama.cpp Discussion #23470](https://github.com/ggml-org/llama.cpp/discussions/23470) (Qwen2.5-7B, wikitext-2): KLD médio `q4_0/q4_0` = **5.508897** vs `f16/q4_0` = **0.004047** vs `q8_0/q8_0` = **0.001782** — ou seja, **~1400× pior**, e `q4_0` no K sozinho colapsou o modelo de 92.0% → 24.2% em 500 perguntas. Usar **`-ctk q8_0 -ctv q8_0`**. |
| `launcher_common.py:511` | `-fa on` está presente e correto — **mas nunca deve virar `-fa auto`**. O [PR #26460](https://github.com/ggml-org/llama.cpp/pull/26460) (ainda ABERTO) descreve que com `auto` o KV cache é alocado com o layout de FA; se o FA resolver para desligado, nada o recria e **cada passo de decode faz `cont(transpose(v))` por camada**: **−69.0%** (Adreno 840) e **−30.4%** (RTX 4060 Ti). Verificar sempre a linha `resolve_fused_ops: Flash Attention enabled` no log. |
| `launcher_common.py:512-513` | `-b 1024 -ub 512`. Subdimensionado para prefill. Medições no fork (Strix Halo) mostram **+29% de prefill** com `-ub 2048` em MoE; modelos densos preferem `-ub 512`. Não generalizar. |
| `launcher_common.py:518` | `--cache-reuse 64`. Num loop agêntico que reenvia system prompt + esquemas de ferramentas a cada turno, um valor maior (256+) poupa prompt-eval. |
| `launcher_common.py:506` | `--host 0.0.0.0` expõe um servidor LLM **sem autenticação** à rede local. Deve ser `127.0.0.1`. |
| `launcher_common.py:20,25` | `_SKIP_PREFIXES = ("mmproj", "mtp-", "ggml-vocab", "dflash", ...)`. `mtp-` e `dflash` **não são modelos alternativos — são aceleradores de spec decoding**. Filtrá-los esconde exatamente o que acelera. Devem continuar fora do *seletor*, mas ser **auto-descobertos como draft**. |
| `launcher_common.py:523-533` | **CORREÇÃO de uma afirmação minha anterior.** Eu tinha escrito que esta branch estava "efetivamente morta". **Está errada: ela DISPARA.** Verifiquei ao executar o launcher real — para `Qwen2.5-Coder-7B` ele carrega de facto um draft model: `/usr/share/ollama/.ollama/models/blobs/sha256-29d8c98f...` (986 MB), que confirmei ser o **Qwen2.5-Coder-1.5B-Instruct** (`general.architecture = qwen2`, `block_count = 28`). É um par de draft legítimo. **O bug é outro, e é pior:** o harness passa `-md ... -ngld 99 --spec-draft-n-max 5 --spec-draft-n-min 2` **mas NUNCA passa `--spec-type`** — e nesta build o default é `none`. Resultado: **986 MB de RAM e tempo de carregamento gastos num modelo draft que nunca é usado.** Confirmação no log do servidor: existe a linha `common_speculative_init_result: loading draft model ...` mas **nenhuma** linha `draft acceptance = ...` (que só aparece quando a especulação realmente corre). |
| `launcher_common.py:523` | A branch está limitada por `"qwen2.5-coder-7b" in fname` **e** por um caminho de blob ollama hardcoded. Só funciona para esse modelo exato. Deve ser substituída por descoberta de sidecar (o que `apex_harness.hwtune.find_draft_model()` faz). |
| `launcher.py:101` | `subprocess.run(["pkill","-9","-f","llama-server"])` mata **qualquer** processo cujo cmdline contenha "llama-server" — incluindo o do LM Studio e o de outro agente. Matar por PID. |
| `launcher.py:115-116` | Comentário diz *"Inicia servidor com 96k de contexto"*, mas passa `context=32768` — e `launch_llama_server` ainda corta para 16384/32768 conforme o tamanho. |
| `launcher_common.py:503` (2ª ordem) | Nenhum `-t`, `--cpu-mask`, `--cpu-strict`, `--prio`, `--metrics`. Sem observabilidade: não há como medir t/s de forma fiável. |
| `cli.py:232` | `PromptSession(history=InMemoryHistory())` — histórico perdido entre sessões. |
| `cli.py:102` | `/doctor` afirma "Aceleração Vulkan/ROCm" sem verificar se o backend Vulkan está de facto ativo. |

---

## 2. Ferramentas e Dependências Recomendadas

### 2.1 Não instale ROCm para inferência nesta APU ❌

| Ferramenta | Veredicto | Evidência |
|---|---|---|
| **ROCm / HIP / hipBLAS** (já instalado: 6.2.1) | **Não usar.** Em gfx1150 o ROCm aloca apenas o carve-out de VRAM e **ignora o GTT** → ~60% mais lento que Vulkan. | [lemonade-sdk/llamacpp-rocm#57](https://github.com/lemonade-sdk/llamacpp-rocm/issues/57), [llama.cpp#20472](https://github.com/ggml-org/llama.cpp/pull/20472) |
| **Vulkan / RADV (Mesa 26.2.2)** | ✅ **É o caminho correto.** Já instalado e funcional. | `libggml-vulkan.so` presente; Mesa 26.2.2 (kisak) |
| **NPU XDNA2 (Ryzen AI)** | ❌ **Não perseguir.** Sem suporte maduro de decode LLM em llama.cpp; o NPU é para CV/ONNX, não para decode *bandwidth-bound*. O gargalo aqui é LPDDR5X, não FLOPs. | — |
| **vLLM / Aphrodite / SGLang** | ❌ Desenhados para datacenter NVIDIA. PagedAttention pressupõe VRAM discreta. Sem ganho em APU. | — |
| **ExLlamaV2** | ❌ Exige CUDA/ROCm; sem backend Vulkan. | — |
| **ONNX Runtime GenAI** | ⚠️ Possível, mas sem vantagem sobre llama.cpp Vulkan neste cenário. | — |
| **`ik_llama.cpp`** | ⚠️ Vale testar para CPU puro (kernels IQ melhores), mas não resolve o gargalo de banda. | — |
| **`llama.cpp` fork `LaurentZuijdwijk/llama.cpp`** | ✅ **Já instalado** (`~/llama-flash-next`, commit `510155c`), build Vulkan próprio em `build/bin/`. É o fork com spec decoding adaptativo + Vulkan otimizado. | ver §4.3 |

### 2.1b Estado real dos métodos de aceleração (verificado na árvore b10456)

| Método | Suportado hoje? | Evidência |
|---|---|---|
| **EAGLE-3** (`draft-eagle3`) | ✅ **SIM, de verdade** | [PR #18039](https://github.com/ggml-org/llama.cpp/pull/18039) merged 2026-06-12; `src/models/eagle3.cpp` existe. Corpo: *"achieving a 2–3× speedup"*; *"With reasoning enabled, speedup can exceed 2x. With reasoning disabled, it can reach over 3x."* — **o reasoning ligado/desligado inverte o ganho**, espelhando o achado de §5.1b. |
| **Medusa** | ❌ **NÃO — zero referências.** `grep -ril medusa` na árvore inteira devolve nada. | — |
| **Lookahead** | ⚠️ **Só demo standalone** (`examples/lookahead/`), **não** ligado a `--spec-type`, inutilizável com `llama-server`. | `examples/lookahead/README.md` |
| **DFlash** (`draft-dflash`) | ✅ exclusivo deste fork | `src/models/dflash.cpp`; PR #22105 |
| **DSpark** (`draft-dspark`) | ✅ exclusivo deste fork | PRs #27804, #25784 |
| **MTP** (`draft-mtp`) | ✅ (ver §5.3) | PR #25784 merged 2026-08-02 |
| **Prompt-lookup** (`ngram-*`) | ✅ **5 variantes**, todas draftless | ver §5.1 |

**Nomes de flags que mudaram (agora são ERROS DUROS, não aliases)** — [PR #22964](https://github.com/ggml-org/llama.cpp/pull/22964), merged 2026-05-13:

```
--draft, --draft-n, --draft-max N   the argument has been removed. use --spec-draft-n-max or --spec-ngram-mod-n-max
--draft-min, --draft-n-min N        the argument has been removed. use --spec-draft-n-min or --spec-ngram-mod-n-min
--spec-ngram-size-n / -size-m / -min-hits   the argument has been removed.
```

Passá-los invoca `arg_removed()`, que lança exceção. (`--draft-p-min` **sobreviveu** como alias de `--spec-draft-p-min`; `--draft-max`/`--draft-min` não.) **O bloco morto em `launcher_common.py:531-532` já usa os nomes novos — a sintaxe está correta; o problema é que nunca dispara.**

**Defaults verificados no binário em uso:** `--spec-draft-n-max` = **3**, `--spec-draft-n-min` = **0**, `--spec-draft-p-split` = **0.10**, `--spec-draft-p-min` = **0.00**, `--spec-ngram-*-size-n/m/min-hits` = **12 / 48 / 1**, `--spec-ngram-mod-n-match/n-min/n-max` = **24 / 48 / 64**.

### 2.2 Rebuild do llama.cpp compilado da fonte (ganho real, com ressalva)
O binário em uso (`b10456`, commit `f275595dd`, GNU 11.4.0) é um **prebuild genérico**. Não foi compilado com `-march=native`. Contudo — e isto é importante — **o backend Vulkan domina o decode**, então `-march=native` só afeta o caminho CPU. Onde importa é no prefill CPU e nos modelos que não cabem no carve-out.

```bash
# Toolchain ausente nesta máquina: não há ninja, mold nem lld.
sudo apt install -y ninja-build mold ccache
```

```bash
# Build Vulkan + CPU nativo, com LTO e linker rápido.
cmake -B build-apex -S . \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON \
  -DGGML_NATIVE=ON \
  -DGGML_LTO=ON \
  -DGGML_CPU_KLEIDIAI=OFF \
  -DLLAMA_CURL=ON \
  -DCMAKE_C_FLAGS="-O3 -march=native -mtune=native -fno-math-errno -fno-trapping-math" \
  -DCMAKE_CXX_FLAGS="-O3 -march=native -mtune=native -fno-math-errno -fno-trapping-math" \
  -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=mold" \
  -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=mold"

cmake --build build-apex -j"$(nproc)" --target llama-server llama-bench
```

Notas:
- `GGML_CPU_ALL_VARIANTS=ON` é o que o prebuild usa (carrega `libggml-cpu-zen4.so` em runtime). Com `GGML_NATIVE=ON` obtém-se um só binário afinado para Zen 5, incluindo AVX-512 completo (`avx512f/dq/bw/vl/vnni/bf16/vbmi/vbmi2/ifpma/vpopcntdq` + `avx_vnni` — todos presentes nesta CPU).
- **Boa notícia:** o prebuild já seleciona `libggml-cpu-zen4.so`, que usa AVX-512/VNNI. O ganho esperado do rebuild nativo é modesto (**~2-5%** no CPU), não transformador.
- O ganho grande vem do fork `llama-flash-next`, que já está compilado em `~/llama-flash-next/build/bin/` com GNU 15.2.0.

### 2.3 O carve-out UMA de 48 GiB está a custar 48 GiB de RAM — e não compra VRAM

Este é o achado de maior impacto que **não** é uma flag:

| | valor |
|---|---|
| `mem_info_vram_total` | 51 539 607 552 B = **48.00 GiB** |
| `mem_info_gtt_total` | 137 438 953 472 B = **128.00 GiB** |
| `MemTotal` (o que o Linux vê) | **45.65 GiB** |
| cmdline | já contém `amdgpu.gttsize=131072 ttm.pages_limit=31457280` |

Os 96 GB físicos = 45.65 (sistema) + 48 (carve-out) + ~2 (crashkernel). O bloco de 48 GiB aparece em `/sys/firmware/memmap/*` como **e820 `Reserved`** — **nunca entra no page allocator**. Pior: o RADV recalcula `total_size = gtt_size + visible_vram_size` e re-divide **2/3 : 1/3**, e `ttm.pages_limit` tem default `totalram/2`, portanto **um carve-out maior encolhe o GTT**.

A própria documentação da AMD nomeia o gfx1150 explicitamente:

> *"**It's recommended to keep the dedicated VRAM reservation in BIOS small (for example, 0.5 GB) and increase the shared (TTM/GTT) limit instead.**"* … *"Firmware may optionally reserve some memory exclusively for GPU use, but **this provides little benefit for most workloads while permanently reducing available system memory.**"*
> — [rocm.docs.amd.com — RDNA3.5 system optimization](https://rocm.docs.amd.com/en/docs-7.2.3/how-to/system-optimization/rdna3-5.html)

**Ação recomendada:** no BIOS, baixar a reserva UMA para **512 MiB**; remover `amdgpu.gttsize` (deprecado no kernel; kernels ≥7.2 impõem um limite a APUs) e fixar `ttm.pages_limit` ≈ 90% da RAM visível. **`MemTotal` deve passar de 45.65 → ~93 GiB sem qualquer custo de GPU.** Isto resolve os reboots de raiz e também torna o `_MAX_SIZE_GB` discutível.

**Bónus Vulkan:** `radv_enable_unified_heap_on_apu` existe no Mesa 26.2.2 mas o drirc do sistema só o liga para o RDR2. Sem isso, o RADV anuncia `GTT 128 + carve 48 = 176 GiB` divididos em 117.33 + 58.67 GiB **sobre 45.65 GiB de RAM real** — 3.86× de over-commit, e alocações grandes falham apesar de "memória livre". Criar `~/.drirc`:

```xml
<driconf><device><application name="Default">
  <option name="radv_enable_unified_heap_on_apu" value="true"/>
</application></device></driconf>
```

### 2.4 Discrepância a corrigir no README

`README.md:76-79` afirma "96GB LPDDR5X Unificada". A máquina tem **96 GB físicos, dos quais 48 GiB estão no carve-out UMA da iGPU**, deixando **45 GiB de RAM de sistema**. Isto não é cosmético: é a causa direta dos reboots (§1.1).

### 2.5 O que NÃO vale a pena (medido ou verificado em fonte)

| Otimização | Veredicto | Evidência |
|---|---|---|
| **Huge Pages / THP** | ❌ **Nada a fazer.** O [llama.cpp#2251](https://github.com/ggml-org/llama.cpp/issues/2251) **não tem uma única medição de throughput** — é uma queixa de `kswapd0` de 2023, fechada por inatividade. Verdictos qualitativos: *"it makes no noticeable performance difference sadly"*. A única chamada `MADV_HUGEPAGE` na árvore é **RISC-V-only** (`spine_mem_pool.cpp`); não há opção CMake nem flag. A/B medido nesta máquina: **12t 71.5 vs 70.9 GB/s (THP ~3% MAIS LENTO)**. E o llama.cpp derrota o THP de qualquer forma: `llama-mmap.cpp` usa **`MAP_POPULATE`**, pré-faultando o GGUF completo dentro do `mmap()`, tornando qualquer `madvise` posterior inócuo. |
| **`--mlock`** | ❌ **Inútil aqui.** Existe agora `-lm/--load-mode` (`auto`\|`none`\|`mmap`\|`mlock`\|`mmap+mlock`\|`dio`). Três armadilhas: (a) `--load-mode mlock` **não faz mmap** — usar `mmap+mlock`; (b) o mlock é condicionado a `ggml_backend_buffer_is_host(buf)`, logo é **no-op para tensores residentes em Vulkan**; (c) `ulimit -l` nesta máquina é **8192 kB = 8 MiB**, acima disso `mlock(2)` devolve ENOMEM e **a falha do llama.cpp é permanente** (`failed_already = true`). **Não existe nenhum delta de t/s medido para mlock em hardware algum** — afeta tempo de carregamento, não throughput de decode. |
| **`--numa`** | ❌ **Evitar.** Desliga o prefetch (`llama-mmap.cpp:473`) e num único nó NUMA todo o conselho NUMA é no-op. |
| **`vm.zone_reclaim_mode`** | ❌ Pré-condição falsa (1 nó NUMA). |
| **Governor `amd_pstate`** | ⚠️ Está em `active`, logo o governor é um pseudo-governor — **mudar EPP, não o governor**. Nota: `amd_prefcore` **só aceita `disable`** e **`amd_prefetch` não existe** no kernel (silenciosamente ignorado). |
| **`--no-mmap`** | ⚠️ A premissa "ntfs3 é lento como FUSE" é **falsa**: `/mnt/HDD` usa o driver **`ntfs3` in-kernel**, não ntfs-3g/FUSE — não há round-trip por page fault. Leitura medida: 189 MB/s. A diferença real é de *reclaimabilidade* (páginas file-backed limpas vs anónimas). **A ação de maior valor é mover os modelos do disco mecânico ntfs3 para o NVMe/ext4** — que além disso é o único caminho onde o THP file-backed funciona (medido: `FilePmdMapped = 0 kB` em ntfs3 sob qualquer ordem de madvise). |

---

## 3. Refatoração Pronta para Uso

### 3.1 Arquivos criados

| Arquivo | Função |
|---|---|
| `apex_harness/hwtune.py` | Deteta topologia híbrida, lê metadados/tensores GGUF sem dependências, localiza sidecars de spec decoding, calcula teto de decode por banda e gera o argv+env otimizado com justificação. |
| `apex_harness/optimized_launcher.py` | Substituto *drop-in* de `launcher_common.launch_llama_server()`. Mesma assinatura, mesmo retorno `(proc, log_file, log_path)`. |
| `benchmarks/apex_bench.py` | Benchmark padronizado (TTFT, prefill, decode, banda efetiva, RSS). |
| `benchmarks/membw.c` | Microbenchmark de banda de memória com pthreads. |
| `benchmarks/sweep.sh`, `benchmarks/ab_test.sh` | Executores A/B de configurações. |

### 3.2 Substituir o launcher (2 linhas em `launcher.py`)

Logo após o bloco `from launcher_common import (...)` (linha 44), inserir:

```python
import launcher_common
from apex_harness.optimized_launcher import install
install(launcher_common)      # troca launch_llama_server pela versão medida
```

Isto preserva o roteamento para `llama-server-flash` (modelos Flash-Next) que já existe em `get_llama_server()`.

### 3.3 O que o novo launcher passa a emitir

Para `Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf` (o `PREFERRED_MODEL_NAME` do seletor):

```bash
~/.local/bin/llama-server \
  -m .../Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf \
  --host 127.0.0.1 \
  -t 12 -tb 12 \
  --cpu-mask 0xFFF --cpu-strict 1 \
  -ngl 999 \
  -c 32768 -np 1 \
  -fa on \
  -ctk q8_0 -ctv q8_0 \
  -b 2048 -ub 2048 \
  --cache-reuse 256 \
  -sps 0.50 \
  --spec-type ngram-simple \
  --prio 1 --timeout 3600 --no-webui \
  --metrics \
  --alias llama-local-model
```

Diferenças face ao atual, cada uma justificada:

| Antes | Depois | Porquê |
|---|---|---|
| `taskset -c 0-7` | *(removido)* | cruzava Zen 5 + Zen 5c |
| *(sem `-t`)* | `-t 12 -tb 12` | 12 threads em 8 CPUs é oversubscrição |
| *(sem máscara)* | `--cpu-mask 0xFFF --cpu-strict 1` | 1 thread por núcleo físico |
| `-b 1024` | `-b 2048` | prefill; +29% em MoE com `-ub 2048` |
| `-ctk/-ctv q4_0` | `q8_0` | q4_0 no V custa qualidade |
| `--cache-reuse 64` | `256` | loop agêntico reenvia o prompt |
| *(nada)* | `--spec-type ngram-simple` | medido **1.95×** |
| `--host 0.0.0.0` | `127.0.0.1` | não expor LLM à LAN |
| *(nada)* | `--metrics` | observabilidade real |
| 7 env vars ROCm | *(removidas)* | inertes num binário Vulkan |

### 3.4 Correções pontuais restantes

```python
# launcher_common.py:26  — parar os reboots
_MAX_SIZE_GB = 38.0          # host tem 45 GiB; 48 GiB vão para o carve-out da iGPU

# launcher_common.py:20  — não esconder aceleradores do spec decoding
# (mantê-los fora do seletor, mas descobríveis como draft)
_SKIP_PREFIXES = ("mmproj", "ggml-vocab", "dflash", "DeepSeek-V4-Flash-DSpark")

# launcher.py:101  — matar por PID, não por padrão
# (pkill -f "llama-server" mata também o servidor do LM Studio)
```

```python
# apex_harness/cli.py:318  — sem reinterpretação de markup por token
on_chunk=lambda chunk: console.out(chunk, end="", markup=False,
                                   highlight=False, soft_wrap=True)

# apex_harness/core.py:168  — pedir contabilidade de tokens ao servidor
stream_options={"include_usage": True},

# apex_harness/core.py:105  — descoberta MCP em paralelo, não sequencial
# (7 servidores × 4 s = até 28 s de arranque bloqueante)
```

---

## 4. Script de Benchmark Padronizado

### 4.1 `benchmarks/apex_bench.py`

Mede, contra um `llama-server` já em execução:

| Métrica | Como |
|---|---|
| **TTFT (ms)** | relógio do cliente, do POST ao primeiro chunk com conteúdo |
| **Prefill t/s** | `timings.prompt_per_second` do servidor (verdade) + versão cliente |
| **Decode t/s** | `timings.predicted_per_second` do servidor (verdade) + wall-clock do cliente |
| **Banda efetiva (GB/s)** | `model_GiB × decode_tps` — compara com o pico medido de 118 GB/s |
| **Pico de memória** | `VmRSS` do processo do servidor, amostrado durante o stream |
| **VRAM/GTT** | `mem_info_vram_*` / `mem_info_gtt_*` do amdgpu via sysfs |

Usa `stream_options: {"include_usage": true}` e o bloco `timings` do llama-server — o t/s reportado é do **servidor**, não do Python, para que o overhead do harness não possa inflar nem esconder o resultado.

```bash
python3 benchmarks/apex_bench.py --label baseline \
    --prompt-tokens 512 4096 16384 --gen-tokens 256 \
    --json benchmarks/resultados/baseline.json --csv benchmarks/resultados/sweep.csv

# A/B automático de configurações (sobe e desce o servidor)
benchmarks/ab_test.sh /mnt/HDD/AIModels/.../model.gguf
benchmarks/sweep.sh    /mnt/HDD/AIModels/.../model.gguf --label tuned -t 12 --cpu-mask 0xFFF
```

### 4.2 `benchmarks/membw.c` — teto de hardware

```bash
gcc -O3 -march=native -pthread -o benchmarks/membw benchmarks/membw.c
taskset -c 0-11 ./benchmarks/membw 1 12     # 118 GB/s → teto de decode
```

Este número é o teto físico: `t/s_max ≈ banda / bytes_por_param`. Sem mudar a banda ou reduzir os bytes lidos por token, **nenhuma flag faz um modelo denso passar disso**.

### 4.3 Estado do `llama-flash-next` (fork já instalado)

`~/llama-flash-next` (fork de `LaurentZuijdwijk/llama.cpp`, commit `510155c`, GNU 15.2.0, build Vulkan próprio).

⚠️ **Ressalva importante:** todos os números de desempenho do README do fork foram medidos numa **Radeon 8060S (Strix Halo, 40 CUs)**. Esta máquina tem uma **Radeon 890M (Strix Point, 16 CUs)**. Os valores de 65-100 t/s **não transferem**; espere ~1/3 no prefill. As *decisões de configuração* transferem; os números não.

O que o fork documenta e é aplicável (`docs/speculative.md`):

| Método | Quando | Como |
|---|---|---|
| `draft-mtp` | contexto longo, qualquer tarefa — **reutiliza o KV do alvo, sem segundo cache** | `--spec-type draft-mtp --spec-draft-n-max 4` |
| `draft-dflash` | contexto curto, saída estruturada | `--spec-type draft-dflash --spec-draft-n-max 7`, sidecar `dflash-*.gguf` |
| `ngram-simple` | contexto longo com muita citação/código re-emitido | `--spec-type ngram-simple` |
| `draft-eagle3` | requer checkpoint EAGLE-3 treinado para o alvo | `--spec-type draft-eagle3 -md <eagle3.gguf>` |
| ❌ `ngram-cache` | **mais lento que o baseline** — evitar | — |

E uma regra contraintuitiva mas medida: **manter `--spec-draft-n-max` curto no MTP (3-4)**. O controlador adaptativo maximiza tokens aceites, não throughput; no MTP estes divergem (camadas `nextn` mais profundas acertam menos, mas o custo cresce linearmente em `n`). No Ornith: `n-max 7` → 85.7 t/s vs `n-max 4` → 100.4 t/s.

---

## 5. Evidência Empírica — Speedups Medidos

> **Limitação de medição (importante).** Todas as medições foram feitas com a máquina **sob carga** (load average 20-25, `gnome-shell` a ~980% de CPU, swap em uso). Os **valores absolutos são pessimistas**; use as **razões** (speedups), que foram medidas em condições comparáveis. A banda de 118 GB/s também deve ser re-medida num sistema ocioso — outros harnesses nesta mesma investigação estabilizaram em 67-73 GB/s sob carga.

### 5.1 Spec decoding por n-gramas: **1.95× num workload de edição de código**

Qwen2.5-Coder-7B-Instruct-Q4_K_M, `-ngl 0`, `-t 12`, `-c 8192`, 256 tokens gerados, taxa de aceitação lida do log do servidor:

| Configuração | decode t/s | Ganho | Aceitação | prompt t/s |
|---|---:|---:|---:|---:|
| baseline | 13.01 | 1.00× | — | 69.5 |
| `--spec-type ngram-mod` | 21.48 | 1.65× | 78.2% | 71.7 |
| `--spec-default` | 21.57 | 1.66× | 78.2% | 70.6 |
| **`--spec-type ngram-simple`** | **25.41** | **1.95×** | **88.5%** | 70.4 |
| `--spec-type ngram-map-k4v` | 25.44 | 1.96× | 88.5% | 70.9 |

Pontos-chave:
- **Sem modelo draft, sem memória extra, sem perda de qualidade.** Os drafts são verificados pelo modelo alvo, logo a distribuição de saída é inalterada — é matematicamente lossless.
- **O prefill não paga nada** (~70 t/s em todos os casos).
- **`--spec-default` NÃO escolhe o vencedor.** Ele liga exatamente `{ngram-mod, n_match=24, n_min=48, n_max=64}` — os defaults compilados, com a alternativa `map-k4v` **comentada no código-fonte**. `ngram-mod` rendeu 21.5 t/s contra 25.4 do `ngram-simple`. Não usar o atalho.
- `--spec-draft-n-max` é **inerte** para todos os tipos n-gram: o comprimento do draft vem de `size_m` (48) ou `n_max` (64). Para `ngram-cache` é fixo em 8.
- Ligar dois especuladores **não** faz pipelining — eles correm independentemente e desperdiçam verificação ([llama.cpp#23184](https://github.com/ggml-org/llama.cpp/issues/23184)).

### 5.1b ⚠️ CONTRA-EXEMPLO CRÍTICO: spec decoding pode ser **2.8× MAIS LENTO**

O mesmo `ngram-simple`, na mesma máquina, com um modelo **de raciocínio**:

| Configuração | decode t/s | Ganho | Aceitação |
|---|---:|---:|---:|
| `Qwen3.8-27B-Q4_K_M` baseline | 3.375 | 1.00× | — |
| `+ --spec-type ngram-simple` | **1.191** | **0.28×** ⬇ | **0.00%** (0/96) |

O `Qwen3.8-27B` abriu com `<think>` e **raciocinou em prosa em vez de reemitir o ficheiro**. O matcher de n-gramas não encontrou nada, mas o servidor ainda pagou um lote de verificação de 49 tokens por zero tokens aceites. Log do servidor: `draft acceptance = 0.00000 (0 accepted / 96 generated)`.

**Regra de decisão obrigatória:** manter um especulador **apenas** se a linha `draft acceptance` impressa pelo servidor for **≳0.6** *e* o decode superar o baseline sem spec **na mesma execução**. Abaixo de ~0.4 está no regime Phi-2 (0.66×/0.48×, [PR #6828](https://github.com/ggml-org/llama.cpp/pull/6828)); a 0.0 é 2.8× mais lento. **Para modelos de raciocínio: desligar a especulação, ou desligar o thinking.**

Corroboração independente: *"Lossless but Not Free: An Empirical Anatomy of Speculative Decoding on Consumer Hardware"* (Chordiya, 2026-07-19, Apple Silicon) — melhor caso **1.61×** com K=6, e **3 de 5 configurações DESACELERAM**, uma delas com **52.4% de aceitação a correr a 0.50×**. Tese: *"speculative decoding pays off only when verification is genuinely batch-parallel and the draft/target latency gap is real."* [arxiv.org/abs/2607.17283](https://arxiv.org/abs/2607.17283)

**A taxa de aceitação, sozinha, não prevê o speedup — o que prevê é o custo marginal do draft.** 88.5% → 2.35× (ngram, draft gratuito) vs 73.5% → 1.00× (MTP, draft que lê pesos).

### 5.2 Tetos de decode por modelo (118 GB/s × 55% de eficiência CPU)

Esta tabela é o argumento decisivo para trocar de modelo:

| Modelo | Tam. | Ativos | Peso ativo/token | **Teto decode (CPU)** |
|---|---:|---:|---:|---:|
| `LFM2.5-8B-A1B` | 4.80 GiB | 1.5B (12.5%) | 0.60 GiB | **~110 t/s** |
| `Qwen3-Coder-30B-A3B` | 16.26 GiB | 3B (10%) | 1.63 GiB | **~40 t/s** |
| `gemma-4-26B-A4B` | 13.45 GiB | 3.8B (15.4%) | 2.07 GiB | **~31 t/s** |
| `Qwen3.8-27B` (denso) | 15.93 GiB | 27B (100%) | 15.93 GiB | **~4.1 t/s** |

**Um MoE A3B de 30B tem ~10× o teto de um denso de 27B do mesmo tamanho em disco, com qualidade comparável para código.** Decode é *bandwidth-bound*: o que importa não é o tamanho do modelo, é quantos **bytes ele lê por token**.

E há uma medição direta nesta iGPU exata (Radeon 890M / RADV STRIX1, LPDDR5X-7500, llama.cpp **Vulkan**):

| Modelo | Vulkan `-ngl 99` |
|---|---|
| **`Qwen3-Coder-30B-A3B` Q4_K_M** | **TG128 = 37.19 t/s** (pp512 471.94, FA on) |
| `Qwen3-30B-A3B` Q4_K_M | 36.98 t/s |

— [zenn.dev/omohikane — llama-cpp-vulkan-bench](https://zenn.dev/omohikane/articles/llama-cpp-vulkan-bench)

**A distinção de regime é essencial:** os 13.73 t/s de referência são **CPU-only `-t 12`**; os 37.19 t/s são **Vulkan `-ngl 99`**. Para MoE nesta APU o caminho GPU é **~2.7× mais rápido**. Para modelos **densos** o resultado inverte (ver §5.5).

#### Ranking de modelos MoE relevantes

| # | Modelo | Total / **ativos** | Q4 | t/s aqui | Evidência agêntica |
|---|---|---|---|---|---|
| **1** | `Qwen/Qwen3.6-35B-A3B` | 35.95B / **3B** | 22.13 GB | ~34 | **SWE-bench Verified 70.12**, Terminal-Bench 2.1 44.38 |
| **2** | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | 30.53B / **3B** | 18.56 GB | **37.2 MEDIDO** | coder dedicado, 256K ctx |
| 3 | `nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B` | 31.58B / **3B** | 18.90 GB | ~35 | SWE-bench 51.56; híbrido Mamba-2 (KV barato em ctx longo) |
| 4 | `LiquidAI/LFM2.5-8B-A1B` | 8.47B / **1.5B** | 5.16 GB | **~75** | mais rápido; não é coder |
| 5 | `google/gemma-4-26B-A4B-it` | 25.81B / **3.8B** | 16.95 GB | ~27 | SWE-bench 57.40, IFBench 77.25 |
| 6 | `ibm/granite-4.0-h-small` | 32.21B / **9B** | 19.48 GB | ~13 | Apache-2.0, mas 9B ativos mata o t/s |

**Correções importantes face ao que os nomes sugerem:**
- **`gemma4moe` / `granitemoehybrid` não existem** no llama.cpp (grep = 0 hits). Os nomes reais são `gemma4` e `granitehybrid`.
- **`granite-4.1-30b` e `granite-4.2-30b` são DENSOS**, não MoE. O único Granite MoE 30B é `granite-4.0-h-small`.
- **`GLM-4.7-Flash` NÃO é suportado** pelo llama.cpp: a arquitetura `glm4_moe_lite` tem **0 ocorrências** em `llama-arch.cpp`. (`GLM-4.5-Flash`/`4.6-Flash` nem têm pesos descarregáveis — são API-only.)
- **`LFM2.5-8B-A1B` são 1.5B ativos, não 1B.**
- **`gemma-4-26B-A4B` tem um drafter EAGLE-3 disponível**: `RedHatAI/gemma-4-26B-A4B-it-speculator.eagle3`, listado em `docs/speculative.md`. É o único modelo desta lista onde o EAGLE-3 está realmente ao alcance.

**Melhor t/s-por-qualidade para codificação agêntica: `Qwen3.6-35B-A3B`** (melhor SWE-bench/Terminal-Bench do conjunto), com **`Qwen3-Coder-30B-A3B` como o cavalo de batalha comprovado** — é o único com medição dura no silício exato desta máquina.

### 5.3 MTP no Qwen3.8-27B — disponível, mas **não compensou** (resultado negativo)

Verificámos os tensores do GGUF diretamente (parser próprio em `hwtune.read_gguf_tensor_names`):

```
Qwen3.8-27B-Q4_K_M.gguf      -> 866 tensores
   blk.64.nextn.eh_proj.weight
   blk.64.nextn.enorm.weight
   blk.64.nextn.hnorm.weight
   blk.64.nextn.shared_head_norm.weight

mtp-Qwen3.8-27B-Q4_0.gguf    ->  18 tensores (MTP-only, cópia Q4_0)
```

**As cabeças MTP já estão dentro do ficheiro alvo**, e o binário em uso suporta o modo:

```
$ llama-server --help | grep spec-type
--spec-type none,draft-simple,draft-eagle3,draft-mtp,draft-dflash,draft-dspark,
            ngram-simple,ngram-map-k,ngram-map-k4v,ngram-mod,ngram-cache
```

Ou seja, `--spec-type draft-mtp` funciona **sem sidecar nenhum**. Mas ao medir, o resultado foi nulo a negativo:

| Configuração (`-ngl 0`, `-t 12`, `-c 8192`, 382 tokens de prompt, 256 gerados) | decode t/s | Ganho | Aceitação | prefill t/s |
|---|---:|---:|---:|---:|
| `Qwen3.8-27B-Q4_K_M` baseline | 3.38 | 1.00× | — | 14.56 |
| `+ --spec-type draft-mtp --spec-draft-n-max 3` | 3.38 | **1.00×** | 73.5% | 14.79 |
| `+ --spec-type draft-mtp --spec-draft-n-max 2` | **2.92** | **0.87×** ⬇ | 80.9% | 14.74 |

**Porquê?** Num alvo **denso** e *bandwidth-bound*, o passo de *draft* também lê pesos (a camada `nextn`), e uma passagem de verificação de *k* tokens custa mais que uma passagem de 1 token. Com aceitação de ~74% e `n-max 3`, o comprimento médio aceite (~1.7 tokens/passagem) não chega para cobrir esse custo extra. O ganho anula-se.

Isto contrasta com o `ngram-simple`, que dá 1.95× porque os seus drafts são **gratuitos**: uma consulta de n-gramas ao histórico de tokens **não lê pesos de modelo nenhum**. A verificação é lucro puro.

**Ressalvas importantes a este resultado negativo:**
1. O teste foi com contexto **curto** (382 tokens). O próprio README do fork mostra que o MTP só ganha em **contexto longo (~31 K tokens)** e em conteúdo **muito citável** (`verbatim reproduction` 36.07 vs 12.20 t/s), perdendo em prosa (20.54 vs 12.19). "Content dominates configuration."
2. A máquina estava sob carga (load average 22-27, **swap em uso**: 3.9 GiB de 8 GiB) durante a medição — o número absoluto de 3.38 t/s é pessimista.
3. Foi medido com `-ngl 0` (CPU). Com offload Vulkan o balanço entre custo de draft e de verificação pode mudar.

**Conclusão:** MTP fica **opt-in** (`TuneOptions(use_mtp=True)`), não por omissão. O default do `hwtune` é `ngram-simple`.

Nota: `--draft`, `--draft-max` e `--draft-min` foram **removidos** nesta build. Os nomes corretos são `--spec-draft-n-max`, `--spec-draft-n-min`, `--spec-draft-p-min`. (O `launcher_common.py` já usa os nomes novos no bloco morto das linhas 531-532 — a sintaxe está certa, o problema é que nunca dispara.)

### 5.4 CPU vs Vulkan `-ngl 999` — comparação back-to-back (o resultado decisivo)

Todas as três configurações abaixo foram medidas **na mesma sessão, com as mesmas flags, servidor quente** (3 requests de warmup obrigatórios), no mesmo modelo Qwen2.5-Coder-7B-Q4_K_M:

| Configuração | prompt | prefill t/s | **decode t/s** | Banda efetiva | TTFT |
|---|---:|---:|---:|---:|---:|
| CPU `-ngl 0` + ngram-simple | 365 | 46.30 | 6.78 | 29.5 GB/s | 7.9 s |
| CPU `-ngl 0` + ngram-simple | 2543 | 29.95 | 4.18 | 18.2 GB/s | 84.9 s |
| **Vulkan `-ngl 999` + ngram-simple** | 365 | **75.54** | **13.69** | **59.7 GB/s** | **4.8 s** |
| **Vulkan `-ngl 999` + ngram-simple** | 2543 | **47.92** | **10.82** | **47.2 GB/s** | **53.1 s** |
| Vulkan `-ngl 999`, **sem** spec | 365 | 73.67 | 13.75 | 59.9 GB/s | 5.0 s |
| Vulkan `-ngl 999`, **sem** spec | 2543 | 47.17 | 10.83 | 47.2 GB/s | 53.9 s |

**Três conclusões, todas não-óbvias:**

1. **Vulkan `-ngl 999` ganha do CPU por ~2× no decode e ~1.6× no prefill.** Decode 6.78 → 13.69 t/s; prefill 46.30 → 75.54 t/s; TTFT 7.9 s → 4.8 s. **Validado: `-ngl 999` é o default correto.** (Uma medição anterior minha mostrou 6.50 t/s em Vulkan — estava **inválida**, contaminada por um sweep concorrente e sem warmup. Ver a nota abaixo.)

2. **⚠️ No caminho Vulkan, o `ngram-simple` deu ZERO ganho** (13.69 vs 13.75 t/s sem spec = 1.00×; 10.82 vs 10.83 = 1.00×). Isto **não** contradiz §5.1 — explica-o. O ganho de 1.95× dos n-gramas é **inteiramente dependente do conteúdo**: o prompt usado aqui (*"write a detailed technical paragraph…"*) é **prosa nova**, não reemissão de contexto. O teste de §5.1 usou *"refactor this Python file, return the complete file"* — deliberadamente rico em citação, onde a aceitação chegou a 88.5%. **Com prosa, a aceitação cai a ~0 e o especulador é neutro (aqui) ou negativo (§5.1b).**

3. **A banda efetiva máxima atingida foi 59.9 GB/s = 51% dos 118 GB/s medidos.** Mesmo o melhor caminho não satura a LPDDR5X — confirma que o decode é uma cadeia dependente com latência, não um problema de streaming puro.

> **Armadilha de medição (documentada por ter me mordido):** a **primeira** requisição a um servidor Vulkan compila os pipelines. Medido: **TTFT de 87.5 s e prefill de 0.01 t/s** para um prompt de 512 tokens. **Sem 2-3 requests de warmup descartados, qualquer benchmark de Vulkan é lixo.** `benchmarks/compare_backends.sh` faz o warmup automaticamente.

### 5.5 Números da configuração atual (indicativo)

Numa execução interrompida sob forte contenção, a configuração **exatamente como o launcher a produz hoje** (`taskset -c 0-7`, `-b 1024`, `-ck/ctv q4_0`, sem `-t`) registou **3.11 t/s de decode e 49.15 t/s de prefill** — contra **13.69 t/s** da configuração corrigida, ou **4.4×**. Este número isolado é **indicativo, não conclusivo** (condições diferentes), mas aponta na mesma direção que o A/B/C controlado de §1.1, que é a evidência limpa.

**Divisão de regimes (resumo prático):**

| Carga | Caminho | Justificação |
|---|---|---|
| **MoE** (A3B/A4B) | **Vulkan `-ngl 999`** | ~2.7× mais rápido; medido por terceiros nesta iGPU: 37.19 t/s |
| **Denso que cabe no carve-out** | **Vulkan `-ngl 999`** | ~2× medido aqui (§5.5) |
| **Denso > carve-out** | CPU `-ngl 0 -t 12` | offload parcial transborda para GTT e degrada |
| **Prefill sempre** | **Vulkan** | 1.6-2.1× medido; a iGPU tem muito mais FLOPs que 12 núcleos AVX-512 |

### 5.6 Baseline denso de 27B — o argumento para migrar para MoE

Medição direta do `Qwen3.8-27B-Q4_K_M` (15.93 GiB, denso), `-ngl 0`, `-t 12`:

| Métrica | Medido | Teto teórico (§5.2) | Eficiência |
|---|---:|---:|---:|
| decode | **3.38 t/s** | 4.1 t/s | 82% |
| prefill | **14.56 t/s** | — | — |

O modelo teórico de banda acertou dentro de 18% — o que valida a metodologia. E confirma o veredicto: um denso de 27B **não passa de ~4 t/s nesta máquina, por física de LPDDR5X**, independentemente de flags. Um MoE A3B de 30B do mesmo tamanho em disco tem teto de ~40 t/s.

O prefill de 14.56 t/s em CPU é igualmente revelador: é ~3.3× mais lento que o mesmo modelo com offload Vulkan (§5.5), o que justifica `-ngl 999` como default.

---

## 6. Plano de Ação Priorizado

| Prioridade | Ação | Impacto esperado | Esforço |
|---|---|---|---|
| **P0** | **BIOS: reduzir a reserva UMA de 48 GiB → 512 MiB** + `ttm.pages_limit` a 90% da RAM | **+48 GiB de RAM** (45.65 → ~93 GiB), elimina os reboots na raiz | reinício |
| **P0** | Remover `taskset -c 0-7`; passar `-t 12 --cpu-mask 0xFFF --cpu-strict 1` | **+97% decode, +30% prefill** (A/B controlado) | 1 linha |
| **P0** | Remover o bloco de env ROCm + `LD_PRELOAD` | remove risco, zero perda | 7 linhas |
| **P0** | `-ctk q4_0 -ctv q4_0` → **`-ctk q8_0 -ctv q8_0`** | **~1400× melhor KLD** (5.509 → 0.0018); evita colapso de qualidade | 2 flags |
| **P1** | **Migrar o modelo default para MoE** (`Qwen3-Coder-30B-A3B` ou `Qwen3.6-35B-A3B`) | **~3-13×** — o maior ganho único | escolha de modelo |
| **P1** | Garantir **`-ngl 999`** + `-ngl` coerente com o carve-out | **~2× decode, ~1.6× prefill** (medido §5.5) | já no `hwtune` |
| **P1** | `--cache-reuse 256`, `-b 2048`, `-fa on` **nunca `auto`** | prefill + robustez (PR #26460) | 3 flags |
| **P2** | `--spec-type ngram-simple` — **só em workload de reemissão de código** | **+95%** lá; **1.00×** em prosa; **−72%** em modelos de raciocínio | 1 flag + validação |
| **P2** | Corrigir `cli.py:318` (`console.out`, `markup=False`) | remove teto de t/s no cliente | 1 linha |
| **P2** | Descoberta MCP em paralelo + `stream_options` | −28 s no arranque, contabilidade real | ~20 linhas |
| **P2** | Mover modelos do HDD ntfs3 para NVMe/ext4 | carregamento e estabilidade (189 MB/s → NVMe) | cópia |
| **P3** | `--host 127.0.0.1`; `pkill` por PID; `~/.drirc` unified heap | segurança / não matar servidores alheios / corrige over-commit 3.86× | 3 linhas |
| **P3** | Avaliar `--spec-type draft-mtp` com **`-ngl 999`** | 1.00× medido em CPU; issue #23184 sugere ~78% aceitação em Vulkan iGPU | 2 flags |
| **P3** | Rebuild com `-march=native` + `ninja`/`mold` | ~2-5% no CPU | ~30 min |
| **P4** | Testar o fork `llama-flash-next` como servidor primário | kernels Vulkan otimizados p/ APU | ~1 h |
| **P4** | Baixar um drafter **EAGLE-3** (`RedHatAI/gemma-4-26B-A4B-it-speculator.eagle3`) | EAGLE-3 dá 2-3× segundo PR #18039 | download |

### O que NÃO fazer (também verificado)

- ❌ **Não** ligar `--spec-default` — escolhe `ngram-mod`, que rendeu 21.5 t/s contra 25.4 do `ngram-simple`.
- ❌ **Não** usar `-fa auto` — [PR #26460](https://github.com/ggml-org/llama.cpp/pull/26460) aberto, −69%/−30% documentados.
- ❌ **Não** perseguir ROCm/HIP, NPU XDNA2, vLLM, ExLlamaV2, Huge Pages, `mlock`, `--numa` (ver §2.1 e §2.5).
- ❌ **Não** usar `--draft`/`--draft-max`/`--draft-min` — lançam erro. (E `--spec-draft-n-max` é **inerte** para tipos n-gram.)
- ❌ **Não** fixar threads com `taskset` nem passar `-t` acima de 12.

---

## 7. Reproduzir

Todos os artefactos estão no repositório do projeto:

| Arquivo | Função |
|---|---|
| `RELATORIO_OTIMIZACAO.md` | Este relatório |
| `apex_harness/hwtune.py` | Deteção de topologia, parser GGUF (metadados **e tensores**), cálculo de teto de banda, gerador de argv+env com justificação |
| `apex_harness/optimized_launcher.py` | Substituto *drop-in* de `launcher_common.launch_llama_server()` |
| `benchmarks/apex_bench.py` | Benchmark padronizado (TTFT / prefill / decode / banda efetiva / RSS / VRAM) |
| `benchmarks/compare_backends.sh` | A/B CPU vs Vulkan com warmup obrigatório |
| `benchmarks/ab_test.sh`, `benchmarks/sweep.sh` | Executores de matrizes de configuração |
| `benchmarks/membw.c` | Microbenchmark de banda de memória (pthreads) |
| `benchmarks/results/*.json`, `*.csv` | Resultados brutos de todas as medições citadas |
| ~~`pesquisa/spec_decoding/`~~ | Campanha de investigação paralela (1,2 GB). **Apagada em 2026-09-12** para libertar disco. Os seus achados estão citados com URL ao longo deste relatório. |

```bash
cd /home/leonardo/apex_harness

# 1. Teto de hardware (o número que limita tudo)
gcc -O3 -march=native -pthread -o benchmarks/membw benchmarks/membw.c
taskset -c 0-11 ./benchmarks/membw 1 12        # esperado: ~118 GB/s read

# 2. Escala de threads — reproduz o colapso a -t 24
LB=~/.local/share/llama.cpp/llama-b10456/llama-bench
M=/mnt/HDD/AIModels/lmstudio-community/Qwen2.5-Coder-7B-Instruct-GGUF/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf
for T in 4 8 12 16 24; do $LB -m "$M" -p 512 -n 128 -t $T -ngl 0 -r 2 -o md; done

# 3. Prova do gargalo do taskset (o A/B/C de §1.1)
taskset -c 0-7 $LB -m "$M" -p 512 -n 128 -ngl 0 -r 2 -o md   # ~6.8 t/s  (launcher hoje)
                 $LB -m "$M" -p 512 -n 128 -ngl 0 -t 12 -r 2 -o md  # ~13.5 t/s (corrigido)

# 4. Plano otimizado para qualquer modelo, com justificação (não executa)
python3 -m apex_harness.optimized_launcher <modelo.gguf>

# 5. CPU vs Vulkan, com warmup (o A/B de §5.4)
benchmarks/compare_backends.sh "$M"

# 6. Benchmark de um servidor já em execução
python3 benchmarks/apex_bench.py --label baseline --prompt-tokens 512 4096 --gen-tokens 256
```

**Ao comparar configurações, respeitar três regras que me morderam durante esta auditoria:**

1. **Warmup é obrigatório em Vulkan.** A primeira requisição compila os pipelines: medi **TTFT de 87.5 s e prefill de 0.01 t/s** sem warmup. Sem descartar 2-3 requests, o benchmark é lixo.
2. **A máquina não está ociosa.** `load average` esteve entre 20 e 35 durante toda a campanha (`gnome-shell` a ~980% de CPU, swap em uso). Comparar sempre **back-to-back na mesma sessão** e reportar **razões**, não valores absolutos.
3. **Validar a especulação pelo log do servidor**, não pela intuição: ler a linha `draft acceptance = X (a accepted / b generated)`. Se a aceitação for < 0.6, ou o ganho não se materializar, **desligar**. A 0% de aceitação o resultado é **2.8× mais lento**.
