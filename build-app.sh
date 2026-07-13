#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Codex Pulse"
EXECUTABLE_NAME="CodexUsageFloat"
OUTPUT_DIR="$ROOT/outputs"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

export HOME="$ROOT/work/home"
export TMPDIR="$ROOT/work/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/work/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/work/swiftpm-module-cache"

mkdir -p \
    "$HOME" \
    "$TMPDIR" \
    "$CLANG_MODULE_CACHE_PATH" \
    "$SWIFTPM_MODULECACHE_OVERRIDE" \
    "$ROOT/work/swiftpm-cache" \
    "$ROOT/work/swiftpm-config" \
    "$ROOT/work/swiftpm-security"

cd "$ROOT"
swift build \
    -c release \
    --disable-sandbox \
    --cache-path "$ROOT/work/swiftpm-cache" \
    --config-path "$ROOT/work/swiftpm-config" \
    --security-path "$ROOT/work/swiftpm-security"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/$EXECUTABLE_NAME" "$APP_EXECUTABLE"

codesign --remove-signature "$APP_EXECUTABLE" 2>/dev/null || true
strip -S -x "$APP_EXECUTABLE"

if LC_ALL=C grep -aqF "$ROOT" "$APP_EXECUTABLE" || LC_ALL=C grep -aq '/Users/' "$APP_EXECUTABLE"; then
    print -u2 "Privacy check failed: the executable contains an absolute build path"
    exit 1
fi

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

xattr -cr "$APP_DIR"
codesign --force --sign - --timestamp=none "$APP_DIR"

rm -f "$OUTPUT_DIR/CodexPulse-macOS.zip"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$OUTPUT_DIR/CodexPulse-macOS.zip"

cp "$ROOT/README.md" "$OUTPUT_DIR/CodexPulse-README.md"
rm -f "$OUTPUT_DIR/CodexPulse-source.zip"
zip -rq "$OUTPUT_DIR/CodexPulse-source.zip" \
    Package.swift \
    Sources \
    Resources \
    README.md \
    PRIVACY.md \
    LICENSE \
    .gitignore \
    build-app.sh

print "Built: $APP_DIR"
print "Archive: $OUTPUT_DIR/CodexPulse-macOS.zip"
print "Source: $OUTPUT_DIR/CodexPulse-source.zip"
