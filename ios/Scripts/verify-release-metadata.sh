#!/bin/bash
# ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
# Usage: verify-release-metadata.sh [path/to/SpeakFreeKeyboard.app]
# Set REQUIRE_SIGNING=1 for the TestFlight/device gate; unsigned archives must fail that mode.
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
    "$IOS_DIR/Resources/Core/PrivacyInfo.xcprivacy" \
    "$IOS_DIR/Resources/Extension/PrivacyInfo.xcprivacy" \
    "$IOS_DIR/Resources/Widget/PrivacyInfo.xcprivacy"; do
    plutil -lint "$manifest" >/dev/null
done

extension_privacy="$(plutil -convert json -o - "$IOS_DIR/Resources/Extension/PrivacyInfo.xcprivacy")"
grep -q 'NSPrivacyAccessedAPICategoryFileTimestamp' <<<"$extension_privacy" || fail "extension file-timestamp category is missing"
grep -q 'C617.1' <<<"$extension_privacy" || fail "extension file-container reason is missing"
app_privacy="$(plutil -convert json -o - "$IOS_DIR/Resources/App/PrivacyInfo.xcprivacy")"
grep -q 'NSPrivacyAccessedAPICategoryFileTimestamp' <<<"$app_privacy" || fail "app file-timestamp category is missing"
grep -q 'C617.1' <<<"$app_privacy" || fail "app file-container reason is missing"
core_privacy="$(plutil -convert json -o - "$IOS_DIR/Resources/Core/PrivacyInfo.xcprivacy")"
grep -q 'NSPrivacyAccessedAPICategoryFileTimestamp' <<<"$core_privacy" || fail "core file-timestamp category is missing"
grep -q 'C617.1' <<<"$core_privacy" || fail "core file-container reason is missing"

for plist in \
    "$IOS_DIR/Config/SpeakFreeKeyboard-Info.plist" \
    "$IOS_DIR/Config/SpeakFreeKeyboardExtension-Info.plist" \
    "$IOS_DIR/Config/SpeakFreeDictationWidget-Info.plist" \
    "$IOS_DIR/Config/SpeakFreeKeyboardCore-Info.plist"; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == '$(MARKETING_VERSION)' ]] || fail "$plist does not use MARKETING_VERSION"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == '$(CURRENT_PROJECT_VERSION)' ]] || fail "$plist does not use CURRENT_PROJECT_VERSION"
done

expected_fluid_revision="e8bd3a205fb8ecef926f7747499d184cbb6d0cc6"
fluid_vendor="$IOS_DIR/Vendor/FluidAudioASRPackage"
grep -q 'path: Vendor/FluidAudioASRPackage' "$IOS_DIR/project.yml" || fail "project.yml does not use the audited local FluidAudio package"
grep -q "$expected_fluid_revision" "$fluid_vendor/UPSTREAM.ai.md" || fail "vendored FluidAudio provenance does not name the audited revision"
fluid_source_hash="$(cd "$fluid_vendor" && find Sources -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
[[ "$fluid_source_hash" == "ad951d9a2b7b1217eb26453e5a12c25d3853a2496f3e0111d09f6f9a6bdc75bd" ]] || fail "vendored FluidAudio source differs from the audited ASR package"
grep -q '40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355' "$fluid_vendor/Sources/FluidAudio/ModelRegistry.swift" || fail "EOU model repository is not revision-pinned"
grep -q 'ee09c569f73759e6d44c9bd16766f477b2b36d39' "$fluid_vendor/Sources/FluidAudio/ModelRegistry.swift" || fail "Parakeet v2 model repository is not revision-pinned"

