#!/usr/bin/env python3
"""
before_after.py — mede o launcher ANTIGO vs o launcher CORRIGIDO, no mesmo modelo.

Corre o `launch_llama_server` real (legacy, de `launcher_common`) ou o substituto
de `apex_harness.optimized_launcher` (optimized), espera pelo servidor, mede com
`apex_bench.py` e desliga tudo.

Isto é o que produz o número "antes/depois" — não uma reimplementação, mas o
código que o harness realmente executa.

Uso:
  python3 bench/before_after.py --mode legacy    --model X.gguf --label before
  python3 bench/before_after.py --mode optimized --model X.gguf --label after
"""
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, os.path.expanduser("~/.local/lib"))


def wait_ready(port: int, proc: subprocess.Popen, log_path: str, timeout: int = 900) -> bool:
    """O servidor só responde em /v1/models quando os pesos estão carregados.

    /health responde 200 durante o carregamento, por isso não serve como sinal.
    """
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            print(f"!!! servidor morreu (exit {proc.returncode}); tail de {log_path}:")
            try:
                print("\n".join(Path(log_path).read_text(errors="replace").splitlines()[-25:]))
            except Exception:
                pass
            return False
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/models", timeout=3) as r:
                if r.getcode() == 200:
                    return True
        except Exception:
            pass
        time.sleep(1)
    return False


def drain(proc: subprocess.Popen, log_path: str) -> threading.Thread:
    """
    Drena stdout do servidor numa thread, gravando em log_path.

    OBRIGATÓRIO e não opcional: `launch_llama_server` devolve o proc com
    stdout=PIPE e NÃO grava nada no `log_file` que devolve — o log só aparece se
    alguém drenar o pipe. Se ninguém o fizer, o pipe enche (64 KiB) e o
    llama-server BLOQUEIA a meio do carregamento. O `launcher.py` real chama
    `stream_server_output()` precisamente por isto; qualquer outro chamador que
    se esqueça fica com um servidor pendurado. É um bug latente da API.
    """
    fh = open(log_path, "w")

    def _run():
        try:
            for line in iter(proc.stdout.readline, ""):
                fh.write(line)
                fh.flush()
        except Exception:
            pass
        finally:
            try:
                fh.close()
            except Exception:
                pass

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    return t


def kill_tree(proc: subprocess.Popen) -> None:
    """Mata o grupo de processos inteiro (o launcher embrulha em taskset/env)."""
    if proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
    try:
        proc.wait(timeout=5)
    except Exception:
        pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", required=True, choices=["legacy", "optimized"])
    ap.add_argument("--model", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--context", type=int, default=32768)
    ap.add_argument("--prompt-tokens", type=int, nargs="+", default=[512, 4096])
    ap.add_argument("--gen-tokens", type=int, default=256)
    a = ap.parse_args()

    print("=" * 88)
    print(f" MODO: {a.mode}   LABEL: {a.label}   MODELO: {os.path.basename(a.model)}")
    print("=" * 88)

    # Isola o servidor no seu próprio grupo de processos, para o poder matar inteiro.
    if a.mode == "legacy":
        import launcher_common as lc
        print(f" launcher: launcher_common.launch_llama_server")
        print(f"           {lc.__file__}")

        class _P(lc.subprocess.Popen):        # type: ignore[misc]
            def __init__(self, *args, **kw):
                kw["preexec_fn"] = os.setsid
                super().__init__(*args, **kw)

        orig = lc.subprocess.Popen
        lc.subprocess.Popen = _P             # type: ignore[assignment]
        try:
            proc, _log_file, log_path = lc.launch_llama_server(
                a.model, port=a.port, context=a.context
            )
        finally:
            lc.subprocess.Popen = orig       # type: ignore[assignment]
    else:
        from apex_harness.optimized_launcher import launch_llama_server
        print(" launcher: apex_harness.optimized_launcher.launch_llama_server")
        proc, _log_file, log_path = launch_llama_server(
            a.model, port=a.port, context=a.context, verbose=True
        )

    # O log real: o que o servidor imprime no stdout. Fica no workspace (não em
    # /tmp) para sobreviver e poder ser inspecionado depois.
    results_dir = ROOT / "benchmarks" / "resultados"
    results_dir.mkdir(parents=True, exist_ok=True)
    real_log = str(results_dir / f"serverlog-{a.label}.log")
    drain(proc, real_log)

    try:
        if not wait_ready(a.port, proc, real_log):
            print("!!! servidor não ficou pronto")
            return 1

        # Parâmetros que o llama.cpp REALMENTE escolheu (a prova, não a intenção).
        print("\n--- parâmetros efetivos (do stdout do servidor) ---")
        keys = ("n_threads", "n_threads_batch", "n_gpu_layers", "offloaded", "flash_attn",
                "n_ctx", "n_batch", "n_ubatch", "type_k", "type_v", "cpu_mask", "cpu-mask",
                "spec", "ngram", "listening", "process priority", "threadpool")
        try:
            txt = Path(real_log).read_text(errors="replace")
            seen = set()
            for line in txt.splitlines():
                s = line.strip()
                if any(k in s for k in keys) and s not in seen:
                    seen.add(s)
                    print("   " + s[:150])
            if not seen:
                print("   (nada correspondente no log)")
        except Exception as e:
            print(f"   (não consegui ler o log: {e})")

        print("\n--- a medir ---")
        cmd = [
            sys.executable, str(ROOT / "benchmarks" / "apex_bench.py"),
            "--url", f"http://127.0.0.1:{a.port}/v1",
            "--port", str(a.port),
            "--label", a.label,
            "--prompt-tokens", *[str(x) for x in a.prompt_tokens],
            "--gen-tokens", str(a.gen_tokens),
            "--json", str(ROOT / "benchmarks" / "resultados" / f"{a.label}.json"),
        ]
        return subprocess.call(cmd)
    finally:
        kill_tree(proc)
        # A porta tem de ficar livre antes do próximo modo.
        time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())
