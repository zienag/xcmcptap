#!/usr/bin/env python3
"""Probe the Xcode MCP Tap service via the stdio client.

Usage:
  probe_tool.py [--tool NAME] [--args JSON] [--timeout SECS] [--client PATH]

Speaks line-delimited JSON-RPC to the xcmcptap stdio client. Sends
`initialize`, `notifications/initialized`, optionally `tools/list`, then
`tools/call` for the requested tool. Each response is read with an
individual timeout so we can tell exactly where we hang.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time


DEFAULT_CLIENT = os.path.expanduser("~/.local/bin/xcmcptap")


def send(proc: subprocess.Popen, obj: dict) -> None:
    line = json.dumps(obj, separators=(",", ":"))
    sys.stderr.write(f"[>] {line}\n")
    sys.stderr.flush()
    assert proc.stdin is not None
    proc.stdin.write(line + "\n")
    proc.stdin.flush()


def recv(proc: subprocess.Popen, timeout: float) -> dict | None:
    """Read one JSON line from proc.stdout with a timeout, return dict or None on timeout."""
    assert proc.stdout is not None
    end = time.monotonic() + timeout
    buf = b""
    while True:
        remaining = end - time.monotonic()
        if remaining <= 0:
            sys.stderr.write(f"[!] timeout after {timeout:.1f}s, partial buf={buf!r}\n")
            return None
        r, _, _ = select.select([proc.stdout], [], [], remaining)
        if not r:
            continue
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            sys.stderr.write("[!] stdout closed\n")
            return None
        buf += chunk
        # JSON-RPC messages are newline-delimited by the xcmcptap client.
        nl = buf.find(b"\n")
        if nl >= 0:
            line = buf[:nl].decode("utf-8", errors="replace")
            sys.stderr.write(f"[<] {line[:200]}{'...' if len(line) > 200 else ''}\n")
            try:
                return json.loads(line)
            except json.JSONDecodeError as e:
                sys.stderr.write(f"[!] bad JSON: {e}\n")
                return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", default=None,
                    help="tool name to call (omit to only do tools/list)")
    ap.add_argument("--args", default="{}",
                    help="JSON object of tool arguments (default: {})")
    ap.add_argument("--timeout", type=float, default=10.0,
                    help="per-response timeout seconds (default: 10)")
    ap.add_argument("--client", default=DEFAULT_CLIENT,
                    help=f"path to xcmcptap client (default: {DEFAULT_CLIENT})")
    ap.add_argument("--list", action="store_true",
                    help="also run tools/list before tools/call")
    ap.add_argument("--no-init", action="store_true",
                    help="skip initialize handshake (to test raw forwarding)")
    args = ap.parse_args()

    try:
        tool_args = json.loads(args.args)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"bad --args JSON: {e}\n")
        return 2

    proc = subprocess.Popen(
        [args.client],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        text=True,  # we want to write() str; reads happen via os.read below
        bufsize=0,
    )
    try:
        if not args.no_init:
            send(proc, {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "probe", "version": "1.0"},
                },
            })
            init_resp = recv(proc, args.timeout)
            if init_resp is None:
                sys.stderr.write("[!] no initialize response\n")
                return 1
            send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})

        if args.list:
            send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
            list_resp = recv(proc, args.timeout)
            if list_resp is None:
                sys.stderr.write("[!] no tools/list response\n")
                return 1

        if args.tool:
            t0 = time.monotonic()
            send(proc, {
                "jsonrpc": "2.0",
                "id": 42,
                "method": "tools/call",
                "params": {"name": args.tool, "arguments": tool_args},
            })
            call_resp = recv(proc, args.timeout)
            dt = time.monotonic() - t0
            if call_resp is None:
                sys.stderr.write(f"[!] NO tools/call response after {dt:.2f}s\n")
                return 1
            sys.stderr.write(f"[+] tools/call responded after {dt:.2f}s\n")

        return 0
    finally:
        try:
            proc.stdin.close()  # type: ignore[union-attr]
        except Exception:
            pass
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
