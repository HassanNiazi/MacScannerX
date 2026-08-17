#!/bin/bash
# Builds MacScannerX and assembles a runnable .app bundle, optionally wrapped in
# a DMG. Xcode is not required — Command Line Tools + SwiftPM are enough.
#
#   ./build.sh                           release build, .app only
#   ./build.sh debug                     debug build
#   ./build.sh release universal dmg     universal .app plus MacScannerX.dmg
#
# VERSION and BUILD_NUMBER, when set, are stamped into the bundled Info.plist.
# Unset, the bundle keeps whatever the checked-in plist says.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
MAKE_DMG=0
UNIVERSAL=0
for arg in "$@"; do
  case "${arg}" in
    debug|release) CONFIG="${arg}" ;;
    dmg)           MAKE_DMG=1 ;;
    universal)     UNIVERSAL=1 ;;
    *) echo "usage: $0 [debug|release] [universal] [dmg]" >&2; exit 2 ;;
  esac
done

APP_NAME="MacScannerX"
BUNDLE="build/${APP_NAME}.app"
DMG="build/${APP_NAME}.dmg"
DEPLOY_TARGET="macosx14.0"

if [ "${UNIVERSAL}" -eq 1 ]; then
  # Two single-arch builds glued with lipo. SwiftPM's own --arch flag needs
  # XCBuild, which ships with full Xcode — cross-compiling by triple does not.
  BIN="build/${APP_NAME}-universal"
  mkdir -p build
  SLICES=()
  for arch in arm64 x86_64; do
    echo "==> Compiling ${arch} (${CONFIG})"
    swift build -c "${CONFIG}" --triple "${arch}-apple-${DEPLOY_TARGET}"
    SLICES+=("$(swift build -c "${CONFIG}" --triple "${arch}-apple-${DEPLOY_TARGET}" --show-bin-path)/${APP_NAME}")
  done
  lipo -create -output "${BIN}" "${SLICES[@]}"
  echo "==> Merged $(lipo -archs "${BIN}")"
else
  echo "==> Compiling (${CONFIG})"
  swift build -c "${CONFIG}"
  BIN="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
fi

if [ ! -x "${BIN}" ]; then
  echo "error: binary not found at ${BIN}" >&2
  exit 1
fi

# The .icns is committed; re-render it only when its generator has moved on.
if [ ! -f Resources/AppIcon.icns ] || [ Tools/MakeAppIcon.swift -nt Resources/AppIcon.icns ]; then
  echo "==> Rendering app icon"
  mkdir -p build
  swift Tools/MakeAppIcon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

# Version stamping happens before signing — the signature covers Info.plist.
PLIST="${BUNDLE}/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}"
  echo "    version ${VERSION}"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST}"
  echo "    build   ${BUILD_NUMBER}"
fi

# Ad-hoc signature. Without it, the local-network and Image Capture prompts
# have no stable identity to attach to and macOS re-asks on every launch.
echo "==> Signing (ad-hoc)"
codesign --force --sign - \
  --entitlements Resources/MacScannerX.entitlements \
  --timestamp=none \
  "${BUNDLE}" 2>&1 | sed 's/^/    /'

if [ "${MAKE_DMG}" -eq 1 ]; then
  echo "==> Packaging ${DMG}"
  STAGE="build/dmg-stage"
  rm -rf "${STAGE}" "${DMG}"
  mkdir -p "${STAGE}"
  cp -R "${BUNDLE}" "${STAGE}/${APP_NAME}.app"
  ln -s /Applications "${STAGE}/Applications"   # the usual drag-here target
  hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" \
    -ov -format UDZO "${DMG}" | sed 's/^/    /'
  rm -rf "${STAGE}"
  (cd build && shasum -a 256 "${APP_NAME}.dmg" > "${APP_NAME}.dmg.sha256")
fi

echo "==> Built ${BUNDLE}"
if [ "${MAKE_DMG}" -eq 1 ]; then
  echo "    dmg:  ${DMG}"
fi
echo "    run:  open ${BUNDLE}"
echo "    log:  ${BUNDLE}/Contents/MacOS/${APP_NAME}   # to see stderr in the terminal"
