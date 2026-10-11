#!/bin/bash
# Run Script build phase for the app target in speakfree.xcodeproj. Does what
# scripts/bundle-app.sh and scripts/build.sh do for command-line builds: embeds the
# pinned whisper.cpp binaries and stamps the built Info.plist.
set -euo pipefail

VENDOR="$SRCROOT/scripts/vendor"
FRAMEWORKS="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
WHISPER_CLI="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/whisper-cli"
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"

(cd "$VENDOR/dylibs" && shasum -a 256 -c checksums.sha256 --strict --quiet)

mkdir -p "$FRAMEWORKS"
find "$FRAMEWORKS" -maxdepth 1 -name '*.dylib' -delete
for dylib in "$VENDOR"/dylibs/*.dylib; do
    cp "$dylib" "$FRAMEWORKS/"
done
# Soname links (libwhisper.1.dylib -> libwhisper.1.8.3.dylib), as committed in vendor/lib.
for link in "$VENDOR"/lib/*.dylib; do
    ln -sf "$(basename "$(readlink "$link")")" "$FRAMEWORKS/$(basename "$link")"
done
cp "$VENDOR/dylibs/whisper-cli" "$WHISPER_CLI"

# Xcode applies the package's debug-only rpath (the checkout's vendor/lib) to every
# configuration. Drop it outside Debug so a shipped app only looks inside its bundle.
if [ "$CONFIGURATION" != "Debug" ]; then
    install_name_tool -delete_rpath "$SRCROOT/scripts/vendor/lib" \
        "$TARGET_BUILD_DIR/$EXECUTABLE_PATH" 2>/dev/null || true
fi

# Nested code must carry the app's own signature: the hardened runtime refuses
# libraries signed by a different team.
SIGN_ARGS=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none)
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
    SIGN_ARGS+=(--options runtime)
fi
find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' -print0 \
    | xargs -0 -n1 codesign "${SIGN_ARGS[@]}"
codesign "${SIGN_ARGS[@]}" "$WHISPER_CLI"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PRODUCT_BUNDLE_IDENTIFIER" "$PLIST"
if [ "${SPEAKFREE_ENABLE_UPDATES:-NO}" != "YES" ]; then
    for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
    done
fi
BUILD_COMMIT=$(git -C "$SRCROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
/usr/libexec/PlistBuddy -c "Delete :SFBuildCommit" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SFBuildCommit string $BUILD_COMMIT" "$PLIST"
