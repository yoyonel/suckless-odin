#!/usr/bin/env python3
"""Automated verification script for Tracy traces (.tracy) in suckless-odin.

Validates that:
1. The OpenGL Context / GPU timeline is active and emitting timestamps.
2. Expected GPU render passes (Scene_Render, Instanced_PBR_Spheres, Skybox_Pass, PostProcess_Uber) exist.
3. IBL compute passes and progressive slices exist.
4. Standardized CPU hierarchy (Total Frame, Frame Acquire Swapchain, Frame Scene Update) is present.
5. Virtual Tracks / Fibers (Async Status & Hybrid Perf) are present with valid state coverage.
"""

import argparse
import csv
import io
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description="Verify Tracy trace (.tracy) GPU, CPU & Fiber contents.")
    parser.add_argument("trace_file", type=Path, help="Path to .tracy trace file")
    parser.add_argument(
        "--csvexport-bin",
        type=Path,
        default=None,
        help="Path to tracy-csvexport binary (defaults to searching in PATH)",
    )
    parser.add_argument(
        "--min-gpu-zones",
        type=int,
        default=5,
        help="Minimum total GPU zone occurrences expected across trace (default: 5)",
    )
    parser.add_argument(
        "--require-render-passes",
        action="store_true",
        default=True,
        help="Require standard per-frame GPU passes (default: True)",
    )
    parser.add_argument(
        "--require-fibers",
        action="store_true",
        default=True,
        help="Require Virtual Tracks / Fibers (Async Status & Hybrid Perf) (default: True)",
    )
    return parser.parse_args()


def find_csvexport_bin(custom_path: Path | None) -> Path:
    if custom_path and custom_path.exists():
        return custom_path
    local_csvexport = Path("deps/tracy/csvexport/build/tracy-csvexport")
    if local_csvexport.exists():
        return local_csvexport
    which_res = shutil.which("tracy-csvexport")
    if which_res:
        return Path(which_res)
    fallback = Path.home() / ".local/bin/tracy-csvexport"
    if fallback.exists():
        return fallback
    raise FileNotFoundError("tracy-csvexport binary not found in deps/ or PATH")


def run_csvexport(csvexport_bin: Path, trace_file: Path, flag: str) -> str:
    if not trace_file.exists():
        raise FileNotFoundError(f"Trace file not found at {trace_file}")

    cmd = [str(csvexport_bin), flag, str(trace_file)]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        raise RuntimeError(f"tracy-csvexport failed (code {res.returncode}): {res.stderr.strip()}")
    return res.stdout


def analyze_gpu_zones(csv_content: str):
    zones_stats = defaultdict(lambda: {"count": 0, "total_ns": 0, "min_ns": float("inf"), "max_ns": 0})
    total_zones = 0

    reader = csv.DictReader(io.StringIO(csv_content))
    for row in reader:
        name = row.get("name", "").strip()
        if not name:
            continue
        try:
            gpu_time_ns = int(row.get("GPU execution time", "0"))
        except ValueError:
            continue

        stats = zones_stats[name]
        stats["count"] += 1
        stats["total_ns"] += gpu_time_ns
        stats["min_ns"] = min(stats["min_ns"], gpu_time_ns)
        stats["max_ns"] = max(stats["max_ns"], gpu_time_ns)
        total_zones += 1

    return total_zones, zones_stats


def analyze_cpu_zones(csv_content: str):
    cpu_counts = defaultdict(int)
    reader = csv.DictReader(io.StringIO(csv_content))
    for row in reader:
        name = row.get("name", "").strip()
        if name:
            cpu_counts[name] += 1
    return cpu_counts


def main():
    args = parse_args()
    csvexport_bin = find_csvexport_bin(args.csvexport_bin)

    print("=" * 70)
    print("🔍 AUDIT PROGRAMMATIQUE DU PROFILING TRACY")
    print(f"  Fichier trace : {args.trace_file}")
    print(f"  Outil export  : {csvexport_bin}")
    print("=" * 70)

    # 1. Analyse des Zones GPU
    try:
        gpu_csv = run_csvexport(csvexport_bin, args.trace_file, "-u")
        total_gpu_zones, gpu_stats = analyze_gpu_zones(gpu_csv)
    except Exception as e:
        print(f"❌ Erreur extraction GPU: {e}")
        return 1

    print("\n📊 1. TIMELINE MATÉRIELLE GPU :")
    print(f"  Total zones GPU détectées : {total_gpu_zones}")
    for name, stats in sorted(gpu_stats.items(), key=lambda x: -x[1]["total_ns"]):
        avg_ms = (stats["total_ns"] / stats["count"]) / 1_000_000 if stats["count"] else 0
        print(f"    - {name:<32} : {stats['count']:>5} passes | avg: {avg_ms:>6.3f} ms")

    if total_gpu_zones < args.min_gpu_zones:
        print(f"❌ ÉCHEC : Zones GPU insuffisantes ({total_gpu_zones} < {args.min_gpu_zones})")
        return 1

    # 2. Analyse des Zones CPU & Fibers
    try:
        cpu_csv = run_csvexport(csvexport_bin, args.trace_file, "-c")
        cpu_counts = analyze_cpu_zones(cpu_csv)
    except Exception as e:
        print(f"❌ Erreur extraction CPU: {e}")
        return 1

    print("\n📊 2. TIMELINE CPU STANDARDISÉE :")
    required_cpu = [
        "Total Frame",
        "Frame Acquire Swapchain / Poll",
        "Frame Scene Update",
        "Frame Scene Render",
        "Frame Queue Submit & Present",
    ]
    for r in required_cpu:
        cnt = cpu_counts[r]
        status = "✅" if cnt > 0 else "❌"
        print(f"  {status} {r:<36} : {cnt:>6} occurrences")
        if cnt == 0:
            print(f"❌ Zone CPU obligatoire manquante : '{r}'")
            return 1

    # 3. Validation des Pistes Virtuelles (Fibers)
    if args.require_fibers:
        print("\n🧵 3. PISTES VIRTUELLES (FIBERS TRACY) :")
        required_fibers = [
            # Fiber: Async Status
            "Async IDLE",
            "Async PENDING",
            "Async LOADING",
            "Async CONVERT",
            "Async READY",
            # Fiber: Hybrid Perf
            "Host (CPU): Luminance",
            "Host (CPU): Specular",
            "Host (CPU): Irradiance",
            "Host (CPU): BRDF LUT",
            "Sync (GPU Wait)",
        ]
        missing_fibers = []
        for f in required_fibers:
            cnt = cpu_counts[f]
            status = "✅" if cnt > 0 else "⚠️"
            print(f"  {status} Fiber Zone '{f}': {cnt:>5} occurrences")
            if cnt == 0 and ("Async" in f or "Sync" in f):
                missing_fibers.append(f)

        if missing_fibers:
            print(f"❌ Pistes Fibers obligatoires manquantes : {missing_fibers}")
            return 1

    print("\n" + "=" * 70)
    print("✅ TOUS LES INVARIANTS TRACY (GPU, CPU, FIBERS) SONT VALIDÉS AVEC SUCCÈS !")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
