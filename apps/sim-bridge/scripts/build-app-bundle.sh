#!/usr/bin/env bash
# Builds SimBridge.app from the swift package output.
# Usage: scripts/build-app-bundle.sh [output-dir]
# Default output: .build/release/SimBridge.app
set -euo pipefail

cd "$(dirname "$0")/.."
PKG_ROOT="$(pwd)"
CONFIG="release"
OUTPUT_DIR="${1:-${PKG_ROOT}/.build/${CONFIG}}"
APP_BUNDLE="${OUTPUT_DIR}/SimBridge.app"

echo "[build-app-bundle] swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="${PKG_ROOT}/.build/${CONFIG}/sim-bridge"
if [ ! -x "${BIN_PATH}" ]; then
  echo "[build-app-bundle] missing executable at ${BIN_PATH}" >&2
  exit 1
fi

echo "[build-app-bundle] assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/sim-bridge"
cp "${PKG_ROOT}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

ENT="${PKG_ROOT}/Resources/SimBridge.entitlements"

echo "[build-app-bundle] codesign ad-hoc"
codesign --force --sign - \
  --identifier com.t3tools.simbridge \
  --options runtime \
  --entitlements "${ENT}" \
  --timestamp=none \
  "${APP_BUNDLE}/Contents/MacOS/sim-bridge"

codesign --force --sign - \
  --identifier com.t3tools.simbridge \
  --options runtime \
  --entitlements "${ENT}" \
  --timestamp=none \
  "${APP_BUNDLE}"

echo "[build-app-bundle] verify"
codesign --display --verbose=2 "${APP_BUNDLE}" 2>&1 | sed 's/^/  /'

echo "[build-app-bundle] done -> ${APP_BUNDLE}"
