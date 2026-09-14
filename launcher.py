#!/home/leonardo/.pyenv/versions/3.12.9/bin/python3
"""
Apex Harness Desktop Launcher
Janela 1: Servidor llama-server com métricas de tokens/s em tempo real
Janela 2: Interface interativa do Apex Harness no projeto selecionado
"""
import os
import sys
import time
import subprocess
import atexit
import signal

# Ensure launcher_common and apex_harness are in Python path
sys.path.insert(0, os.path.expanduser("~/.local/lib"))
sys.path.insert(0, "/home/leonardo/apex_harness")

server_process = None

def cleanup():
    global server_process
    if server_process and server_process.poll() is None:
        try:
            print("\n[Apex] Encerrando llama-server...")
            server_process.terminate()
            server_process.wait(timeout=3)
        except Exception:
            subprocess.run(["pkill", "-9", "-f", "llama-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

atexit.register(cleanup)
signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))

try:
    from launcher_common import (
        ensure_drive_mounted,
        get_gguf_files,
        show_zenity_model_picker,
        show_zenity_backend_picker,
        launch_llama_server,
        stream_server_output,
        wait_for_server_ready,
        notify
    )
except ImportError as e:
    print(f"\033[1;31mErro ao importar launcher_common: {e}\033[0m")
    input("\nPressione Enter para fechar...")
    sys.exit(1)

# Monkeypatch: substitui launch_llama_server do launcher_common pelo
# optimized_launcher do apex_harness (mmap+mlock, --prio 2, ngram-simple, etc).
# Mantém todas as outras funções do launcher_common intactas.
try:
    import launcher_common as _lc
    from apex_harness.optimized_launcher import install as _apex_install
    _apex_install(_lc)
    print("\033[1;32m[Apex] Servidor optimizado activo (hwtune + ngram-simple + mmap+mlock).\033[0m")
except Exception as _patch_err:
    print(f"\033[1;33m[Apex] Aviso: optimized_launcher não aplicado ({_patch_err}). A usar launcher_common padrão.\033[0m")

def pick_folder():
    default_dir = os.path.expanduser("~/Project_1")
    if not os.path.exists(default_dir):
        default_dir = os.path.expanduser("~")
    cmd = [
        "zenity", "--file-selection", "--directory",
        "--title=Apex Harness - Selecione a Pasta do Projeto",
        "--text=Selecione a pasta onde o Apex Harness irá trabalhar:",
        f"--filename={default_dir}/"
    ]
    try:
        res = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
        if res and os.path.exists(res):
            return res
    except Exception:
        pass
    return default_dir

def ask_mcp_mode() -> bool:
    """Pergunta ao utilizador se deseja carregar ferramentas MCP externas."""
    cmd = [
        "zenity", "--question",
        "--title=Apex Harness - Ferramentas MCP",
        "--text=Como deseja inicializar as ferramentas do Apex Harness?\n\n"
               "• 🚀 Modo Turbo (Recomendado): Ferramentas nativas de código, prompt leve (~800 tok), velocidade máxima (~4.2 t/s)\n"
               "• 🔌 Modo Completo (+MCP): Carrega 59 ferramentas de pesquisa/análise (Hyperresearch, Memory, Notebooks, etc.)\n\n"
               "(Você também pode alternar a qualquer momento no chat digitando /mcp load ou /mcp unload)",
        "--ok-label=🚀 Modo Turbo (Sem MCP)",
        "--cancel-label=🔌 Modo Completo (+MCP)"
    ]
    try:
        ret = subprocess.call(cmd, stderr=subprocess.DEVNULL)
        # ret == 0 -> utilizador clicou no botão primário (Modo Turbo)
        # ret == 1 -> utilizador clicou no cancel-label (Modo Completo)
        return ret != 0
    except Exception:
        return False

def pick_reasoning_effort() -> str:
    """Permite escolher o nível de raciocínio (effort) via Zenity."""
    cmd = [
        "zenity", "--list", "--radiolist",
        "--title=Apex Harness - Nível de Raciocínio (Effort)",
        "--text=Escolha o nível de profundidade de raciocínio para o modelo:\n(Também pode alterar no chat a qualquer momento com /effort)",
        "--column=Sel", "--column=Nível", "--column=Descrição",
        "FALSE", "low", "⚡ Baixo: Respostas rápidas e concisas (economiza tokens)",
        "TRUE", "medium", "⚖️ Médio: Equilíbrio padrão recomendado",
        "FALSE", "high", "🧠 Alto: Raciocínio profundo e analítico",
        "FALSE", "off", "🚀 Desligado: Resposta direta sem bloco de pensamento"
    ]
    try:
        res = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
        if res in ["low", "medium", "high", "off"]:
            return res
    except Exception:
        pass
    return "medium"

