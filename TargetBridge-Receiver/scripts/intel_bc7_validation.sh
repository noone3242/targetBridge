#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build_tbreceiver_c_app.sh"
APP="$REPO_ROOT/build/TargetBridge Receiver.app"
BIN="$APP/Contents/MacOS/TargetBridgeReceiver"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="${TB_INTEL_RESULTS_DIR:-$REPO_ROOT/build/intel-validation/$STAMP}"
LAUNCH=0
ALLOW_NON_INTEL=0

sanitize_paths() {
    sed -e "s|$REPO_ROOT|<repo>|g" -e "s|$HOME|~|g"
}

usage() {
    cat <<'EOF'
Usage: intel_bc7_validation.sh [--launch] [--allow-non-intel]

Builds the Receiver on the current Mac, verifies its architecture, records
hardware/network facts, and probes Metal BC7 support. Use --launch to keep a
windowed Receiver running and save its stderr/stdout log.

--launch           Start the packaged Receiver after preflight.
--allow-non-intel  Permit a development smoke run on Apple Silicon.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH=1 ;;
        --allow-non-intel) ALLOW_NON_INTEL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) print -u2 "Unknown argument: $arg"; usage >&2; exit 64 ;;
    esac
done

ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" && "$ALLOW_NON_INTEL" -ne 1 ]]; then
    print -u2 "This validation must run on the Intel Mac itself (found $ARCH)."
    print -u2 "Use --allow-non-intel only to smoke-test the script."
    exit 2
fi

missing=()
for command in brew pkgconf make file system_profiler; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
done
if (( ${#missing[@]} > 0 )); then
    print -u2 "Missing commands: ${missing[*]}"
    print -u2 "Install Homebrew, then run: brew install ffmpeg sdl2 pkgconf dylibbundler"
    exit 3
fi

for package in ffmpeg sdl2 pkgconf dylibbundler; do
    if ! brew list --versions "$package" >/dev/null 2>&1; then
        missing+=("$package")
    fi
done
if (( ${#missing[@]} > 0 )); then
    print -u2 "Missing Homebrew packages: ${missing[*]}"
    print -u2 "Run: brew install ffmpeg sdl2 pkgconf dylibbundler"
    exit 3
fi

mkdir -p "$RESULT_DIR"
{
    print "timestamp=$STAMP"
    print "architecture=$ARCH"
    print "macos=$(sw_vers -productVersion)"
    print "build_version=$(sw_vers -buildVersion)"
    print "hardware_model=$(sysctl -n hw.model)"
    print "cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || print unknown)"
} > "$RESULT_DIR/host.txt"

system_profiler SPDisplaysDataType \
    | sed -E '/Serial Number:/d' \
    > "$RESULT_DIR/display-gpu.txt"
ifconfig | awk '
    /^[[:alnum:]][[:alnum:]]*:/ {
        interface = $1
        sub(/:$/, "", interface)
    }
    /^[[:space:]]+status:/ {
        print interface, $0
    }
    /^[[:space:]]+inet / {
        print interface, "inet", $2
    }
' > "$RESULT_DIR/network.txt"

print "Building Receiver on $ARCH..."
"$BUILD_SCRIPT" 2>&1 | sanitize_paths | tee "$RESULT_DIR/build.log"

file "$BIN" | sanitize_paths | tee "$RESULT_DIR/binary.txt"
if [[ "$ARCH" == "x86_64" ]] && ! file "$BIN" | grep -q "x86_64"; then
    print -u2 "Built Receiver is not x86_64."
    exit 4
fi

find "$APP/Contents/Frameworks" -type f -exec file {} \; \
    | sanitize_paths \
    > "$RESULT_DIR/framework-architectures.txt"
if [[ "$ARCH" == "x86_64" ]] &&
   grep 'Mach-O' "$RESULT_DIR/framework-architectures.txt" | grep -vq 'x86_64'; then
    print -u2 "At least one bundled framework does not contain x86_64 code."
    print -u2 "See: $RESULT_DIR/framework-architectures.txt"
    exit 4
fi

codesign --verify --deep --strict --verbose=2 "$APP" \
    2>&1 | sanitize_paths > "$RESULT_DIR/codesign.txt"
otool -L "$BIN" | sanitize_paths > "$RESULT_DIR/dylibs.txt"

"$BIN" --capabilities | tee "$RESULT_DIR/capabilities.json"
if ! grep -q '"supportsBC7Mode6":true' "$RESULT_DIR/capabilities.json"; then
    print -u2 "Receiver GPU does not report Metal BC7 texture support."
    print -u2 "BC7 transport is blocked on this Intel Mac; evidence: $RESULT_DIR"
    exit 5
fi

if [[ "$ARCH" == "x86_64" ]]; then
    print "Intel BC7 preflight passed."
else
    print "BC7 preflight passed with non-Intel development override ($ARCH)."
fi
print "Evidence directory: $RESULT_DIR"
print "On the Sender, select this Receiver and run Diagnostics > Start BC7 Test."

if (( LAUNCH == 1 )); then
    print "Launching windowed Receiver in debug mode; press Ctrl-C to stop."
    "$BIN" --windowed --debug 2>&1 | tee "$RESULT_DIR/receiver.log"
fi
