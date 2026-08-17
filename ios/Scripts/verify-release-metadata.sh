#!/bin/bash
# ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/.." && pwd)"

fail() {
    echo "release metadata check failed: $*" >&2
    exit 1
}

for manifest in \
    "$IOS_DIR/Resources/App/PrivacyInfo.xcprivacy" \
    "$IOS_DIR/Resources/Extension/PrivacyInfo.xcprivacy"; do
    plutil -lint "$manifest" >/dev/null
done

extension_privacy="$(plutil -convert json -o - "$IOS_DIR/Resources/Extension/PrivacyInfo.xcprivacy")"
grep -q 'NSPrivacyAccessedAPICategoryFileTimestamp' <<<"$extension_privacy" || fail "extension file-timestamp category is missing"
grep -q 'C617.1' <<<"$extension_privacy" || fail "extension file-container reason is missing"

for plist in \
    "$IOS_DIR/Config/SpeakFreeKeyboard-Info.plist" \
    "$IOS_DIR/Config/SpeakFreeKeyboardExtension-Info.plist" \
    "$IOS_DIR/Config/SpeakFreeKeyboardCore-Info.plist"; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == '$(MARKETING_VERSION)' ]] || fail "$plist does not use MARKETING_VERSION"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == '$(CURRENT_PROJECT_VERSION)' ]] || fail "$plist does not use CURRENT_PROJECT_VERSION"
done

[[ "$(tail -n +5 "$IOS_DIR/Resources/Legal/EXECUTORCH-LICENSE.ai.md" | shasum -a 256 | awk '{print $1}')" == "c58707ea5d5c0ee17af7e16f1377e4d31ad1533492ab0bf9b87ebd9f718f9e7b" ]] || fail "ExecuTorch license payload differs from v1.2.0"
[[ "$(tail -n +5 "$IOS_DIR/Resources/Legal/XNNPACK-LICENSE.ai.md" | shasum -a 256 | awk '{print $1}')" == "63f519e15726f4c4f830bd958f694c84fecb4e0a4cacc527d2696bb71ef95ada" ]] || fail "XNNPACK license payload differs from the ExecuTorch v1.2.0 submodule revision"

icon="ios/Sources/SpeakFreeKeyboardApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
if git -C "$REPO_DIR" check-ignore -q "$icon"; then
    fail "$icon is still ignored"
fi

if [[ $# -gt 0 ]]; then
    app_bundle="$1"
    extension_bundle="$app_bundle/PlugIns/SpeakFreeKeyboardExtension.appex"
    for resource in \
        "$app_bundle/PrivacyInfo.xcprivacy" \
        "$app_bundle/EXECUTORCH-LICENSE.ai.md" \
        "$app_bundle/XNNPACK-LICENSE.ai.md" \
        "$app_bundle/FUTO-Model-Weights-License-1.0.md" \
        "$app_bundle/WORD-FREQUENCY-LICENSE.md" \
        "$extension_bundle/PrivacyInfo.xcprivacy" \
        "$extension_bundle/metadata.json" \
        "$extension_bundle/model_fp32.pte" \
        "$extension_bundle/wordfreq-en-25000-log.json"; do
        [[ -f "$resource" ]] || fail "archive resource missing: $resource"
    done

    expected_model_hash="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["file_hashes"]["model_fp32.pte"])' "$extension_bundle/metadata.json")"
    actual_model_hash="$(shasum -a 256 "$extension_bundle/model_fp32.pte" | awk '{print $1}')"
    [[ "$actual_model_hash" == "$expected_model_hash" ]] || fail "archived model hash differs from bundled metadata"
    [[ -s "$extension_bundle/wordfreq-en-25000-log.json" ]] || fail "archived vocabulary is empty"

    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
    extension_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension_bundle/Info.plist")"
    [[ "$app_version" == "$extension_version" ]] || fail "app and extension marketing versions differ"
fi

echo "release metadata checks passed"
