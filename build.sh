#!/bin/bash
# Builds VueScanX and assembles a runnable .app bundle.
# Xcode is not required — Command Line Tools + SwiftPM are enough.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="VueScanX"
BUNDLE="build/${APP_NAME}.app"

echo "==> Compiling (${CONFIG})"
swift build -c "${CONFIG}"

BIN="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [ ! -x "${BIN}" ]; then
  echo "error: binary not found at ${BIN}" >&2
  exit 1
fi

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

# Ad-hoc signature. Without it, the local-network and Image Capture prompts
# have no stable identity to attach to and macOS re-asks on every launch.
echo "==> Signing (ad-hoc)"
codesign --force --sign - \
  --entitlements Resources/VueScanX.entitlements \
  --timestamp=none \
  "${BUNDLE}" 2>&1 | sed 's/^/    /'

echo "==> Built ${BUNDLE}"
echo "    run:  open ${BUNDLE}"
echo "    log:  ${BUNDLE}/Contents/MacOS/${APP_NAME}   # to see stderr in the terminal"
