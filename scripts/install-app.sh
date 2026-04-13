#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/_config.sh"

pkill -x "Xcode MCP Tap" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/${SERVICE_NAME}" 2>/dev/null || true

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_PATH"
cp -R "$APP_BUNDLE" "$APP_PATH"
echo "Installed $APP_NAME to $INSTALL_DIR"

open "$APP_PATH"

cat <<EOF

Click "Install service" in the app's Settings tab to register the LaunchAgent,
then configure Claude Code with:

  claude mcp add --transport stdio xcode -- $CLIENT_LINK
EOF
