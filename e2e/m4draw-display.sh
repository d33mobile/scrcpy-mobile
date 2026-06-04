#!/usr/bin/env bash
# e2e/m4draw-display.sh — THIN SHIM (kept for historical/D3 callers).
#
# The drawing-e2e flow this file used to carry has been CONSOLIDATED into the
# single authoritative entry script e2e/run-draw.sh (milestone D4): that one
# script runs the full flow (setup -> connect -> CONTROL stroke geometry on B ->
# DISPLAY round-trip red-on-A -> L shape on both B and A) with the same OUTER/
# INNER + docker-run structure that lived here. To avoid duplicating the large
# inner logic, this shim simply execs run-draw.sh with the same arguments.
#
# Use e2e/run-draw.sh (and e2e/run-draw-on-d-claude.sh) directly going forward.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$REPO_ROOT/e2e/run-draw.sh" "$@"
