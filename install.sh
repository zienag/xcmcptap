#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<EOF
Usage: $0 [--dmg|--exit]

  (no args)  Build, notarize, install to /Applications, launch.
  --dmg      Build, notarize, package as .build/XcodeMCPTap.dmg.
  --exit     Stop the service and quit the app (without uninstalling).

To uninstall, run scripts/uninstall.sh directly.
EOF
}

case "${1:-}" in
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
