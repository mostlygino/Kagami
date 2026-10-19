#!/bin/sh
# Builds build/Kagami.app (release, ad-hoc signed) with the kagami CLI inside.
# SwiftUI macros need the full Xcode toolchain, not only the Command Line Tools.
#   KAGAMI_CHANNEL=Release|Beta|Development (default Development) is stamped into Info.plist,
#   with the commit and build date, for the About window and the updater.
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product KagamiApp
swift build -c release --product kagami-cli
app=build/Kagami.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp .build/release/KagamiApp "$app/Contents/MacOS/Kagami"
cp .build/release/kagami-cli "$app/Contents/Helpers/kagami"
cp Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/release-key.asc Resources/mostlygino.png "$app/Contents/Resources/"
# The accent colour (verdigris) for AppKit controls: focus rings, segmented controls, toolbar tabs.
xcrun actool Resources/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist /dev/null >/dev/null
plist="$app/Contents/Info.plist"
commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] && commit="$commit+"
/usr/libexec/PlistBuddy -c "Set :KagamiCommit $commit" "$plist"
/usr/libexec/PlistBuddy -c "Set :KagamiBuildDate $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$plist"
/usr/libexec/PlistBuddy -c "Set :KagamiChannel ${KAGAMI_CHANNEL:-Development}" "$plist"
[ -n "${KAGAMI_BUILD:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $KAGAMI_BUILD" "$plist"
codesign --force --sign - "$app/Contents/Helpers/kagami"
codesign --force --sign - "$app"
echo "$app"
