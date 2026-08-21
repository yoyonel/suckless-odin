#!/usr/bin/env bash
# verify_codegen.sh — Verify State Machine codegen parity.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

mkdir -p build/bin
odin build tools/codegen -out:build/bin/generate_states -o:speed
./build/bin/generate_states verification/EnvManagerVerification.tla
git diff --exit-code src/scene/env_manager_states.gen.odin
echo "==> State machine codegen verification PASSED."
