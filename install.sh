#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Nicholas Smith

# Build Homestead.app and symlink it into ~/Applications (rebuilds propagate;
# SMAppService accepts a symlink there for Start-at-Login).
set -euo pipefail

# Menubarn release rule — every push is a release. Arm the pre-push hook in
# every Menubarn repo cloned beside this one (local git config, so a fresh
# clone has none until this runs). StatusItemKit README, "Releases".
RELEASE_KIT="$(cd "$(dirname "$0")/.." && pwd)/StatusItemKit/scripts/release/adopt.sh"
if [ -x "$RELEASE_KIT" ]; then
    "$RELEASE_KIT" --hooks-only || echo "Release hook: adopt.sh failed" >&2
else
    echo "Release hook: StatusItemKit not found beside this repo — clone it and re-run" >&2
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Homestead.app"

"$SRC_DIR/scripts/build-app.sh"

mkdir -p "$HOME/Applications"
ln -sfn "$SRC_DIR/build/$APP_NAME" "$HOME/Applications/$APP_NAME"
echo "Linked $HOME/Applications/$APP_NAME -> $SRC_DIR/build/$APP_NAME"

open "$HOME/Applications/$APP_NAME"

cat <<'EOF'

Homestead is now running in the menu bar.

First-run setup
  1. In Home Assistant: your profile ▸ Security ▸ Long-lived access tokens ▸
     "Create token". Copy it.
  2. Click the Homestead icon ▸ Connect to Home Assistant…
  3. Enter the server URL (e.g. http://homeassistant.local:8123), paste the
     token, press Test, then Save.
  4. Optional: menu ▸ Start at Login.

The token is stored in your login Keychain. (Developers rebuilding the app can
swap that for a 0600 file to stop the per-rebuild password prompt — see the
README's Development section.)
EOF
