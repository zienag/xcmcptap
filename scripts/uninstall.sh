#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/_config.sh"

pkill -x "Xcode MCP Tap" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/${SERVICE_NAME}" 2>/dev/null || true
rm -f "$PLIST_PATH"
rm -f "$CLIENT_LINK"
rm -rf "$APP_PATH"
echo "Uninstalled."
