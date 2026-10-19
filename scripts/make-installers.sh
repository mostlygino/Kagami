#!/bin/zsh
# Builds the two ways people install Kagami by hand, from an already built app:
#   Kagami-<version>.dmg  a disk image with a drawn background: drag Kagami into Applications
#   Kagami-<version>.pkg  an Installer package: the app, plus an optional kagami command in /usr/local/bin
# The updater uses the zip that scripts/release.sh makes; these are for first installs.
#
#   scripts/make-installers.sh 0.1.0 [build/Kagami.app] [build/release]
# Needs Xcode's tools (pkgbuild, productbuild, tiffutil) and fetches dmgbuild into build/.installer-venv once.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/make-installers.sh <version> [app] [outdir]}
APP=${2:-build/Kagami.app}
OUT=${3:-build/release}
[[ -d $APP ]] || { echo "No app at $APP. Run ./make-app.sh first."; exit 1; }
mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Art: 1x and 2x, joined into TIFFs so Finder and Installer pick the sharp one on Retina screens.
swiftc -O scripts/make-installer-art.swift -o "$WORK/make-art" 2>/dev/null
"$WORK/make-art" "$WORK/art" "$VERSION" >/dev/null
for name in dmg-background installer-light installer-dark; do
  tiffutil -cathidpicheck "$WORK/art/$name.png" "$WORK/art/$name@2x.png" -out "$WORK/art/$name.tiff" 2>/dev/null
done

# DMG, laid out by dmgbuild (it writes Finder's .DS_Store itself, no Finder window opens).
VENV=build/.installer-venv
[[ -x $VENV/bin/dmgbuild ]] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q dmgbuild; }
DMG="$OUT/Kagami-$VERSION.dmg"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/installer/dmg-settings.py \
  -D app="$APP" -D background="$WORK/art/dmg-background.tiff" -D volume_icon=Resources/AppIcon.icns \
  "Kagami $VERSION" "$DMG" > /dev/null 2> >(grep -v 'is deprecated' >&2)

# PKG: the app (fixed to /Applications, never relocated onto a copy elsewhere), and a payload-free
# component whose postinstall links the command line tool.
mkdir -p "$WORK/root" "$WORK/scripts" "$WORK/resources"
ditto "$APP" "$WORK/root/Kagami.app"
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
plutil -replace 0.BundleIsVersionChecked -bool NO "$WORK/component.plist"
pkgbuild --quiet --root "$WORK/root" --component-plist "$WORK/component.plist" --install-location /Applications \
  --identifier dev.mostlygino.kagami --version "$VERSION" "$WORK/Kagami-app.pkg" 2> >(grep -v '^write: Permission denied$' >&2)
cp scripts/installer/postinstall-cli "$WORK/scripts/postinstall"
pkgbuild --quiet --nopayload --scripts "$WORK/scripts" --identifier dev.mostlygino.kagami.cli --version "$VERSION" "$WORK/Kagami-cli.pkg"

# Installer shows each page on its own, so the stylesheet goes inline.
for page in welcome conclusion license; do
  python3 -c 'import sys; css=open(sys.argv[1]).read(); html=open(sys.argv[2]).read()
print(html.replace("<link rel=\"stylesheet\" href=\"style.css\">", "<style>"+css+"</style>").replace("__VERSION__", sys.argv[3]), end="")' \
    scripts/installer/style.css "scripts/installer/$page.html" "$VERSION" > "$WORK/resources/$page.html"
done
cp "$WORK/art/installer-light.tiff" "$WORK/art/installer-dark.tiff" "$WORK/resources/"
sed "s/__VERSION__/$VERSION/g" scripts/installer/distribution.xml > "$WORK/distribution.xml"
PKG="$OUT/Kagami-$VERSION.pkg"
productbuild --quiet --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" "$PKG"

echo "$DMG"
echo "$PKG"
