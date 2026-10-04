#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-idevice-tools.sh [options]

Clone the pinned official jkcoxson/idevice source, build idevice-tools with
Cargo's lockfile on macOS, and copy the verified executable to an output
directory. No root access is required.

Options:
  --out-dir PATH    executable destination directory
                    (default: ~/xmrand-ios-work/bin)
  -h, --help
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

OUT_DIR="$HOME/xmrand-ios-work/bin"
UPSTREAM_URL="https://github.com/jkcoxson/idevice.git"
UPSTREAM_COMMIT="85b866f0b4c26514e807e35f15be87612617eec4"

while (($#)); do
    case "$1" in
        --out-dir) OUT_DIR=${2:-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$OUT_DIR" ]] || die "--out-dir cannot be empty"
[[ $(uname -s) == Darwin ]] || die "run this script on macOS"

if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
fi

for command in cargo git shasum; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/idevice-tools.XXXXXX")
SRC="$WORK/src"
STAGED_BINARY="$WORK/idevice-tools"

cleanup() {
    if [[ -n ${WORK:-} && -d "$WORK" && "$WORK" == *idevice-tools.* ]]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT INT TERM

git init -q "$SRC"
git -C "$SRC" remote add origin "$UPSTREAM_URL"
git -C "$SRC" fetch -q --depth 1 origin "$UPSTREAM_COMMIT"
git -C "$SRC" checkout -q --detach FETCH_HEAD
ACTUAL_COMMIT=$(git -C "$SRC" rev-parse HEAD)
[[ "$ACTUAL_COMMIT" == "$UPSTREAM_COMMIT" ]] || \
    die "upstream commit mismatch: expected $UPSTREAM_COMMIT, got $ACTUAL_COMMIT"

cargo build \
    --manifest-path "$SRC/Cargo.toml" \
    --locked \
    --release \
    --package idevice-tools \
    --bin idevice-tools

BUILT_BINARY="$SRC/target/release/idevice-tools"
[[ -x "$BUILT_BINARY" ]] || die "built idevice-tools executable is missing"
cp "$BUILT_BINARY" "$STAGED_BINARY"
chmod 0755 "$STAGED_BINARY"
"$STAGED_BINARY" --version >/dev/null

mkdir -p "$OUT_DIR"
OUTPUT="$OUT_DIR/idevice-tools"
mv -f "$STAGED_BINARY" "$OUTPUT"

[[ -x "$OUTPUT" ]] || die "output executable verification failed"
printf 'UPSTREAM_COMMIT=%s\n' "$ACTUAL_COMMIT"
printf 'OUTPUT=%s\n' "$OUTPUT"
printf 'SHA256=%s\n' "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
