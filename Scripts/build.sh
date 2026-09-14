#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="DisplaySleeper"
BUILD_DIR="${ROOT_DIR}/.build"
APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

echo "==> Building ${APP_NAME}..."

mkdir -p "${BUILD_DIR}/module-cache"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Compile Swift sources
SDK_PATH="$(xcrun --show-sdk-path)"

swiftc \
    -sdk "${SDK_PATH}" \
    -module-cache-path "${BUILD_DIR}/module-cache" \
    -O \
    -framework Cocoa \
    -framework IOKit \
    -framework CoreGraphics \
    -framework ApplicationServices \
    "${ROOT_DIR}/Sources/DisplaySleeper/LidLatchManager.swift" \
    "${ROOT_DIR}/Sources/DisplaySleeper/AppDelegate.swift" \
    "${ROOT_DIR}/Sources/DisplaySleeper/main.swift" \
    -o "${MACOS_DIR}/${APP_NAME}"

# Copy Info.plist
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Ad-hoc code signing
echo "==> Signing ${APP_NAME}.app..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Successfully created ${APP_BUNDLE}"
