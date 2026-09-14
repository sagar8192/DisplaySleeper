#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${ROOT_DIR}/.build"
mkdir -p "${BUILD_DIR}/module-cache"

SDK_PATH="$(xcrun --show-sdk-path)"

echo "==> Compiling and running tests..."
swiftc \
    -sdk "${SDK_PATH}" \
    -module-cache-path "${BUILD_DIR}/module-cache" \
    -framework Cocoa \
    -framework IOKit \
    -framework CoreGraphics \
    -framework ApplicationServices \
    "${ROOT_DIR}/Sources/DisplaySleeper/LidLatchManager.swift" \
    "${ROOT_DIR}/Tests/main.swift" \
    -o "${BUILD_DIR}/test_runner"

"${BUILD_DIR}/test_runner"