[[ "$(tail -n +5 "$IOS_DIR/Resources/Legal/EXECUTORCH-LICENSE.ai.md" | shasum -a 256 | awk '{print $1}')" == "c58707ea5d5c0ee17af7e16f1377e4d31ad1533492ab0bf9b87ebd9f718f9e7b" ]] || fail "ExecuTorch license payload differs from v1.2.0"
[[ "$(tail -n +5 "$IOS_DIR/Resources/Legal/XNNPACK-LICENSE.ai.md" | shasum -a 256 | awk '{print $1}')" == "63f519e15726f4c4f830bd958f694c84fecb4e0a4cacc527d2696bb71ef95ada" ]] || fail "XNNPACK license payload differs from the ExecuTorch v1.2.0 submodule revision"
[[ "$(tail -n +5 "$IOS_DIR/Resources/Legal/CPUINFO-LICENSE.ai.md" | shasum -a 256 | awk '{print $1}')" == "8e7e60636c3aa0cb03571a1a841ce5697f9551ff92b3c426c2561613d15ade70" ]] || fail "cpuinfo license payload differs from XNNPACK's pinned revision"
[[ "$(tail -n +5 "$IOS_DIR/Resources/Legal/PTHREADPOOL-LICENSE.ai.md" | shasum -a 256 | awk '{print $1}')" == "955604be43dc2c71940b5285e59ba60bd5132953ada8ca2292042817349d9399" ]] || fail "pthreadpool license payload differs from XNNPACK's pinned revision"
[[ "$(tail -n +5 "$IOS_DIR/Resources/Legal/FXDIV-LICENSE.ai.md" | shasum -a 256 | awk '{print $1}')" == "7cac00006125b1486a27e4801ed66357236e984c540bd323945ab7b66b078ec3" ]] || fail "FXdiv license payload differs from XNNPACK's pinned revision"
[[ "$(tail -n +5 "$IOS_DIR/Resources/Legal/KLEIDIAI-LICENSE.ai.md" | shasum -a 256 | awk '{print $1}')" == "074e6e32c86a4c0ef8b3ed25b721ca23aca83df277cd88106ef7177c354615ff" ]] || fail "KleidiAI license payload differs from XNNPACK's pinned revision"

icon="ios/Sources/SpeakFreeKeyboardApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
if git -C "$REPO_DIR" check-ignore -q "$icon"; then
    fail "$icon is still ignored"
fi

