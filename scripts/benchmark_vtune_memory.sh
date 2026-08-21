#!/usr/bin/env bash
set -euo pipefail

echo "========================================="
echo "   BENCHMARK VTUNE (Memory Access & Cache Misses)"
echo "========================================="

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

PROJECT_DIR="$HOME/intel/vtune/projects/suckless-odin"
mkdir -p "$PROJECT_DIR"
OUT_DIR="./build/profiling/vtune"
mkdir -p "$OUT_DIR"

TMP_DIR=$(mktemp -d)
export TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

chmod +x ./scripts/interactive_runner.sh

echo "[vtune] Collection memory-access..."
"$VTUNE_BIN" -collect memory-access -result-dir "$PROJECT_DIR/r@@@ma" -- env TMP_DIR="$TMP_DIR" ./scripts/interactive_runner.sh "$APP_BIN"

RES_DIR=$(ls -td "$PROJECT_DIR"/r* 2>/dev/null | head -n1 || true)

echo "[vtune] Rendu du rapport Memory Access..."
SUMMARY_FILE="$OUT_DIR/vtune_memory_summary.txt"
"$VTUNE_BIN" -report summary -r "$RES_DIR" -format=text >"$SUMMARY_FILE" 2>&1 || true

echo ""
echo "=========================================================================="
echo "📊 RÉSUMÉ MÉMOIRE & CACHE MISSES (Intel VTune)"
echo "=========================================================================="
grep -E "Memory Bound|L1 Bound|L2 Bound|L3 Bound|DRAM Bound|Load Handled|Store Handled|LLC Miss|Average Latency" "$SUMMARY_FILE" || head -n 35 "$SUMMARY_FILE" || true
RUNNER_LOG_FILE=$(find "$TMP_DIR" -name "runner_app_*.log" 2>/dev/null | head -n1 || true)
if [ -n "$RUNNER_LOG_FILE" ] && [ -f "$RUNNER_LOG_FILE" ]; then
	echo "--------------------------------------------------------------------------"
	grep "\[SIMD 4K HDR MICRO-BENCHMARK\]" -A 4 "$RUNNER_LOG_FILE" || true
fi
echo "=========================================================================="

echo ""
echo "✅ Résultats enregistrés dans le projet VTune : $PROJECT_DIR"
echo "👉 Pour explorer dans VTune Profiler GUI : task profile-vtune-gui (ou vtune-gui \"$PROJECT_DIR/suckless-odin.vtuneproj\")"
