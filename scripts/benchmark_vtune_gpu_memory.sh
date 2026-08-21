#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================================="
echo "   BENCHMARK VTUNE (GPU Global Memory, SLM & L3 Cache Bandwidth)"
echo "=========================================================================="

APP_BIN="./build/relwithdebinfo/suckless-odin"
if [ ! -f "$APP_BIN" ]; then
	echo "Info: $APP_BIN manquant, tentative avec ./build/release/suckless-odin"
	APP_BIN="./build/release/suckless-odin"
	if [ ! -f "$APP_BIN" ]; then
		echo "Erreur: binaire manquant. Lancez d'abord 'task build-relwithdebinfo' ou 'task build-release'."
		exit 1
	fi
fi

VTUNE_BIN=""
if command -v vtune >/dev/null 2>&1; then
	VTUNE_BIN=$(command -v vtune)
elif [ -x /opt/intel/oneapi/vtune/latest/bin64/vtune ]; then
	VTUNE_BIN="/opt/intel/oneapi/vtune/latest/bin64/vtune"
elif [ -d /opt/intel/oneapi/vtune ]; then
	VTUNE_BIN=$(find /opt/intel/oneapi/vtune -name vtune -type f -perm -111 2>/dev/null | grep bin64 | head -n1 || true)
fi

if [ -z "$VTUNE_BIN" ] || [ ! -x "$VTUNE_BIN" ]; then
	echo "Erreur: Intel VTune Profiler (vtune) introuvable dans PATH ou /opt/intel/oneapi/vtune."
	exit 1
fi

if [ -f /opt/intel/oneapi/setvars.sh ]; then
	# shellcheck disable=SC1091
	source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 || true
fi

export LD_LIBRARY_PATH="$HOME/.local/lib:${LD_LIBRARY_PATH:-}"

PROJECT_DIR="$HOME/intel/vtune/projects/suckless-odin"
mkdir -p "$PROJECT_DIR"
OUT_DIR="./build/profiling/vtune"
mkdir -p "$OUT_DIR"

if [ -f /proc/sys/dev/i915/perf_stream_paranoid ]; then
	PARANOID=$(cat /proc/sys/dev/i915/perf_stream_paranoid 2>/dev/null || echo "1")
	if [ "$PARANOID" != "0" ] && [ "$(id -u)" != "0" ]; then
		echo "⚠️  Note Système : La collecte bas niveau des compteurs matériels GPU Intel (EU, L3, Sampler) requiert :"
		echo "   sudo sysctl dev.i915.perf_stream_paranoid=0"
		echo "   (ou d'appartenir au groupe render : sudo usermod -aG render \$USER)"
		echo ""
	fi
fi

TMP_DIR=$(mktemp -d)
export TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

chmod +x ./scripts/interactive_runner.sh

echo "[vtune] Collection GPU Global Memory Accesses..."
"$VTUNE_BIN" -collect gpu-hotspots -knob characterization-mode=global-memory-accesses -start-paused -result-dir "$PROJECT_DIR/r@@@gpu_mem" -- env TMP_DIR="$TMP_DIR" ./scripts/interactive_runner.sh "$APP_BIN"

RES_DIR=$(ls -td "$PROJECT_DIR"/r*gpu_mem* 2>/dev/null | head -n1 || true)

if [ -n "$RES_DIR" ] && [ -d "$RES_DIR" ]; then
	echo ""
	echo "=========================================================================="
	echo "📊 TOP GPU MEMORY ACCESSES & BANDWIDTH BOTTLENECKS"
	echo "=========================================================================="
	SUMMARY_FILE="$OUT_DIR/vtune_gpu_memory_summary.txt"
	"$VTUNE_BIN" -report summary -r "$RES_DIR" -format=text 2>&1 | grep -v "^vtune:" >"$SUMMARY_FILE" || true
	cat "$SUMMARY_FILE"
	echo "=========================================================================="
	echo "✓ Rapport sauvegardé dans $SUMMARY_FILE"
	echo "✓ Projet VTune complet : $RES_DIR"
fi
