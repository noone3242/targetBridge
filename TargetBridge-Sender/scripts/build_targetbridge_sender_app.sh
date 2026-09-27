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
SIGNING_IDENTITY="${TARGETBRIDGE_SIGNING_IDENTITY:-}"
ALLOW_ADHOC="${ALLOW_ADHOC:-0}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/^[[:space:]]*[0-9]+\\)/ { print $2; exit }'
  )"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  SIGNING_MODE="stable"
else
  SIGNING_MODE="adhoc"
  SIGNING_IDENTITY="-"
  if [[ "$ALLOW_ADHOC" != "1" ]]; then
    cat >&2 <<'EOF'
TargetBridge Sender build stopped: no stable code-signing identity is available.

Screen Recording permission is tied to the app's code identity. A new ad-hoc
build gets a new CDHash, so macOS may ask for permission again after every
rebuild.

Permanent path:
  Install an Apple Development or Developer ID certificate, then rerun.

Explicit temporary path:
  ALLOW_ADHOC=1 ./scripts/build_targetbridge_sender_app.sh

The temporary path is intentionally opt-in so an ad-hoc rebuild cannot silently
invalidate the existing Screen Recording authorization.
EOF
    exit 2
  fi
fi

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
if [[ "$SIGNING_MODE" == "stable" ]]; then
  echo "Signing sender application with: $SIGNING_IDENTITY"
  codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$DEST_APP"
else
  echo "Signing sender application ad-hoc (explicit ALLOW_ADHOC=1)..."
  codesign --force --deep --sign - "$DEST_APP"
fi
codesign --verify --deep --strict "$DEST_APP"
touch "$DEST_APP"

SIGNATURE_DETAILS="$(codesign -dv --verbose=2 "$DEST_APP" 2>&1)"
{
  echo "app=$DEST_APP"
  echo "mode=$SIGNING_MODE"
  echo "identity=$SIGNING_IDENTITY"
  echo "$SIGNATURE_DETAILS" | grep -E '^(Identifier|Signature|TeamIdentifier)=' || true
  if [[ "$SIGNING_MODE" == "adhoc" ]]; then
    cat <<'EOF'
screen_recording_warning=This ad-hoc build may require Screen Recording permission again.
reset_command=tccutil reset ScreenCapture com.targetbridge.sender
EOF
  fi
} > "$SIGNING_STATUS_FILE"

echo "TargetBridge sender built: $DEST_APP"
echo "Local DerivedData: $DERIVED_DATA_DIR"
echo "Signing status: $SIGNING_STATUS_FILE"
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  cat >&2 <<'EOF'

WARNING: TargetBridge was signed ad-hoc because ALLOW_ADHOC=1 was explicitly
set. Its designated requirement changes with the binary CDHash. macOS may no
longer match the previous Screen Recording authorization.

If Connect requests permission again:
  1. Quit TargetBridge.
  2. Run: tccutil reset ScreenCapture com.targetbridge.sender
  3. Reopen TargetBridge and grant Screen Recording.

This warning is also saved in build/TargetBridge.app.signing.txt.
EOF
fi
