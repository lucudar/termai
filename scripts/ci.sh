#!/usr/bin/env bash
# Everything the Build workflow does. The workflow file only calls this script, so CI can change
# without editing .github/workflows (the GitHub connection used for this repo cannot write there).
# usage: bash scripts/ci.sh core-linux | ipa
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs out shots
BUNDLE_ID=io.github.hgfh34bnvcn.termai

on_main() { [ "${GITHUB_REF:-}" = refs/heads/main ]; }

# Opens an issue with the errors (when running in Actions) and stops.
fail() {
    local what=$1
    shift
    echo "::error::$what failed"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        sh scripts/report_failure.sh "$what" "$@" || echo "could not open an issue"
    fi
    exit 1
}

# The newest Xcode 26 or later on the image (the default is older): Liquid Glass needs the iOS 26 SDK.
select_xcode() {
    local newest
    newest=$(python3 -c '
import glob, re
apps = []
for path in glob.glob("/Applications/Xcode_*.app"):
    match = re.fullmatch(r"/Applications/Xcode_(\d+(?:\.\d+)*)\.app", path)
    if match and int(match.group(1).split(".")[0]) >= 26:
        apps.append(([int(p) for p in match.group(1).split(".")], path))
print(max(apps)[1] if apps else "")
')
    if [ -n "$newest" ]; then
        sudo xcode-select -s "$newest/Contents/Developer" || fail "Selecting $newest"
    else
        echo "::warning::No Xcode 26 on this image; building without Liquid Glass"
    fi
    xcodebuild -version
}

core_tests() {
    local log="logs/core-$1.log"
    swift --version
    if ! swift test --package-path TermKit 2>&1 | tee "$log"; then
        fail "Core tests ($1)" "$log"
    fi
}

build_ipa() {
    python3 scripts/make_icon.py App/Assets.xcassets/AppIcon.appiconset/icon-1024.png || fail "Drawing the app icon"
    command -v xcodegen > /dev/null || brew install xcodegen
    xcodegen generate > logs/xcodegen.log 2>&1 || fail "Generating the Xcode project" logs/xcodegen.log
    if ! xcodebuild build \
        -project TermAI.xcodeproj -scheme TermAI -configuration Release \
        -sdk iphoneos -destination 'generic/platform=iOS' \
        -derivedDataPath build/device \
        CODE_SIGNING_ALLOWED=NO > logs/xcodebuild-device.log 2>&1; then
        grep -E -A3 "error:" logs/xcodebuild-device.log | head -200
        tail -n 30 logs/xcodebuild-device.log
        fail "iOS build" logs/xcodebuild-device.log
    fi
    echo "warnings: $(grep -c "warning:" logs/xcodebuild-device.log)"
    mkdir -p out/Payload
    cp -R build/device/Build/Products/Release-iphoneos/TermAI.app out/Payload/ || fail "Packaging the IPA"
    (cd out && zip -qry TermAI-unsigned.ipa Payload && rm -rf Payload) || fail "Packaging the IPA"
    ls -lh out
}

# A public download that does not expire, unlike workflow artifacts.
publish_release() {
    local short
    short=$(printf %s "$GITHUB_SHA" | cut -c1-7)
    printf 'Unsigned IPA built from %s (run %s).\n\n%s\n\nSign and install it with AltStore, Sideloadly or TrollStore.\n' \
        "$short" "${GITHUB_RUN_NUMBER:-?}" "${MESSAGE:-}" > notes.md
    gh release delete latest --yes --cleanup-tag --repo "$GITHUB_REPOSITORY" 2> /dev/null || true
    sleep 3
    gh release create latest out/TermAI-unsigned.ipa --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
        --title "TermAI latest ($short)" --notes-file notes.md --prerelease \
        || fail "Publishing the latest release"
}

shoot() {
    local udid=$1 name=$2
    shift 2
    xcrun simctl launch "$udid" "$BUNDLE_ID" -demo "$@" > /dev/null
    sleep 15
    xcrun simctl io "$udid" screenshot "shots/$name.png" > /dev/null 2>&1
    xcrun simctl terminate "$udid" "$BUNDLE_ID"
    sleep 3
}

# Launches the app in demo mode on a simulator so the UI can be reviewed without a device.
screenshots() {
    local sdk udid theme
    sdk=$(xcrun --sdk iphonesimulator --show-sdk-version) || return 1
    # The newest iPhone simulator whose iOS is not newer than the SDK this Xcode builds with.
    udid=$(xcrun simctl list devices available -j | SDK="$sdk" python3 -c '
import json, os, sys
sdk = [int(p) for p in os.environ["SDK"].split(".") if p.isdigit()]
runtimes = {k: v for k, v in json.load(sys.stdin)["devices"].items() if "iOS" in k}
def version(key):
    return [int(p) for p in key.rsplit("iOS-", 1)[1].split("-") if p.isdigit()]
keys = sorted(runtimes, key=lambda k: (version(k) <= sdk, version(k)), reverse=True)
print(next(d["udid"] for k in keys for d in runtimes[k] if d["name"].startswith("iPhone")))
') || return 1
    echo "simulator $udid, SDK $sdk"
    xcodebuild build \
        -project TermAI.xcodeproj -scheme TermAI -configuration Debug \
        -sdk iphonesimulator -destination "id=$udid" \
        -derivedDataPath build/sim \
        CODE_SIGNING_ALLOWED=NO > logs/xcodebuild-sim.log 2>&1 \
        || { grep -E -A3 "error:" logs/xcodebuild-sim.log | head -100; return 1; }
    xcrun simctl boot "$udid" 2> /dev/null
    xcrun simctl bootstatus "$udid" -b > /dev/null || return 1
    xcrun simctl install "$udid" build/sim/Build/Products/Debug-iphonesimulator/TermAI.app || return 1
    # The first launch on a fresh simulator is slow; warm it up so no shot catches the launch screen.
    xcrun simctl launch "$udid" "$BUNDLE_ID" -demo > /dev/null
    sleep 45
    xcrun simctl terminate "$udid" "$BUNDLE_ID"
    sleep 3
    for theme in desktop dark crt-green crt-amber light; do shoot "$udid" "$theme" -theme "$theme"; done
    shoot "$udid" home -demoHome
    shoot "$udid" sidebar -demoSidebar
    shoot "$udid" approval -demoApproval
    shoot "$udid" settings -demoSettings
}

case "${1:-}" in
core-linux)
    core_tests linux
    ;;
ipa)
    select_xcode
    core_tests macos
    build_ipa
    if on_main; then publish_release; fi
    if screenshots; then
        if on_main && ls shots/*.png > /dev/null 2>&1; then
            gh release upload latest shots/*.png --clobber --repo "$GITHUB_REPOSITORY" || echo "could not add the screenshots"
        fi
    else
        echo "::warning::Simulator screenshots failed; the IPA is fine"
    fi
    ;;
*)
    echo "usage: bash scripts/ci.sh core-linux | ipa" >&2
    exit 2
    ;;
esac
exit 0
