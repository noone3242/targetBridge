#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
DERIVED_DATA_DIR="${ROOT}/.build/DerivedData"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${DERIVED_DATA_DIR}/Build/Products/${CONFIGURATION}"
SOURCE_APP="${BUILD_DIR}/TargetBridge.app"
DEST_DIR="${REPO_ROOT}/build"
DEST_APP="${DEST_DIR}/TargetBridge.app"
SIGNING_STATUS_FILE="${DEST_DIR}/TargetBridge.app.signing.txt"

cd "$ROOT"

xcodegen generate

xcodebuild \
  -scheme TBDisplaySender \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
echo "Cleaning extended attributes..."
xattr -cr "$DEST_APP" || true
echo "Signing sender application ad-hoc..."
codesign --force --deep --sign - "$DEST_APP"
codesign --verify --deep --strict "$DEST_APP"
touch "$DEST_APP"

echo "Resetting Screen Recording authorization for the new ad-hoc build..."
tccutil reset ScreenCapture com.targetbridge.sender

SIGNATURE_DETAILS="$(codesign -dv --verbose=2 "$DEST_APP" 2>&1)"
{
  echo "app=$DEST_APP"
  echo "mode=adhoc"
  echo "identity=-"
  echo "$SIGNATURE_DETAILS" | grep -E '^(Identifier|Signature|TeamIdentifier)=' || true
  cat <<'EOF'
screen_recording_warning=This ad-hoc build may require Screen Recording permission again.
reset_command=tccutil reset ScreenCapture com.targetbridge.sender
tcc_reset=completed_by_build_script
EOF
} > "$SIGNING_STATUS_FILE"

echo "TargetBridge sender built: $DEST_APP"
echo "Local DerivedData: $DERIVED_DATA_DIR"
echo "Signing status: $SIGNING_STATUS_FILE"
cat >&2 <<'EOF'

TargetBridge was signed ad-hoc. The build script already reset the old Screen
Recording authorization. After opening the new build:

  1. Click Connect.
  2. Grant Screen Recording in the macOS prompt.
  3. If macOS requests an app restart, quit and reopen TargetBridge once.

These steps are also saved in build/TargetBridge.app.signing.txt.
EOF
