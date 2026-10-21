#!/bin/sh
# Builds Kagami and installs it in /Applications, where the updater can replace it.
set -eu
cd "$(dirname "$0")/.."
./make-app.sh >/dev/null
pkill -x Kagami 2>/dev/null && sleep 1 || true
rm -rf /Applications/Kagami.app
ditto build/Kagami.app /Applications/Kagami.app
echo "Installed /Applications/Kagami.app"
