#!/usr/bin/env bash
# Build Homestead.app and symlink it into ~/Applications (rebuilds propagate;
# SMAppService accepts a symlink there for Start-at-Login).
set -euo pipefail

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

The token is stored in your login Keychain, never on disk in plain text.
EOF
