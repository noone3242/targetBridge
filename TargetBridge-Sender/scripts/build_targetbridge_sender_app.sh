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
SIGNING_REQUIREMENT='=designated => identifier "com.targetbridge.sender"'

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
echo "Signing sender application with a stable local requirement..."
codesign \
  --force \
  --deep \
  --sign - \
  --requirements "$SIGNING_REQUIREMENT" \
  "$DEST_APP"
codesign --verify --deep --strict "$DEST_APP"
touch "$DEST_APP"

SIGNATURE_DETAILS="$(codesign -dv --verbose=2 "$DEST_APP" 2>&1)"
DESIGNATED_REQUIREMENT="$(codesign -d --requirements - "$DEST_APP" 2>&1 |
  tail -n 1)"
{
  echo "app=$DEST_APP"
  echo "mode=adhoc-stable-requirement"
  echo "identity=-"
  echo "designated_requirement=$DESIGNATED_REQUIREMENT"
  echo "$SIGNATURE_DETAILS" | grep -E '^(Identifier|Signature|TeamIdentifier)=' || true
  cat <<'EOF'
screen_recording_note=Grant Screen Recording once after switching to this stable requirement. Later rebuilds keep the same designated requirement.
reset_command=tccutil reset ScreenCapture com.targetbridge.sender
tcc_reset=not_performed_by_build_script
EOF
} > "$SIGNING_STATUS_FILE"

echo "TargetBridge sender built: $DEST_APP"
echo "Local DerivedData: $DERIVED_DATA_DIR"
echo "Signing status: $SIGNING_STATUS_FILE"
cat >&2 <<'EOF'

TargetBridge was signed ad-hoc with a stable designated requirement. When
switching from the previous CDHash-bound build, grant Screen Recording once.
Later rebuilds with this script retain the same requirement and do not reset
TCC automatically.

These details are also saved in build/TargetBridge.app.signing.txt.
EOF
