#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
APP_DIR="${BUILD_DIR}/TargetBridge Receiver.app"
BIN_NAME="TargetBridgeReceiver"
APP_NAME="TargetBridge Receiver"
APP_VERSION="4.0.1"
STAMP="${TB_BUILD_TIMESTAMP:-$(date +%Y%m%d%H%M%S)}"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || print unknown)"
ARCH="$(uname -m)"
ICONSET_DIR="$(mktemp -d)"
ICON_FILE="${ROOT}/TargetBridgeAssets/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
ICNS_PATH="${APP_DIR}/Contents/Resources/TargetBridgeReceiver.icns"

cd "$ROOT/TBReceiverC"
make clean
make APP_VERSION="${APP_VERSION}" APP_BUILD="$STAMP" APP_COMMIT="$COMMIT"

mkdir -p "$BUILD_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Resources/Languages"

cp "$ROOT/TBReceiverC/tbreceiver" "$APP_DIR/Contents/MacOS/$BIN_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "$REPO_ROOT/TargetBridge-Shared/Languages/"*.json "$APP_DIR/Contents/Resources/Languages/"

# Bundle dylib dependencies (ffmpeg and SDL) inside the .app.
# Some Homebrew setups provide SDL2 through sdl2-compat, which loads SDL3 at
# runtime via dlopen. dylibbundler cannot discover that dynamic dependency, so
# copy SDL3 when the installed SDL2 binary actually references it. A native
# SDL2 installation (such as SDL 2.32.x) does not need SDL3.
mkdir -p "$APP_DIR/Contents/Frameworks"
if ! command -v dylibbundler &>/dev/null; then
  echo "Installing dylibbundler..."
  brew install dylibbundler
fi
dylibbundler -od -b \
  -x "$APP_DIR/Contents/MacOS/$BIN_NAME" \
  -d "$APP_DIR/Contents/Frameworks/" \
  -p @executable_path/../Frameworks/ \
  >/dev/null 2>&1

SDL2_DYLIB="$(brew --prefix sdl2)/lib/libSDL2.dylib"
SDL2_NEEDS_SDL3=0
if [[ -f "$SDL2_DYLIB" ]]; then
  if otool -L "$SDL2_DYLIB" 2>/dev/null | grep -q 'libSDL3' || \
     strings "$SDL2_DYLIB" 2>/dev/null | grep -q 'libSDL3'; then
    SDL2_NEEDS_SDL3=1
  fi
fi

if (( SDL2_NEEDS_SDL3 == 1 )); then
  SDL3_DYLIB="$(brew --prefix sdl3 2>/dev/null)/lib/libSDL3.dylib"
  if [[ ! -f "$SDL3_DYLIB" ]]; then
    echo "Installed SDL2 compatibility layer requires SDL3, but SDL3 was not found." >&2
    echo "Install it with: brew install sdl3" >&2
    exit 1
  fi
  cp -L "$SDL3_DYLIB" "$APP_DIR/Contents/Frameworks/libSDL3.dylib"
else
  echo "Native SDL2 detected; SDL3 runtime is not required."
fi

if [[ -f "$ICON_FILE" ]]; then
  mkdir -p "${ICONSET_DIR}/TargetBridgeReceiver.iconset"
  sips -z 16 16     "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_16x16.png" >/dev/null
  sips -z 32 32     "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_32x32.png" >/dev/null
  sips -z 64 64     "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_128x128.png" >/dev/null
  sips -z 256 256   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_256x256.png" >/dev/null
  sips -z 512 512   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$ICON_FILE" --out "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_512x512.png" >/dev/null
  cp "$ICON_FILE" "${ICONSET_DIR}/TargetBridgeReceiver.iconset/icon_512x512@2x.png"
  iconutil -c icns "${ICONSET_DIR}/TargetBridgeReceiver.iconset" -o "$ICNS_PATH" >/dev/null 2>&1 || true
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.targetbridge.receiver</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>TargetBridgeReceiver</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>$STAMP</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
# Sign each bundled dylib first, then the app
find "$APP_DIR/Contents/Frameworks" -name "*.dylib" | while read dylib; do
  codesign --force --sign - "$dylib" >/dev/null 2>&1 || true
done
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
xattr -cr "$APP_DIR" >/dev/null 2>&1 || true
rm -rf "$ICONSET_DIR"

echo "${APP_NAME} built: $APP_DIR"
echo "Version: ${APP_VERSION} ($STAMP)"
echo "Build architecture: $ARCH"
