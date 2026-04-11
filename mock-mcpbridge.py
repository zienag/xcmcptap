#!/usr/bin/env python3
"""Fake mcpbridge over stdio.

Mimics `xcrun mcpbridge`'s observed wire behavior closely enough that tests
can exercise the full MCP handshake without requiring Xcode to be installed
or the per-launch Xcode permission dialog to be dismissed.

Key differences from the permissive fake-mcp-server.py:

- Strictly requires `notifications/initialized` (spec-compliant name) before
  answering tools/list or tools/call. Requests received before a valid
  initialized notification are silently dropped, matching real mcpbridge.
  This is a regression guard for the bug where MCPRouter was sending the
  wrong notification name `initialized` and mcpbridge silently dropped
  every follow-up request.
- Returns the exact shape real mcpbridge returned when probed manually:
  protocolVersion=2025-06-18, serverInfo.name=xcode-tools,
  capabilities.tools.listChanged=True, and an instructions field.
- Exposes a small set of Xcode-shaped tools with inputSchemas so callers
  that want to verify `tools/list` parsing have realistic data.
"""

import json
import sys


# Matches what real mcpbridge returned on this machine when probed directly.
INIT_RESULT = {
    "protocolVersion": "2025-06-18",
    "capabilities": {"tools": {"listChanged": True}},
    "instructions": "Request Xcode perform the action you specify.",
    "serverInfo": {"name": "xcode-tools", "version": "24582"},
}


TOOLS = [
    {
        "name": "BuildProject",
        "description": "Builds the Xcode project and returns warnings and errors.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "tabIdentifier": {
                    "type": "string",
                    "description": "The workspace tab identifier",
                },
                "destination": {
                    "type": "string",
                    "description": "Destination specifier",
                },
            },
            "required": ["tabIdentifier"],
        },
    },
    {
        "name": "XcodeGrep",
        "description": "Searches for text patterns in files within the Xcode project.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "tabIdentifier": {"type": "string"},
                "pattern": {"type": "string"},
                "path": {"type": "string"},
            },
            "required": ["tabIdentifier", "pattern"],
        },
    },
    {
        "name": "XcodeRead",
        "description": "Reads a file in the Xcode project.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "tabIdentifier": {"type": "string"},
                "path": {"type": "string"},
            },
            "required": ["tabIdentifier", "path"],
        },
    },
]


class State:
    def __init__(self):
        self.init_received = False
        self.initialized = False


def log(msg):
    sys.stderr.write(f"[fake-mcpbridge] {msg}\n")
    sys.stderr.flush()


def handle(req, state):
    method = req.get("method")
    rid = req.get("id")

    if method == "initialize":
        state.init_received = True
        return {"jsonrpc": "2.0", "id": rid, "result": INIT_RESULT}

    if method == "notifications/initialized":
        if state.init_received:
            state.initialized = True
        return None

    # Real mcpbridge silently drops anything that arrives before a valid
    # `notifications/initialized`. Unknown notifications (including the
    # wrong spelling `initialized`) are also silently dropped — never
    # flipping the ready flag.
    if not state.initialized:
        log(f"dropped method={method!r} before notifications/initialized")
        return None

    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}

    if method == "tools/call":
        params = req.get("params", {})
        tool_name = params.get("name", "unknown")
        arguments = params.get("arguments", {})
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(
                            {"tool": tool_name, "arguments": arguments, "fake": True}
                        ),
                    }
                ],
                "isError": False,
            },
        }

    if rid is not None:
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }

    return None


def main():
    state = State()
    log("started")
    for raw_line in iter(sys.stdin.buffer.readline, b""):
        line = raw_line.decode().strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            log(f"parse error: {line[:120]}")
            continue
        log(f"recv: {line[:120]}")
        resp = handle(req, state)
        if resp is not None:
            out = json.dumps(resp)
            log(f"send: {out[:120]}")
            sys.stdout.write(out + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
