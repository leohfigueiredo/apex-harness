#!/usr/bin/env python3
"""
apex_bench.py — Standardised LLM inference benchmark for the Apex Harness.

Measures, against a live `llama-server` OpenAI-compatible endpoint:

  * TTFT              — time to first token (ms), client-observed
  * Prefill / prompt  — prompt-eval throughput (t/s), server-reported + client-observed
  * Decode / gen      — generation throughput (t/s), server-reported + client-observed
  * Effective bandwidth — model_bytes * decode_tps  (GB/s), the number that tells you
                          whether you are at the memory-bandwidth wall
  * Peak memory       — server RSS peak + VRAM/GTT peak (AMD APU sysfs)

It uses the *server's own* `timings` block as the ground truth for t/s (so Python
client overhead cannot flatter or hide the result) and additionally reports
client-observed wall-clock t/s so you can see harness overhead separately.

Usage
-----
  # benchmark whatever is already listening on :8080
  python3 benchmarks/apex_bench.py

  # benchmark and also record which model/flags the server reported
  python3 benchmarks/apex_bench.py --url http://127.0.0.1:8080/v1 --label "baseline"

  # sweep prompt sizes (prefill scaling) and generation lengths
  python3 benchmarks/apex_bench.py --prompt-tokens 128 512 2048 8192 --gen-tokens 128 512

  # write machine-readable results
  python3 benchmarks/apex_bench.py --json benchmarks/resultados/latest.json --csv benchmarks/resultados/latest.csv

Exit code is 0 when every configuration produced a result, 1 otherwise.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re

import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any, Dict, List, Optional

# --------------------------------------------------------------------------- #
#  Hardware probes
# --------------------------------------------------------------------------- #

def _read(path: str) -> Optional[str]:
    try:
        return Path(path).read_text().strip()
    except Exception:
        return None


def probe_amd_apu() -> Dict[str, Any]:
    """Read VRAM/GTT counters exposed by the amdgpu driver (APU-aware)."""
    out: Dict[str, Any] = {}
    base = Path("/sys/class/drm")
    for card in sorted(base.glob("card[0-9]*")):
        dev = card / "device"
        if not (dev / "mem_info_vram_total").exists():
            continue
        for key, fname in (
            ("vram_total", "mem_info_vram_total"),
            ("vram_used", "mem_info_vram_used"),
            ("gtt_total", "mem_info_gtt_total"),
            ("gtt_used", "mem_info_gtt_used"),
        ):
            v = _read(str(dev / fname))
            if v and v.isdigit():
                out[f"{card.name}_{key}_gib"] = round(int(v) / 1024**3, 2)
    return out


def probe_cpu_topology() -> Dict[str, Any]:
    """Report the hybrid Zen5 / Zen5c split, which is what makes affinity matter."""
    topo: Dict[str, Any] = {"threads": os.cpu_count()}
    try:
        # -p=... (parsable) is mutually exclusive with -e=.../-c=... ; use -p only.
        txt = subprocess.check_output(["lscpu", "-p=CPU,MAXMHZ"], text=True)
        mhz: Dict[int, float] = {}
        for line in txt.splitlines():
            if line.startswith("#") or not line.strip():
                continue
            cpu_s, mhz_s = line.split(",")[:2]
            mhz[int(cpu_s)] = float(mhz_s)
        if mhz:
            fastest = max(mhz.values())
            fast = sorted(c for c, m in mhz.items() if m >= fastest * 0.9)
            slow = sorted(c for c, m in mhz.items() if m < fastest * 0.9)
            topo["fast_cpus"] = _compact(fast)
            topo["slow_cpus"] = _compact(slow)
            topo["fast_mhz"] = round(fastest)
            topo["slow_mhz"] = round(min(mhz.values()))
    except Exception:
        pass
    return topo


def _compact(cpus: List[int]) -> str:
    """[0,1,2,3,12,13,14,15] -> '0-3,12-15'"""
    if not cpus:
        return ""
    out, start, prev = [], cpus[0], cpus[0]
    for c in cpus[1:]:
        if c == prev + 1:
            prev = c
            continue
        out.append(f"{start}-{prev}" if start != prev else f"{start}")
        start = prev = c
    out.append(f"{start}-{prev}" if start != prev else f"{start}")
    return ",".join(out)


def server_rss_kib(pid: Optional[int]) -> Optional[int]:
    if not pid:
        return None
    v = _read(f"/proc/{pid}/status")
    if not v:
        return None
    m = re.search(r"VmRSS:\s+(\d+) kB", v)
    return int(m.group(1)) if m else None


def find_server_pid(port: int) -> Optional[int]:
    try:
        out = subprocess.check_output(["pgrep", "-f", f"llama-server.*--port {port}"], text=True)
        pids = [int(x) for x in out.split()]
        return pids[0] if pids else None
    except Exception:
        try:
            out = subprocess.check_output(["pgrep", "-f", "llama-server"], text=True)
            pids = [int(x) for x in out.split()]
            return pids[0] if pids else None
        except Exception:
            return None


# --------------------------------------------------------------------------- #
#  HTTP helpers
# --------------------------------------------------------------------------- #

def http_json(url: str, payload: Optional[dict] = None, timeout: float = 30.0) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST" if data else "GET",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


# --------------------------------------------------------------------------- #
#  The measurement itself
# --------------------------------------------------------------------------- #

@dataclass
class Result:
    label: str
    prompt_tokens: int
    gen_tokens: int
    # server ground truth
    srv_prompt_n: int = 0
    srv_prompt_ms: float = 0.0
    srv_prompt_tps: float = 0.0
    srv_predicted_n: int = 0
    srv_predicted_ms: float = 0.0
    srv_predicted_tps: float = 0.0
    # client observed
    ttft_ms: float = 0.0
    client_total_ms: float = 0.0
    client_decode_tps: float = 0.0
    client_prefill_tps: float = 0.0
    # resource
    rss_peak_mib: float = 0.0
    model_size_gib: float = 0.0
    #: GiB realmente lidos do disco/RAM por token. Para um modelo DENSO e igual a
    #: model_size_gib; para um MoE e o tamanho dos pesos ATIVOS (ex.: 3B de 30B),
    #: que e o que determina o teto de decode. Calculado por hwtune.profile_model().
    effective_weight_gib: float = 0.0
    effective_bw_gbs: float = 0.0
    # meta
    server_info: Dict[str, Any] = field(default_factory=dict)
    error: str = ""


def build_prompt(target_tokens: int) -> str:
    """Deterministic filler prompt with a realistic token/char ratio (~4 chars/token)
    plus a trailing instruction so the model generates prose rather than echoing."""
    filler = ("The quick brown fox jumps over the lazy dog. "
              "Performance engineering is the discipline of measurement. ")
    body = filler * max(1, (target_tokens * 4) // len(filler))
    return (body + "\n\nNow write a detailed technical paragraph about memory "
                     "bandwidth bound inference on unified-memory APUs.")


def measure_once(
    base_url: str,
    model: str,
    prompt_tokens: int,
    gen_tokens: int,
    label: str,
    pid: Optional[int],
    timeout: float = 900.0,
) -> Result:
    res = Result(label=label, prompt_tokens=prompt_tokens, gen_tokens=gen_tokens)
    url = base_url.rstrip("/") + "/chat/completions"
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": build_prompt(prompt_tokens)}],
        "max_tokens": gen_tokens,
        "temperature": 0.0,
        "top_p": 1.0,
        "seed": 1234,
        "stream": True,
        "stream_options": {"include_usage": True},
        # llama-server extension: gives per-request timings in the final chunk
        "timings_per_token": False,
    }

    rss = server_rss_kib(pid)
    rss_peak = rss or 0

    t0 = time.perf_counter()
    ttft: Optional[float] = None
    n_chunks = 0
    last_usage: Dict[str, Any] = {}
    last_timings: Dict[str, Any] = {}

    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                body = line[5:].strip()
                if body == "[DONE]":
                    break
                try:
                    obj = json.loads(body)
                except Exception:
                    continue

                if "timings" in obj and obj["timings"]:
                    last_timings = obj["timings"]
                if obj.get("usage"):
                    last_usage = obj["usage"]

                choices = obj.get("choices") or []
                if choices:
                    delta = choices[0].get("delta") or {}
                    if delta.get("content") or delta.get("reasoning_content"):
                        if ttft is None:
                            ttft = time.perf_counter() - t0
                        n_chunks += 1

                if n_chunks % 64 == 0 and pid:
                    cur = server_rss_kib(pid)
                    if cur and cur > rss_peak:
                        rss_peak = cur
    except urllib.error.HTTPError as e:
        res.error = f"HTTP {e.code}: {e.read()[:300].decode('utf-8', 'replace')}"
        return res
    except Exception as e:
        res.error = f"{type(e).__name__}: {e}"
        return res

    total = time.perf_counter() - t0
    cur = server_rss_kib(pid)
    if cur and cur > rss_peak:
        rss_peak = cur

    res.ttft_ms = (ttft or 0.0) * 1000.0
    res.client_total_ms = total * 1000.0
    res.rss_peak_mib = rss_peak / 1024.0

    # ---- server-reported ground truth ------------------------------------- #
    if last_timings:
        res.srv_prompt_n = int(last_timings.get("prompt_n", 0) or 0)
        res.srv_prompt_ms = float(last_timings.get("prompt_ms", 0.0) or 0.0)
        res.srv_prompt_tps = float(last_timings.get("prompt_per_second", 0.0) or 0.0)
        res.srv_predicted_n = int(last_timings.get("predicted_n", 0) or 0)
        res.srv_predicted_ms = float(last_timings.get("predicted_ms", 0.0) or 0.0)
        res.srv_predicted_tps = float(last_timings.get("predicted_per_second", 0.0) or 0.0)

    if not res.srv_prompt_n and last_usage:
        res.srv_prompt_n = int(last_usage.get("prompt_tokens", 0) or 0)
        res.srv_predicted_n = int(last_usage.get("completion_tokens", 0) or 0)

    # ---- client-observed -------------------------------------------------- #
    decode_window = max(total - (ttft or 0.0), 1e-9)
    n_out = res.srv_predicted_n or n_chunks
    res.client_decode_tps = (n_out - 1) / decode_window if n_out > 1 else 0.0
    if ttft and res.srv_prompt_n:
        res.client_prefill_tps = res.srv_prompt_n / ttft

    # ---- effective bandwidth ---------------------------------------------- #
    # Para MoE isto TEM de usar os pesos ATIVOS, nao o tamanho do ficheiro: um
    # Qwen3-Coder-30B-A3B ocupa 16,3 GB no disco mas so le ~1,6 GB por token
    # (3B de 30B parametros ativos). Multiplicar pelo tamanho do ficheiro dava
    # 602 GB/s -- impossivel, com um pico medido de 118 GB/s.
    if res.srv_predicted_tps and res.effective_weight_gib:
        res.effective_bw_gbs = res.srv_predicted_tps * res.effective_weight_gib

    return res


# --------------------------------------------------------------------------- #
#  Reporting
# --------------------------------------------------------------------------- #

def fmt_table(results: List[Result], apu: Dict[str, Any], topo: Dict[str, Any]) -> str:
    w = 112
    lines: List[str] = []
    lines.append("=" * w)
    lines.append(" APEX HARNESS — INFERENCE BENCHMARK".center(w))
    lines.append("=" * w)
    if topo:
        lines.append(f" CPU   : {topo.get('threads')} threads | fast(Zen5) {topo.get('fast_cpus')} "
                     f"@{topo.get('fast_mhz')}MHz | slow(Zen5c) {topo.get('slow_cpus')} @{topo.get('slow_mhz')}MHz")
    for k in ("card0_vram_total_gib", "card0_gtt_total_gib"):
        if k in apu:
            lines.append(f" iGPU  : {k} = {apu[k]} GiB")
    lines.append("")
    hdr = (f"{'label':<14}{'pp_tok':>8}{'tg_tok':>8}{'TTFT ms':>10}"
           f"{'prefill t/s':>13}{'decode t/s':>12}{'cli dec t/s':>13}"
           f"{'BW GB/s':>9}{'RSS MiB':>10}")
    lines.append(hdr)
    lines.append("-" * w)
    for r in results:
        if r.error:
            lines.append(f"{r.label:<14}{r.prompt_tokens:>8}{r.gen_tokens:>8}   ERROR: {r.error[:60]}")
            continue
        lines.append(
            f"{r.label:<14}{r.srv_prompt_n:>8}{r.srv_predicted_n:>8}{r.ttft_ms:>10.1f}"
            f"{r.srv_prompt_tps:>13.2f}{r.srv_predicted_tps:>12.2f}{r.client_decode_tps:>13.2f}"
            f"{r.effective_bw_gbs:>9.1f}{r.rss_peak_mib:>10.0f}"
        )
    lines.append("-" * w)
    lines.append(" prefill t/s = server prompt_eval  |  decode t/s = server eval (ground truth)")
    lines.append(" cli dec t/s = wall-clock incl. Python/HTTP overhead")
    lines.append(" BW GB/s = GiB LIDOS POR TOKEN x decode t/s  (pesos ativos, nao o tamanho do ficheiro)")
    lines.append("=" * w)
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="Apex Harness standardised inference benchmark")
    ap.add_argument("--url", default=os.environ.get("APEX_API_BASE", "http://127.0.0.1:8080/v1"))
    ap.add_argument("--model", default=os.environ.get("APEX_MODEL", "llama-local-model"))
    ap.add_argument("--label", default="default")
    ap.add_argument("--prompt-tokens", type=int, nargs="+", default=[512, 4096])
    ap.add_argument("--gen-tokens", type=int, nargs="+", default=[256])
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--model-size-gib", type=float, default=0.0,
                    help="override; otherwise taken from the server's /props model_path")
    ap.add_argument("--json", dest="json_out", default="")
    ap.add_argument("--csv", dest="csv_out", default="")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    # ---- discover server -------------------------------------------------- #
    # NOTE: llama-server exposes /props, /health, /metrics and /slots at the
    # ROOT, not under /v1. Strip a trailing /v1 to get the root URL.
    root = args.url.rstrip("/")
    if root.endswith("/v1"):
        root = root[:-3].rstrip("/")

    props: Dict[str, Any] = {}
    last_err = ""
    for _ in range(60):                      # the model may still be loading
        try:
            props = http_json(root + "/props", timeout=10)
            break
        except Exception as e:
            last_err = str(e)
            time.sleep(5)
    if not props:
        print(f"FATAL: cannot reach llama-server at {args.url} "
              f"(tried {root}/props -> {last_err})", file=sys.stderr)
        return 1

    pid = find_server_pid(args.port)
    topo = probe_cpu_topology()
    apu = probe_amd_apu()

    model_path = props.get("model_path") or props.get("default_generation_settings", {}).get("model") or ""
    model_size_gib = args.model_size_gib
    if not model_size_gib and model_path and os.path.exists(model_path):
        model_size_gib = round(os.path.getsize(model_path) / 1024**3, 3)

    # MoE-aware: um modelo com 3B ativos so le ~10% dos pesos por token. Isto
    # muda completamente a leitura do numero de banda.
    eff_weight_gib = model_size_gib
    arch_hint = ""
    try:
        import sys as _sys
        _sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
        from apex_harness.hwtune import profile_model as _prof
        _p = _prof(model_path)
        if _p.size_gib:
            eff_weight_gib = round(_p.active_weight_gib, 3)
            if _p.is_moe:
                arch_hint = (f"MoE {_p.n_expert} experts, {_p.n_expert_used} ativos/token "
                             f"-> {_p.active_fraction*100:.1f}% dos pesos por token")
    except Exception:
        pass
    n_ctx = props.get("default_generation_settings", {}).get("n_ctx")
    n_threads = (props.get("default_generation_settings", {}) or {}).get("n_threads")

    print(f"server   : {args.url}  pid={pid}")
    print(f"model    : {os.path.basename(model_path) if model_path else '(unknown)'}  "
          f"({model_size_gib:.2f} GiB em disco, {eff_weight_gib:.2f} GiB lidos por token)")
    if arch_hint:
        print(f"           {arch_hint}")
    print(f"n_ctx    : {n_ctx}   n_threads: {n_threads}")
    print(f"cpu      : fast={topo.get('fast_cpus')} slow={topo.get('slow_cpus')}")
    print()

    results: List[Result] = []
    for pt in args.prompt_tokens:
        for gt in args.gen_tokens:
            for rep in range(args.repeats):
                lbl = args.label if args.repeats == 1 else f"{args.label}.{rep}"
                r = measure_once(args.url, args.model, pt, gt, lbl, pid)
                r.model_size_gib = model_size_gib
                r.effective_weight_gib = eff_weight_gib
                if r.srv_predicted_tps and eff_weight_gib:
                    r.effective_bw_gbs = r.srv_predicted_tps * eff_weight_gib
                r.server_info = {"n_ctx": n_ctx, "n_threads": n_threads, "model": model_path}
                results.append(r)
                status = f"ERROR {r.error}" if r.error else \
                    f"TTFT {r.ttft_ms:7.1f}ms  prefill {r.srv_prompt_tps:7.2f} t/s  decode {r.srv_predicted_tps:6.2f} t/s"
                print(f"  [{lbl}] pp={pt:<6} tg={gt:<5} -> {status}")

    print()
    print(fmt_table(results, apu, topo))

    ok = [r for r in results if not r.error]
    if ok:
        dec = [r.srv_predicted_tps for r in ok if r.srv_predicted_tps]
        pre = [r.srv_prompt_tps for r in ok if r.srv_prompt_tps]
        if dec:
            print(f" best decode : {max(dec):.2f} t/s")
        if pre:
            print(f" best prefill: {max(pre):.2f} t/s")
        if dec and model_size_gib:
            print(f" effective BW at best decode: {max(dec) * model_size_gib:.1f} GB/s "
                  f"(vs ~118 GB/s measured hardware peak)")

    if args.json_out:
        p = Path(args.json_out); p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "url": args.url, "model": model_path, "model_size_gib": model_size_gib,
            "n_ctx": n_ctx, "n_threads": n_threads,
            "cpu_topology": topo, "apu": apu,
            "results": [asdict(r) for r in results],
        }, indent=2))
        print(f"json -> {p}")

    if args.csv_out:
        p = Path(args.csv_out); p.parent.mkdir(parents=True, exist_ok=True)
        new = not p.exists()
        with p.open("a", newline="") as f:
            wr = csv.DictWriter(f, fieldnames=list(asdict(results[0]).keys()))
            if new:
                wr.writeheader()
            for r in results:
                wr.writerow(asdict(r))
        print(f"csv  -> {p}")

    return 0 if all(not r.error for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
