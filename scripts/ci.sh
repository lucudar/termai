#!/usr/bin/env bash
# Everything the Build workflow does. The workflow file only calls this script, so CI can change
# without editing .github/workflows (the GitHub connection used for this repo cannot write there).
# usage: bash scripts/ci.sh core-linux | ipa
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs out shots
BUNDLE_ID=io.github.hgfh34bnvcn.termai
# Read from the built app by stamp_build.
APP_VERSION=?
APP_BUILD=?
IPA_NAME=

on_main() { [ "${GITHUB_REF:-}" = refs/heads/main ]; }

short_sha() { printf %s "${GITHUB_SHA:-$(git rev-parse HEAD 2> /dev/null)}" | cut -c1-7; }

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2> /dev/null; }

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

# Each CI build gets its own build number (the run number) and its commit. Settings shows the build and a
# new chat without a gateway shows both, so an installed app can be matched with its release.
stamp_build() {
    local plist=$1/Info.plist
    if [ -n "${GITHUB_RUN_NUMBER:-}" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GITHUB_RUN_NUMBER" "$plist" || fail "Stamping the build number"
    fi
    /usr/libexec/PlistBuddy -c "Delete :TermAICommit" "$plist" > /dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Add :TermAICommit string $(short_sha)" "$plist" || fail "Stamping the commit"
    APP_VERSION=$(plist_get "$plist" CFBundleShortVersionString)
    APP_BUILD=$(plist_get "$plist" CFBundleVersion)
    IPA_NAME="TermAI-$APP_VERSION-$APP_BUILD.ipa"
}

# What is inside the IPA, published with the release: the version, the toolchain, and how often strings
# that tell this UI from older builds occur in the app binary (0.3 had a disabled "Manage connectors (soon)").
# The whole file is searched, so the names of imported SwiftUI symbols (glassEffect, ...) count too; Swift
# string literals of 15 bytes or less are stored inside instructions and cannot be found this way.
build_info() {
    local app=$1 plist=$1/Info.plist bins
    bins=$(find "$app" -maxdepth 1 -type f \( -name TermAI -o -name '*.dylib' \))
    {
        echo "TermAI $APP_VERSION ($APP_BUILD) · $(plist_get "$plist" TermAICommit)"
        echo "commit ${GITHUB_SHA:-local}, run ${GITHUB_RUN_NUMBER:-local}"
        echo "$(xcodebuild -version | paste -sd ' ' -), SDK $(plist_get "$plist" DTSDKName), minimum iOS $(plist_get "$plist" MinimumOSVersion)"
        echo "binary $(du -k $bins | awk '{ kb += $1 } END { print kb }') KB"
        echo
        echo "Times each string occurs in the app binary:"
        python3 - $bins <<'PY'
import sys
data = b"".join(open(path, "rb").read() for path in sys.argv[1:])
for text in ["Manage connectors (soon)", "Manage connectors", "Ask the agent about the output",
             "https://mcp.deepwiki.com/mcp", "notifications/initialized", "UIDocumentPickerViewController",
             "GlassEffectContainer", "glassEffect", "tabBarMinimizeBehavior", "Keep a short plan for work",
             "Thought it through", "Not text, so it was saved for the agent to open"]:
    print("  %-50s %d" % ('"%s"' % text, data.count(text.encode())))
PY
    } > out/build-info.txt
    cat out/build-info.txt
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
    rm -rf out/Payload && mkdir -p out/Payload
    cp -R build/device/Build/Products/Release-iphoneos/TermAI.app out/Payload/ || fail "Packaging the IPA"
    stamp_build out/Payload/TermAI.app
    build_info out/Payload/TermAI.app
    (cd out && zip -qry TermAI-unsigned.ipa Payload && rm -rf Payload) || fail "Packaging the IPA"
    cp out/TermAI-unsigned.ipa "out/$IPA_NAME" || fail "Packaging the IPA"
    ls -lh out
}

# A public download that does not expire, unlike workflow artifacts. The versioned IPA gets a new name
# every build, so a phone's Downloads folder cannot mix it up with an older one.
publish_release() {
    local short
    short=$(short_sha)
    {
        printf 'TermAI %s (%s), unsigned IPA built from %s (run %s).\n\n%s\n\n' \
            "$APP_VERSION" "$APP_BUILD" "$short" "${GITHUB_RUN_NUMBER:-?}" "${MESSAGE:-}"
        printf 'The installed app shows `TermAI %s (%s)` at the bottom of Settings (and the commit, %s, on a new chat until a gateway is added). ' \
            "$APP_VERSION" "$APP_BUILD" "$short"
        printf '`%s` and `TermAI-unsigned.ipa` are the same file. Sign and install it with AltStore, Sideloadly or TrollStore.\n\n' \
            "$IPA_NAME"
        printf '```\n'
        cat out/build-info.txt
        printf '```\n'
    } > notes.md
    gh release delete latest --yes --cleanup-tag --repo "$GITHUB_REPOSITORY" 2> /dev/null || true
    sleep 3
    gh release create latest out/TermAI-unsigned.ipa "out/$IPA_NAME" out/build-info.txt \
        --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
        --title "TermAI $APP_VERSION ($APP_BUILD) · $short" --notes-file notes.md --prerelease \
        || fail "Publishing the latest release"
}

# The app's MCP client against a real server (DeepWiki, no sign-in): lists the tools and calls one.
# Published as mcp-live.txt; a failure here does not fail the build.
mcp_live_check() {
    local status
    TERMAI_MCP_URL=https://mcp.deepwiki.com/mcp TERMAI_MCP_CALL=read_wiki_structure \
        TERMAI_MCP_ARGS='{"repoName":"modelcontextprotocol/swift-sdk"}' \
        swift test --package-path TermKit --filter 'MCPTests/testLiveServer' > logs/mcp-live.log 2>&1
    status=$?
    {
        if [ "$status" -eq 0 ]; then
            echo "Live MCP check, DeepWiki (https://mcp.deepwiki.com/mcp): passed"
        else
            echo "Live MCP check, DeepWiki (https://mcp.deepwiki.com/mcp): failed (exit $status)"
        fi
        echo
        if grep -q "Test Suite" logs/mcp-live.log; then
            sed -n '/Test Suite/,$p' logs/mcp-live.log | head -n 60
        else
            tail -n 40 logs/mcp-live.log
        fi
    } > out/mcp-live.txt
    cat out/mcp-live.txt
    if on_main; then
        gh release upload latest out/mcp-live.txt --clobber --repo "$GITHUB_REPOSITORY" || echo "could not add the MCP check"
        # Also in the release notes, which the GitHub API returns as text.
        { cat notes.md; printf '\n```\n'; cat out/mcp-live.txt; printf '```\n'; } > notes-mcp.md
        gh release edit latest --notes-file notes-mcp.md --repo "$GITHUB_REPOSITORY" || echo "could not add the MCP check to the notes"
    fi
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
    shoot "$udid" activity -demoExpanded
    shoot "$udid" chats -demoChats
    shoot "$udid" approval -demoApproval
    shoot "$udid" settings -demoSettings
    shoot "$udid" terminal -demoTerminal
    shoot "$udid" connectors -demoConnectors
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
    mcp_live_check
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
