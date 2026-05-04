#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/_config.sh"

pkill -x "$PRODUCT_NAME" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/${SERVICE_NAME}" 2>/dev/null || true

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_PATH"
cp -R "$APP_BUNDLE" "$APP_PATH"
echo "Installed $APP_NAME to $INSTALL_DIR"

# Register the LaunchAgent immediately — same flow brew's postflight uses.
"$APP_PATH/Contents/MacOS/$SYMLINK_NAME" install

open "$APP_PATH"

cat <<EOF

Service registered. Point your MCP client (Claude Code, Codex, Cursor,
VS Code, ...) at:

  $APP_PATH/Contents/MacOS/$SYMLINK_NAME

Or click "Install to /usr/local/bin" in Settings to expose a bare
\`$SYMLINK_NAME\` command on PATH (one-time admin prompt). The Integrations
tab has ready-to-copy snippets for every supported client.
EOF
