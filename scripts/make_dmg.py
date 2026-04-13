#!/usr/bin/env python3
"""
Build a signed DMG with custom Finder layout — no AppleScript, no mounted
read-write image. Writes the .DS_Store directly into the staging folder
using the `ds_store` library, then creates the compressed DMG in one shot.

Bootstraps a venv at .build/dmg-venv on first run.
"""
from __future__ import annotations

import os
import subprocess
import sys
import venv
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VENV = REPO / ".build" / "dmg-venv"
VENV_PY = VENV / "bin" / "python"
DEPS = ["ds_store==1.3.1", "mac_alias==2.2.2"]


def bootstrap_venv() -> None:
    if not VENV_PY.exists():
        print(f"Creating venv at {VENV.relative_to(REPO)}...", file=sys.stderr)
        VENV.parent.mkdir(parents=True, exist_ok=True)
        venv.create(VENV, with_pip=True, clear=True)
        subprocess.check_call(
            [str(VENV_PY), "-m", "pip", "install", "--quiet", *DEPS]
        )
    if Path(sys.executable).resolve() != VENV_PY.resolve():
        os.execv(str(VENV_PY), [str(VENV_PY), __file__, *sys.argv[1:]])


bootstrap_venv()

import shutil
import tempfile

from ds_store import DSStore

APP_NAME = "Xcode MCP Tap.app"
SIGN_IDENTITY = "Developer ID Application: Alfred Zien (GU3RT64VWG)"
APP_BUNDLE = REPO / ".build" / "Release" / APP_NAME
DMG_PATH = REPO / ".build" / "XcodeMCPTap.dmg"
VOLUME_NAME = "XcodeMCPTap"

WINDOW_BOUNDS = "{{400, 100}, {600, 300}}"
ICON_SIZE = 100.0
APP_POSITION = (150, 120)
APPS_POSITION = (450, 120)


def write_ds_store(path: Path) -> None:
    with DSStore.open(str(path), "w+") as d:
        d["."]["vSrn"] = ("long", 1)
        d["."]["bwsp"] = {
            "WindowBounds": WINDOW_BOUNDS,
            "ShowSidebar": False,
            "ShowToolbar": False,
            "ShowStatusBar": False,
            "ShowPathbar": False,
            "ShowTabView": False,
            "PreviewPaneVisibility": False,
            "SidebarWidth": 0,
        }
        d["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "arrangeBy": "none",
            "iconSize": ICON_SIZE,
            "gridSpacing": 100.0,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "labelOnBottom": True,
            "showItemInfo": False,
            "showIconPreview": True,
            "textSize": 12.0,
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
            "backgroundType": 0,
            "backgroundColorRed": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorBlue": 1.0,
        }
        d[APP_NAME]["Iloc"] = APP_POSITION
        d["Applications"]["Iloc"] = APPS_POSITION


def main() -> None:
    if not APP_BUNDLE.exists():
        sys.exit(f"App bundle not found: {APP_BUNDLE}")

    DMG_PATH.unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(prefix="xcmcptap-dmg-") as tmp:
        staging = Path(tmp) / "stage"
        staging.mkdir()
        print(f"Staging {APP_NAME}...", file=sys.stderr)
        shutil.copytree(APP_BUNDLE, staging / APP_NAME, symlinks=True)
        (staging / "Applications").symlink_to("/Applications")
        write_ds_store(staging / ".DS_Store")

        print("Creating DMG...", file=sys.stderr)
        subprocess.check_call([
            "hdiutil", "create",
            "-srcfolder", str(staging),
            "-volname", VOLUME_NAME,
            "-fs", "HFS+",
            "-format", "UDZO",
            "-imagekey", "zlib-level=9",
            "-ov",
            "-quiet",
            str(DMG_PATH),
        ])

    print("Signing DMG...", file=sys.stderr)
    subprocess.check_call(
        ["codesign", "--force", "--sign", SIGN_IDENTITY, str(DMG_PATH)]
    )

    print(f"DMG created: {DMG_PATH.relative_to(REPO)}")


if __name__ == "__main__":
    main()
