#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================================="
echo "🎯 CAPTURE AUTOMATIQUE RENDERDOC IBL MULTI-TRAMES"
echo "=========================================================================="

RENDERDOC_CMD="${RENDERDOC_DIR:-/usr/bin}/renderdoccmd"
if [ ! -x "$RENDERDOC_CMD" ]; then
	if command -v renderdoccmd >/dev/null 2>&1; then
		RENDERDOC_CMD="$(command -v renderdoccmd)"
	elif [ -x "$HOME/.local/renderdoc_1.42/bin/renderdoccmd" ]; then
		RENDERDOC_CMD="$HOME/.local/renderdoc_1.42/bin/renderdoccmd"
	else
		echo "Erreur: renderdoccmd introuvable dans ${RENDERDOC_DIR:-} ou dans PATH."
		echo "Définissez RENDERDOC_DIR (ex: export RENDERDOC_DIR=/chemin/vers/renderdoc/bin dans .envrc)."
		exit 127
	fi
fi

APP_BIN="./build/debug/suckless-odin"
if [ ! -f "$APP_BIN" ]; then
	echo "Erreur: binaire $APP_BIN introuvable. Lancez 'task build'."
	exit 1
fi

OUT_DIR="build/profiling/renderdoc"
mkdir -p "$OUT_DIR"

TMP_DIR=$(mktemp -d)
export TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

chmod +x ./scripts/interactive_runner.sh

echo "[RenderDoc] Lancement automatisé via interactive_runner..."
./scripts/interactive_runner.sh "$RENDERDOC_CMD" capture -w -d . -c "$OUT_DIR/ibl_capture" "$APP_BIN" --capture-ibl

LATEST_RDC=$(ls -td "$OUT_DIR"/ibl_capture*.rdc 2>/dev/null | head -n1 || true)
if [ -n "$LATEST_RDC" ] && [ -f "$LATEST_RDC" ]; then
	RDC_SIZE=$(du -h "$LATEST_RDC" | cut -f1)
	echo ""
	echo "=========================================================================="
	echo "✓ Capture RenderDoc IBL multi-trames terminée avec succès !"
	echo "  Fichier : $LATEST_RDC ($RDC_SIZE)"
	echo "=========================================================================="
else
	echo "Avertissement: Aucun fichier .rdc trouvé dans $OUT_DIR."
fi
