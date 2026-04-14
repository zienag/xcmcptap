#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/_config.sh"

HELPER_LABEL="${SERVICE_NAME}.helper"
SYSTEM_LINK="/usr/local/bin/xcmcptap"

# User-level: app, main agent, client symlink.
pkill -x "Xcode MCP Tap" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/${SERVICE_NAME}" 2>/dev/null || true
rm -f "$PLIST_PATH"
rm -f "$CLIENT_LINK"

# Move app bundles to Trash via Finder (reversible, respects Launch Services).
trash_bundle() {
  local path="$1"
  [ -e "$path" ] || return 0
  osascript -e "tell application \"Finder\" to delete POSIX file \"$path\"" >/dev/null
}

trash_bundle "$HOME/Applications/$APP_NAME"
trash_bundle "/Applications/$APP_NAME"

# Privileged: helper daemon + /usr/local/bin symlink. Only prompt for sudo if
# there is actually something to remove.
need_sudo=false
[ -L "$SYSTEM_LINK" ] && need_sudo=true
launchctl print "system/${HELPER_LABEL}" >/dev/null 2>&1 && need_sudo=true

if $need_sudo; then
  echo "Removing privileged helper daemon and $SYSTEM_LINK (requires sudo)..."
  sudo launchctl bootout "system/${HELPER_LABEL}" 2>/dev/null || true
  sudo rm -f "$SYSTEM_LINK"
  # SMAppService drops the daemon plist under /Library/LaunchDaemons/ with an
  # opaque prefix — wildcard-match anything carrying our helper label.
  sudo find /Library/LaunchDaemons -maxdepth 1 -name "*${HELPER_LABEL}*" -delete 2>/dev/null || true
fi

echo "Uninstalled."
