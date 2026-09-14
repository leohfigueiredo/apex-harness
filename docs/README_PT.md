# ⚡ Apex Harness

**Apex Harness** é um agente autónomo de engenharia de software, pesquisa técnica e automação, construído à medida para a sua máquina de alto desempenho (**AMD Ryzen AI 9 HX 370 + Radeon 890M + 96GB RAM**).

Ele combina a experiência interativa do Claude Code e a robustez de múltiplos harnesses, com suporte de hardware nativo e integração total com o ecossistema MCP:

1. **Acesso Real à Internet:** Ferramentas nativas `web_search` (DuckDuckGo live) e `fetch_url` (leitura e extração limpa de artigos, documentação e repositórios sem restrições de corte temporal).
2. **Acesso ao Sistema Operacional & Arquivos:** Ferramentas `list_dir`, `read_file` (com paginação anti-estouro de contexto), `write_file`, `edit_file` (com tolerância a quebras de linha `\r\n` e espaços) e `bash_exec`.
3. **Suporte Nativo a Ferramentas MCP (Model Context Protocol):** Conexão dinâmica aos servidores MCP configurados em `~/.gemini/config/mcp_config.json` (ex: `memory`, `sequential-thinking`, `ollama`, `notebooks`, etc.), com descoberta automática e execução assíncrona segura.
4. **Tool Calling Resiliente & Autônomo:** Suporta tanto chamadas estruturadas padrão OpenAI quanto extração por fallback de chamadas em texto (`<tool_call>...`, blocos markdown JSON) emitidas por modelos locais (Qwen, DeepSeek, GLM, Llama).
5. **Varredura Universal de Modelos GGUF:** Detecta modelos em `~/.lmstudio/models`, `/mnt/HDD/AIModels`, `/mnt/Windows/AIModels`, `/run/media/...` com seguimento seguro de links simbólicos.
6. **Interface Gráfica & Terminal Duplo:** Seletor visual Zenity com janela 1 dedicada a métricas de inferência em tempo real (tokens/s, tempo de prompt eval) e janela 2 com o terminal de desenvolvimento do agente.

---

## 📁 Estrutura da Pasta

> **Mapa completo e atualizado: [`COMO_ESTA_ORGANIZADO.md`](COMO_ESTA_ORGANIZADO.md)**
> O relatório da auditoria de desempenho está em [`RELATORIO_OTIMIZACAO.md`](RELATORIO_OTIMIZACAO.md).

Estrutura resumida:
```
apex_harness/            o agente (pacote Python) — NÃO renomear
  cli.py core.py tools.py mcp_client.py
  hwtune.py              escolhe as flags do llama-server (medido)
  optimized_launcher.py  substitui o launch antigo
launcher.py run.sh       entrada gráfica e de terminal
benchmarks/              ferramentas de medição + resultados/
  resultado/             todos os números medidos
backups/                 originais de antes das correções
```

### Estrutura antiga (obsoleta)

```
/home/leonardo/apex_harness/
├── apex_harness/
│   ├── __init__.py
│   ├── core.py          # Agente, loop multi-turn, streaming, fallback de tool call e auto-compactação
│   ├── tools.py         # Ferramentas embutidas (web, bash, os) com tolerância de edição e paginação
│   ├── mcp_client.py    # Gerenciador MCP (leitura de mcp_config.json, descoberta e execução de ferramentas)
│   └── cli.py           # Interface TUI moderna (Rich + Prompt Toolkit + comandos Claude Code + MCP)
├── launcher.py          # Launcher gráfico com Zenity integrado ao launcher_common.py
├── run.sh               # Script de execução rápida para terminal
├── README.md            # Esta documentação
└── apex-harness.svg     # Ícone visual do sistema
```

---

## 🚀 Como Iniciar

### 1. Pelo Desktop (Ícone Gráfico)
- Dê duplo clique no ícone **Apex Harness** no ambiente de trabalho (`~/Desktop/Apex Harness.desktop`).
- Escolha o modelo GGUF (detecta automaticamente os modelos do SSD e do HDD em `/mnt/HDD`).
- Escolha a pasta do projeto onde deseja trabalhar.
- O `llama-server` iniciará com aceleração GPU (Vulkan/ROCm) na janela de métricas, e a janela do agente abrirá pronta para codificar!

### 2. Pelo Terminal (Qualquer Pasta)
Em qualquer terminal ou pasta de projeto, digite:
```bash
apex-harness
```
Ou especificando endpoint ou modelo:
```bash
apex-harness --url http://127.0.0.1:8080/v1 --model "llama-local-model"
```
Para desativar temporariamente o carregamento de ferramentas MCP:
```bash
apex-harness --no-mcp
```

---

## 🛠️ Comandos Internos no Chat (Slash Commands)

- `/help` — Exibe a lista com todos os comandos disponíveis.
- `/mcp` — Exibe os servidores MCP configurados e as ferramentas ativas de cada um.
- `/tools` — Lista todas as ferramentas carregadas (embutidas + MCP).
- `/doctor` — Diagnóstico de saúde do sistema (llama-server, Radeon 890M, RAM, MCP, Git).
- `/review` — Analisa o `git diff` do projeto atual e faz revisão técnica automática.
- `/commit` — Sugere e executa commits convencionais inteligentes via Git.
- `/compact` — Compacta o histórico para liberar espaço na janela de contexto.
- `/cost` — Exibe estatísticas de tokens e custo de execução (100% gratuito local).
- `/init` — Cria o arquivo `APEX.md` com instruções e regras do projeto.
- `/clear` ou `/new` — Limpa o histórico da sessão e inicia um novo tópico.
- `/status` — Exibe modelo ativo, endpoint e contagem de mensagens em memória.
- `/exit` ou `/quit` — Encerra a sessão.

---

## 🧠 Hardware Otimizado
- **Processador:** AMD Ryzen AI 9 HX 370 (12 Cores / 24 Threads Zen 5 / AVX-512)
- **Placa Gráfica:** AMD Radeon 890M (16 CUs RDNA 3.5 gfx1150)
- **Memória:** 96GB LPDDR5X Unificada
- **Aceleração:** ROCm + Vulkan + llama.cpp com Flash-Attention e Cache Quantizado
