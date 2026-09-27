#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECEIVER_DIR="$(cd "$SCRIPT_DIR/../TBReceiverC" && pwd)"

BUILD=1
RECEIVER_ARGS=(--debug)

usage() {
    cat <<'EOF'
Usage: run_tbreceiver_dev.sh [--no-build] [receiver options]

Builds the Receiver from the current source tree, then runs it directly.

Script options:
  --no-build      Reuse the existing tbreceiver binary.
  -h, --help      Show this help.

Receiver options:
  --windowed      Keep the Receiver in a development window.
  --capabilities  Print architecture, Metal GPU, and BC7 support, then exit.

Examples:
  ./scripts/run_tbreceiver_dev.sh
  ./scripts/run_tbreceiver_dev.sh --windowed
  ./scripts/run_tbreceiver_dev.sh --no-build --windowed
  ./scripts/run_tbreceiver_dev.sh --no-build --capabilities
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --no-build)
            BUILD=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            RECEIVER_ARGS+=("$1")
            ;;
    esac
    shift
done

cd "$RECEIVER_DIR"

if (( BUILD == 1 )); then
    BUILD_STAMP="dev-$(date +%Y%m%d%H%M%S)"
    BUILD_COMMIT="$(git -C "$SCRIPT_DIR/../.." rev-parse --short=12 HEAD 2>/dev/null || print unknown)"
    make clean
    make APP_VERSION="4.0.1" APP_BUILD="$BUILD_STAMP" APP_COMMIT="$BUILD_COMMIT"
fi

if [[ ! -x ./tbreceiver ]]; then
    print -u2 "Receiver binary not found: $RECEIVER_DIR/tbreceiver"
    print -u2 "Run this script without --no-build first."
    exit 1
fi

exec ./tbreceiver "${RECEIVER_ARGS[@]}"