def main():
    global server_process
    try:
        ensure_drive_mounted()
        
        backend_mode = show_zenity_backend_picker("Apex Harness")
        if not backend_mode:
            print("Inicialização cancelada.")
            return

        apex_bin = os.path.expanduser("~/.local/bin/apex-harness")

        # ── 1. Local GGUF via llama-server (Hardware Accelerated) ─────────────
        if backend_mode in ["vulkan", "gpu", "colibri"]:
            model_data = get_gguf_files()
            if not model_data or not model_data[0]:
                print("\033[1;31m⚠️ Nenhum modelo GGUF encontrado.\033[0m")
                input("\nPressione Enter para fechar...")
                sys.exit(1)

            selected_model_path = show_zenity_model_picker(model_data, title="Apex Harness - Escolha do Modelo GGUF")
            if not selected_model_path:
                print("Seleção cancelada.")
                return

            working_dir = pick_folder()
            if not working_dir:
                working_dir = os.path.expanduser("~/Project_1")

            load_mcp = ask_mcp_mode()
            mcp_flag = "" if load_mcp else " --no-mcp"
            effort_val = pick_reasoning_effort()
            effort_flag = f" --effort {effort_val}"

            folder_name = os.path.basename(working_dir)
            model_name = os.path.basename(selected_model_path)

            # Limpar instâncias antigas do llama-server na porta 8080
            subprocess.run(["pkill", "-9", "-f", "llama-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(1.5)

            print(f"\n\033[1;36m========================================================\033[0m")
            print(f"\033[1;32m  APEX HARNESS - SERVIDOR & MÉTRICAS DE TOKENS/S\033[0m")
            print(f"\033[1;36m========================================================\033[0m")
            print(f"\033[1;34mModelo:\033[0m          {model_name}")
            print(f"\033[1;34mPasta do Projeto:\033[0m {working_dir}")
            print(f"\033[1;35mHardware:\033[0m         AMD Ryzen AI 9 HX 370 + Radeon 890M (96GB Unified)")
            print(f"\033[1;33mPorta Server:\033[0m     http://127.0.0.1:8080/v1")
            print(f"\033[1;36m--------------------------------------------------------\033[0m\n")

            notify("Apex Harness", f"Carregando {model_name}...", icon="utilities-terminal")

            # Inicia servidor com 96k de contexto
            server_proc, log_file, log_path = launch_llama_server(selected_model_path, port=8080, context=65536)
            server_process = server_proc

            # Redireciona a saída do llama-server em tempo real para este terminal (tokens/s, latência, etc.)
            # Inicia streaming silencioso — a barra de progresso vai dominar o terminal
            stream_thread = stream_server_output(server_proc, log_file, silent=True)

            ready = wait_for_server_ready(8080, timeout=1800, server_proc=server_proc, log_path=log_path)

            # Após servidor pronto, libera streaming para mostrar tokens/s em tempo real
            stream_thread.set_silent(False)

            if not ready:
                print("\n\033[1;31m❌ Erro ao inicializar o modelo no llama-server.\033[0m")
                print(f"Verifique o log em: {log_path}")
                input("\nPressione Enter para fechar...")
                sys.exit(1)

            notify("Apex Harness Ready", f"✅ {model_name} pronto!\nAbrindo janela do agente...", icon="emblem-default")
            print(f"\n\033[1;32m✅ Servidor online e acelerado na GPU! Abrindo Apex Harness...\033[0m")
            print(f"\033[1;35m-> Acompanhe neste terminal os tokens/s e o prompt eval em tempo real.\033[0m\n")

            # Abrir o Apex Harness na segunda janela do terminal dedicada ao chat/projeto
            launch_cmd = (
                f"export PATH=\"$HOME/.local/bin:$PATH\" && "
                f"cd '{working_dir}' && "
                f"echo -e '\\033[1;32m=== Apex Harness conectado ao llama-server local (Porta 8080) ===\\033[0m\\n' && "
                f"{apex_bin} --url 'http://127.0.0.1:8080/v1' --model 'llama-local-model'{mcp_flag}{effort_flag}; "
                f"echo ''; read -p 'Sessão do Apex Harness concluída. Pressione Enter para fechar...'"
            )

            subprocess.Popen([
                "gnome-terminal",
                "--title", f"Apex Harness · {model_name} · {folder_name}",
                "--", "bash", "-c", launch_cmd
            ])

            # Mantém este terminal aberto exibindo as métricas de tokens/s geradas pelo llama-server
            try:
                server_proc.wait()
            except KeyboardInterrupt:
                print("\nEncerrando servidor...")
            return

        # ── 2. LM Studio Backend ─────────────────────────────────────────────
        elif backend_mode == "lmstudio":
            working_dir = pick_folder()
            load_mcp = ask_mcp_mode()
            mcp_flag = "" if load_mcp else " --no-mcp"
            effort_val = pick_reasoning_effort()
            effort_flag = f" --effort {effort_val}"
            folder_name = os.path.basename(working_dir)
            launch_cmd = (
                f"export PATH=\"$HOME/.local/bin:$PATH\" && "
                f"cd '{working_dir}' && "
                f"{apex_bin} --url 'http://127.0.0.1:1234/v1' --model 'default'{mcp_flag}{effort_flag}; "
                f"echo ''; read -p 'Sessão concluída. Pressione Enter...'"
            )
            subprocess.Popen(["gnome-terminal", "--title", f"Apex Harness · LM Studio · {folder_name}", "--", "bash", "-c", launch_cmd])
            return

        # ── 3. Cloud API Backend ─────────────────────────────────────────────
        else:
            working_dir = pick_folder()
            load_mcp = ask_mcp_mode()
            mcp_flag = "" if load_mcp else " --no-mcp"
            effort_val = pick_reasoning_effort()
            effort_flag = f" --effort {effort_val}"
            folder_name = os.path.basename(working_dir)
            launch_cmd = (
                f"export PATH=\"$HOME/.local/bin:$PATH\" && "
                f"cd '{working_dir}' && "
                f"{apex_bin}{mcp_flag}{effort_flag}; "
                f"echo ''; read -p 'Sessão concluída. Pressione Enter...'"
            )
            subprocess.Popen(["gnome-terminal", "--title", f"Apex Harness · Cloud · {folder_name}", "--", "bash", "-c", launch_cmd])
            return

    except KeyboardInterrupt:
        print("\nSessão cancelada pelo utilizador.")
    except Exception as err:
        print(f"\n\033[1;31mOcorreu um erro: {err}\033[0m")
        input("\nPressione Enter para fechar...")
    finally:
        cleanup()

if __name__ == "__main__":
    main()
