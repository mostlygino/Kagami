#!/bin/zsh
# Cuts a Kagami release on the private GitHub repo. Installed copies pick it up through
# Kagami > Check for Updates (and a daily check). Needs a clean tree on main, gh logged in and
# the release key (also pinned in Sources/KagamiApp/Updater.swift).
#
#   scripts/release.sh 1.1.0          bumps the version, builds, signs, commits, pushes, releases
#   scripts/release.sh 1.1.0 --beta   the same, published as a GitHub pre-release labelled Beta
#
# Uploads Kagami-<version>.dmg (drag to Applications) and .pkg (Installer, with the optional kagami
# command) for people, the .zip for the updater, a detached GPG signature for each, and SHA-256 sums.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [--beta], for example 1.1.0}
BETA=${2:-}
[[ -z $BETA || $BETA == --beta ]] || { echo "The second argument can only be --beta."; exit 1; }
KEY=4C49B6E8DC9F50C80A1A20B805BE68B6158B9E08
REPO=mostlygino/Kagami
OUT=build/release
ZIP="$OUT/Kagami-$VERSION.zip"
DMG="$OUT/Kagami-$VERSION.dmg"
PKG="$OUT/Kagami-$VERSION.pkg"

[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3."; exit 1; }
[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "Commit or stash your changes first."; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "Releases come from main."; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "v$VERSION already exists."; exit 1; fi
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main is not the same as origin/main. Pull or push first."; exit 1; }

# Tests first: a release never ships red.
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} swift test >/dev/null || { echo "Tests failed, nothing released."; exit 1; }
scripts/check-cli.sh >/dev/null || { echo "CLI checks failed, nothing released."; exit 1; }

# Until the release commit exists, any failure puts Info.plist back.
trap '[[ -n ${COMMITTED:-} ]] || git checkout -- Info.plist' EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
git diff --quiet Info.plist || git commit -qm "chore: release v$VERSION" Info.plist
COMMITTED=1

KAGAMI_CHANNEL=$([[ -n $BETA ]] && echo Beta || echo Release) KAGAMI_BUILD=$(date +%Y%m%d%H%M) ./make-app.sh >/dev/null
BUILT=build/Kagami.app
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$BUILT/Contents/Info.plist")
[[ $BUILT_VERSION == "$VERSION" ]] || { echo "Built version is $BUILT_VERSION, not $VERSION."; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --keepParent "$BUILT" "$ZIP"
gpg --local-user "$KEY" --detach-sign --output "$ZIP.sig" "$ZIP"
gpg --verify "$ZIP.sig" "$ZIP"
# The DMG and the package are for people installing by hand; the updater uses the zip.
scripts/make-installers.sh "$VERSION" "$BUILT" "$OUT" >/dev/null
for f in "$DMG" "$PKG"; do
  gpg --local-user "$KEY" --detach-sign --output "$f.sig" "$f"
  gpg --verify "$f.sig" "$f"
done
(cd "$OUT" && shasum -a 256 Kagami-$VERSION.dmg Kagami-$VERSION.pkg Kagami-$VERSION.zip > SHA256SUMS)
NOTES="$OUT/notes.md"
cat > "$NOTES" <<NOTES_END
## Install

- **Kagami-$VERSION.dmg**: open it and drag Kagami into Applications.
- **Kagami-$VERSION.pkg**: the Installer way. Installs Kagami in Applications and, if you keep the option on, links the \`kagami\` command into /usr/local/bin.

Kagami is not notarised by Apple yet, so macOS blocks the first open of the .pkg or of the dragged app. Then go to System Settings > Privacy & Security, click Open Anyway, and open it again. That is needed once.

Recording needs Wireshark (with its ChmodBPF helper). Flow files open without it. macOS 26 or later, Apple silicon.

Already installed? Kagami > Check for Updates picks this up; it checks the zip's signature before it replaces anything.

## Verify

Each file has a detached GPG signature (.sig) from release key \`$KEY\`. SHA-256:

\`\`\`
$(cat "$OUT/SHA256SUMS")
\`\`\`
NOTES_END

git tag -a "v$VERSION" -m "Kagami $VERSION${BETA:+ Beta}"
git push origin main "v$VERSION"
ASSETS=("$DMG" "$DMG.sig" "$PKG" "$PKG.sig" "$ZIP" "$ZIP.sig" "$OUT/SHA256SUMS")
if [[ -n $BETA ]]; then
  gh release create "v$VERSION" --repo "$REPO" --prerelease --title "Kagami $VERSION Beta" --notes-file "$NOTES" --generate-notes "${ASSETS[@]}"
else
  gh release create "v$VERSION" --repo "$REPO" --title "Kagami $VERSION" --notes-file "$NOTES" --generate-notes "${ASSETS[@]}"
fi
echo "Released Kagami $VERSION."
