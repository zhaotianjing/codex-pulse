#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Codex Pulse"
EXECUTABLE_NAME="CodexUsageFloat"
OUTPUT_DIR="$ROOT/outputs"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
PLIST_PATH="$ROOT/Resources/Info.plist"
EXPECTED_BUNDLE_IDENTIFIER="io.github.zhaotianjing.codex-pulse"
MACOS_ARCHIVE="$OUTPUT_DIR/CodexPulse-macOS.zip"
SOURCE_ARCHIVE="$OUTPUT_DIR/CodexPulse-source.zip"
README_COPY="$OUTPUT_DIR/CodexPulse-README.md"
BUILD_INFO="$OUTPUT_DIR/CodexPulse-build-info.txt"
CHECKSUMS="$OUTPUT_DIR/SHA256SUMS"
SOURCE_STAGE="$ROOT/work/source-archive"

BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST_PATH")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_PATH")"

if [[ "$BUNDLE_IDENTIFIER" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
    print -u2 "Build failed: unexpected bundle identifier: $BUNDLE_IDENTIFIER"
    exit 1
fi

SOURCE_COMMIT="unknown"
SOURCE_STATE="unavailable"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
    SOURCE_STATE="clean"
    if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
        SOURCE_STATE="dirty"
    fi
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" show -s --format=%ct HEAD)}"
else
    # ZIP timestamps cannot represent dates before 1980. Use that stable
    # minimum when the source tree has no Git history and no explicit epoch.
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-315532800}"
fi

case "$SOURCE_DATE_EPOCH" in
    (''|*[!0-9]*)
        print -u2 "Build failed: SOURCE_DATE_EPOCH must be an integer"
        exit 1
        ;;
esac

export HOME="$ROOT/work/home"
export TMPDIR="$ROOT/work/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/work/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/work/swiftpm-module-cache"

mkdir -p \
    "$HOME" \
    "$TMPDIR" \
    "$CLANG_MODULE_CACHE_PATH" \
    "$SWIFTPM_MODULECACHE_OVERRIDE" \
    "$OUTPUT_DIR" \
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

cp "$PLIST_PATH" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

xattr -cr "$APP_DIR"
codesign --force --sign - --options runtime --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

SIGNING_DETAILS="$(codesign -d --verbose=4 "$APP_DIR" 2>&1)"
if ! print -r -- "$SIGNING_DETAILS" | grep -q 'flags=.*runtime'; then
    print -u2 "Build failed: Hardened Runtime is not enabled"
    exit 1
fi

rm -f "$MACOS_ARCHIVE" "$SOURCE_ARCHIVE" "$README_COPY" "$BUILD_INFO" "$CHECKSUMS"
ditto -c -k \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    --keepParent \
    "$APP_DIR" \
    "$MACOS_ARCHIVE"

cp "$ROOT/README.md" "$README_COPY"

rm -rf "$SOURCE_STAGE"
mkdir -p "$SOURCE_STAGE"
cp "$ROOT/Package.swift" "$SOURCE_STAGE/Package.swift"
cp "$ROOT/README.md" "$SOURCE_STAGE/README.md"
cp "$ROOT/PRIVACY.md" "$SOURCE_STAGE/PRIVACY.md"
cp "$ROOT/LICENSE" "$SOURCE_STAGE/LICENSE"
cp "$ROOT/.gitignore" "$SOURCE_STAGE/.gitignore"
cp "$ROOT/build-app.sh" "$SOURCE_STAGE/build-app.sh"
cp -R "$ROOT/Sources" "$SOURCE_STAGE/Sources"
cp -R "$ROOT/Resources" "$SOURCE_STAGE/Resources"
if [[ -d "$ROOT/.github" ]]; then
    cp -R "$ROOT/.github" "$SOURCE_STAGE/.github"
fi

ARCHIVE_TIMESTAMP="$(TZ=UTC date -r "$SOURCE_DATE_EPOCH" '+%Y%m%d%H%M.%S')"
while IFS= read -r -d '' item; do
    TZ=UTC touch -h -t "$ARCHIVE_TIMESTAMP" "$item"
done < <(find "$SOURCE_STAGE" -print0)

(
    cd "$SOURCE_STAGE"
    find . -type f -print \
        | LC_ALL=C sort \
        | sed 's#^\./##' \
        | TZ=UTC zip -X -q "$SOURCE_ARCHIVE" -@
)

EXECUTABLE_ARCHITECTURES="$(lipo -archs "$APP_EXECUTABLE")"
SWIFT_TOOLCHAIN="$(swift --version 2>&1 | sed -n '1p')"
{
    print "Product: $APP_NAME"
    print "Version: $BUNDLE_VERSION"
    print "Build: $BUNDLE_BUILD"
    print "Bundle-Identifier: $BUNDLE_IDENTIFIER"
    print "Source-Commit: $SOURCE_COMMIT"
    print "Source-State: $SOURCE_STATE"
    print "Source-Date-Epoch: $SOURCE_DATE_EPOCH"
    print "Executable-Architectures: $EXECUTABLE_ARCHITECTURES"
    print "Code-Signing: ad-hoc (no publisher identity)"
    print "Hardened-Runtime: enabled"
    print "Apple-Notarization: not performed"
    print "Swift-Toolchain: $SWIFT_TOOLCHAIN"
} > "$BUILD_INFO"

(
    cd "$OUTPUT_DIR"
    LC_ALL=C shasum -a 256 \
        "${MACOS_ARCHIVE:t}" \
        "${SOURCE_ARCHIVE:t}" \
        "${README_COPY:t}" \
        "${BUILD_INFO:t}"
) > "$CHECKSUMS"

print "Built: $APP_DIR"
print "Archive: $MACOS_ARCHIVE"
print "Source: $SOURCE_ARCHIVE"
print "Build info: $BUILD_INFO"
print "Checksums: $CHECKSUMS"
