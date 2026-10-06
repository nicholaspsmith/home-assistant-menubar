#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Nicholas Smith

# Draw the menu-bar glyph's states strip from the real CharacterIcon, compiled
# straight from the sibling StatusItemKit checkout the way the site's glyph
# renderer does — so the README shows the glyph the app draws, not a copy of it.
# The app icon and docs/mascot.png come from scripts/make-icon.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
work="art/build"
mkdir -p "$work" docs Resources/bundle
cp ../StatusItemKit/Sources/StatusItemKit/CharacterIcon.swift "$work/"
cp art/render-art.swift "$work/main.swift"
(cd "$work" && swiftc -O CharacterIcon.swift main.swift -o render 2>&1 | grep -v warning || true)
"$work/render" "$PWD"
