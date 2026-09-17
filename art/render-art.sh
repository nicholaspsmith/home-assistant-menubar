#!/usr/bin/env bash
# Draw Homestead's artwork from code: the app icon, the mascot, and the
# menu-bar strip. Compiles CharacterIcon.swift straight from the sibling
# StatusItemKit checkout, the way the site's glyph renderer does, so the strip
# shows the real glyph rather than a copy of it.
set -euo pipefail
cd "$(dirname "$0")/.."
work="art/build"
mkdir -p "$work" docs Resources/bundle
cp ../StatusItemKit/Sources/StatusItemKit/CharacterIcon.swift "$work/"
cp art/render-art.swift "$work/main.swift"
(cd "$work" && swiftc -O CharacterIcon.swift main.swift -o render 2>&1 | grep -v warning || true)
"$work/render" "$PWD"
iconutil -c icns art/Homestead.iconset -o Resources/bundle/AppIcon.icns
echo "wrote Resources/bundle/AppIcon.icns"
