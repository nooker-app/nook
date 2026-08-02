#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
OUTPUT_DIR="${1:-${SCRIPT_DIR}/output}"
MODULE_CACHE="${TMPDIR:-/tmp}/nook-app-store-module-cache"

mkdir -p "${OUTPUT_DIR}" "${MODULE_CACHE}"

cd "${REPO_ROOT}"
/usr/bin/xcrun swift \
  -module-cache-path "${MODULE_CACHE}" \
  "${SCRIPT_DIR}/Sources/AppStoreRenderer.swift" \
  "${SCRIPT_DIR}/config.json" \
  "${OUTPUT_DIR}"
