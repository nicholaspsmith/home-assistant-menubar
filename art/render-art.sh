#!/usr/bin/env bash
# Draw the menu-bar glyph's states strip from the real CharacterIcon, compiled
# straight from the sibling StatusItemKit checkout the way the site's glyph
# renderer does — so the README shows the glyph the app draws, not a copy of it.
#
# The other two pieces of artwork are generated, not drawn:
#   app icon   art/gen_app_icon.py                     (Gemini, then masked here)
#   mascot     ../widgets.nicksmith.software/art/gen_icons.py homestead
# This script copies the mascot across if the site repo has one.
set -euo pipefail
cd "$(dirname "$0")/.."
work="art/build"
mkdir -p "$work" docs Resources/bundle
cp ../StatusItemKit/Sources/StatusItemKit/CharacterIcon.swift "$work/"
cp art/render-art.swift "$work/main.swift"
(cd "$work" && swiftc -O CharacterIcon.swift main.swift -o render 2>&1 | grep -v warning || true)
"$work/render" "$PWD"

mascot="../widgets.nicksmith.software/site/img/mascots/homestead.png"
if [ -f "$mascot" ]; then
    cp "$mascot" docs/mascot.png
    echo "copied docs/mascot.png from the Menubarn mascot pipeline"
fi
