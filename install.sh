#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<EOF
Usage: $0 [--dmg|--uninstall|--exit]

  (no args)    Build, notarize, install to ~/Applications, launch.
  --dmg        Build, notarize, package as .build/XcodeMCPTap.dmg.
  --uninstall  Stop service, remove app + LaunchAgent + symlink.
  --exit       Stop the service and quit the app (without uninstalling).

Env:
  NOTARIZE=false   Skip notarization (default: true).
EOF
}

case "${1:-}" in
  --uninstall) exec scripts/uninstall.sh ;;
  --exit)      exec scripts/exit-service.sh ;;
  --dmg)
    scripts/build.sh
    [ "${NOTARIZE:-true}" = "true" ] && scripts/notarize.sh
    exec scripts/make_dmg.py
    ;;
  "")
    scripts/build.sh
    [ "${NOTARIZE:-true}" = "true" ] && scripts/notarize.sh
    exec scripts/install-app.sh
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac
