#!/usr/bin/env bash
set -euo pipefail

echo "========================================="
echo "   BENCHMARK VTUNE (CPU Hotspots)"
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

echo "[vtune] Collection hotspots..."
"$VTUNE_BIN" -collect hotspots -result-dir "$PROJECT_DIR/r@@@hs" -- env TMP_DIR="$TMP_DIR" ./scripts/interactive_runner.sh "$APP_BIN"

RES_DIR=$(ls -td "$PROJECT_DIR"/r* 2>/dev/null | head -n1 || true)

echo ""
echo "=========================================================================="
echo "📊 TOP 15 CPU HOTSPOTS (Fonctions les plus coûteuses en temps CPU)"
echo "=========================================================================="
SUMMARY_FILE="$OUT_DIR/vtune_hotspots_summary.txt"
"$VTUNE_BIN" -report hotspots -r "$RES_DIR" -format=text -limit=15 2>&1 | grep -v "^vtune:" | c++filt >"$SUMMARY_FILE" || true
cat "$SUMMARY_FILE"
echo "=========================================================================="

echo ""
echo "✅ Résultats enregistrés dans le projet VTune : $PROJECT_DIR"
echo "👉 Pour explorer dans VTune Profiler GUI : task profile-vtune-gui (ou vtune-gui \"$PROJECT_DIR/suckless-odin.vtuneproj\")"