if [[ $# -gt 0 ]]; then
    app_bundle="$1"
    extension_bundle="$app_bundle/PlugIns/SpeakFreeKeyboardExtension.appex"
    widget_bundle="$app_bundle/PlugIns/SpeakFreeDictationWidget.appex"
    for resource in \
        "$app_bundle/PrivacyInfo.xcprivacy" \
        "$app_bundle/Frameworks/SpeakFreeKeyboardCore.framework/PrivacyInfo.xcprivacy" \
        "$app_bundle/EXECUTORCH-LICENSE.ai.md" \
        "$app_bundle/XNNPACK-LICENSE.ai.md" \
        "$app_bundle/CPUINFO-LICENSE.ai.md" \
        "$app_bundle/PTHREADPOOL-LICENSE.ai.md" \
        "$app_bundle/FXDIV-LICENSE.ai.md" \
        "$app_bundle/KLEIDIAI-LICENSE.ai.md" \
        "$app_bundle/FLUIDAUDIO-LICENSE.ai.md" \
        "$app_bundle/PARAKEET-MODEL-ATTRIBUTION.ai.md" \
        "$app_bundle/FUTO-Model-Weights-License-1.0.md" \
        "$app_bundle/WORD-FREQUENCY-LICENSE.md" \
        "$extension_bundle/PrivacyInfo.xcprivacy" \
        "$extension_bundle/metadata.json" \
        "$extension_bundle/model_fp32.pte" \
        "$extension_bundle/wordfreq-en-25000-log.json"; do
        [[ -f "$resource" ]] || fail "archive resource missing: $resource"
    done

    [[ -d "$widget_bundle" ]] || fail "dictation Live Activity widget is missing"
    [[ -f "$widget_bundle/PrivacyInfo.xcprivacy" ]] || fail "widget privacy manifest is missing"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsLiveActivities' "$app_bundle/Info.plist")" == true ]] \
        || fail "app does not declare Live Activity support"
    /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$app_bundle/Info.plist" \
        | grep -q 'audio' || fail "app does not declare background audio"
    mic_purpose="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$app_bundle/Info.plist")"
    [[ -n "$mic_purpose" ]] || fail "microphone purpose string is missing"
    app_intents="$app_bundle/Metadata.appintents/extract.actionsdata"
    widget_intents="$widget_bundle/Metadata.appintents/extract.actionsdata"
    [[ -f "$app_intents" ]] || fail "app intent metadata is missing"
    [[ -f "$widget_intents" ]] || fail "widget intent metadata is missing"
    /usr/bin/python3 - "$app_intents" "$widget_intents" <<'PY' || fail "dictation intent metadata is invalid"
import json
import sys

app = json.load(open(sys.argv[1]))["actions"]
widget = json.load(open(sys.argv[2]))["actions"]
start = app.get("StartSpeakFreeDictationIntent")
assert start is not None, "start dictation intent is missing"
protocols = set(start.get("systemProtocols", []))
assert "com.apple.link.systemProtocol.AudioRecording" in protocols
assert "com.apple.link.systemProtocol.SessionStarting" in protocols
assert start.get("supportedModes") == 1
assert start.get("availabilityAnnotations", {}).get("LNPlatformNameIOS", {}).get("introducedVersion") == "18.0"
for actions in (app, widget):
    stop = actions.get("StopSpeakFreeDictationIntent")
    assert stop is not None, "Live Activity stop intent is missing"
    assert stop.get("visibilityMetadata", {}).get("isDiscoverable") is False
    assert stop.get("supportedModes") == 1
    assert stop.get("availabilityAnnotations", {}).get("LNPlatformNameIOS", {}).get("introducedVersion") == "17.0"
    assert any(parameter.get("name") == "sessionID" for parameter in stop.get("parameters", []))
PY

    expected_model_hash="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["file_hashes"]["model_fp32.pte"])' "$extension_bundle/metadata.json")"
    actual_model_hash="$(shasum -a 256 "$extension_bundle/model_fp32.pte" | awk '{print $1}')"
    [[ "$actual_model_hash" == "$expected_model_hash" ]] || fail "archived model hash differs from bundled metadata"
    [[ -s "$extension_bundle/wordfreq-en-25000-log.json" ]] || fail "archived vocabulary is empty"

    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
    extension_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension_bundle/Info.plist")"
    widget_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$widget_bundle/Info.plist")"
    [[ "$app_version" == "$extension_version" ]] || fail "app and extension marketing versions differ"
    [[ "$app_version" == "$widget_version" ]] || fail "app and widget marketing versions differ"

    if [[ "${REQUIRE_SIGNING:-0}" == "1" ]]; then
        core_bundle="$app_bundle/Frameworks/SpeakFreeKeyboardCore.framework"
        expected_team="${EXPECTED_TEAM_ID:-$(awk '/DEVELOPMENT_TEAM:/{print $2; exit}' "$IOS_DIR/project.yml")}"
        [[ -n "$expected_team" ]] || fail "expected Apple development team is unavailable"

        codesign --verify --deep --strict "$app_bundle" \
            || fail "app bundle is not validly signed"
        for signed_bundle in "$app_bundle" "$extension_bundle" "$widget_bundle" "$core_bundle"; do
            codesign --verify --strict "$signed_bundle" \
                || fail "bundle is not validly signed: $signed_bundle"
            actual_team="$(codesign -dv --verbose=4 "$signed_bundle" 2>&1 \
                | sed -n 's/^TeamIdentifier=//p' | head -1)"
            [[ "$actual_team" == "$expected_team" ]] \
                || fail "unexpected or missing signing team for $signed_bundle"
        done

        for provisioned_bundle in "$app_bundle" "$extension_bundle" "$widget_bundle"; do
            [[ -s "$provisioned_bundle/embedded.mobileprovision" ]] \
                || fail "embedded provisioning profile is missing: $provisioned_bundle"
            entitlements="$(codesign -d --entitlements :- "$provisioned_bundle" 2>/dev/null)"
            /usr/bin/python3 -c '
import plistlib, sys
payload = plistlib.loads(sys.stdin.buffer.read())
team = sys.argv[1]
assert payload.get("com.apple.developer.team-identifier") == team
assert payload.get("application-identifier", "").startswith(team + ".")
assert payload.get("com.apple.security.application-groups") == ["group.com.speakfree.keyboard"]
' "$expected_team" <<<"$entitlements" \
                || fail "signed entitlements are wrong for $provisioned_bundle"
        done
        echo "signed archive checks passed"
    fi
fi

echo "release metadata checks passed"
