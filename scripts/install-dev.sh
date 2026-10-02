#!/bin/bash
# ai-processed:unverified · session:unknown/agent:alpha-product-fixes · 2026-10-01
# Compatibility entrypoint: use the same staged, guarded deployment on all three Macs.
# M3_ONLY=1 remains the explicit local-only override supported by the fleet script.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$REPO_DIR/scripts/dev-deploy-fleet.sh" "$@"
