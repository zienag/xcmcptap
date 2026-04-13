#!/usr/bin/env python3
"""Mock mcpbridge over stdio — the one and only test fixture.

Mimics `xcrun mcpbridge`'s observed wire behavior closely enough that tests
can exercise the full MCP handshake without requiring Xcode to be installed
or the per-launch Xcode permission dialog to be dismissed.

Behavior pinned to real mcpbridge:

- Strictly requires `notifications/initialized` (spec-compliant name) before
  answering tools/list or tools/call. Requests received before a valid
  initialized notification are silently dropped, matching real mcpbridge.
  This is a regression guard for the bug where MCPRouter was sending the
  wrong notification name `initialized` and mcpbridge silently dropped
  every follow-up request.
- Returns the exact shape real mcpbridge returned when probed manually:
  protocolVersion=2025-06-18, serverInfo.name=xcode-tools,
  capabilities.tools.listChanged=True, and an instructions field.
- Exposes a small set of Xcode-shaped tools with realistic inputSchemas.
- `XcodeListWindows` returns the exact response shape Claude Code observed
  in production: `content[0].text` carries a JSON-encoded projection and
  `structuredContent` carries typed data matching the outputSchema.
- Unknown-tool `tools/call` falls back to an echo of `{tool, arguments}`
  for parameterized tests that don't need a realistic payload.
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


# Canned XcodeListWindows output captured from real mcpbridge when both the
# multivibe workspace and the xcmcptap project were open. Pinned verbatim so
# tests can assert on the exact wire shape Claude Code receives.
XCODE_LIST_WINDOWS_MESSAGE = (
    "* tabIdentifier: windowtab2, workspacePath: /Users/alfred/dev/multivibe/Multivibe.xcworkspace\n"
    "* tabIdentifier: windowtab1, workspacePath: /Users/alfred/dev/xcmcptap/XcodeMCPTap.xcodeproj\n"
)


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
    {
        "name": "XcodeListWindows",
        "description": "Lists the current Xcode windows and their workspace information",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "outputSchema": {
            "type": "object",
            "properties": {
                "message": {
                    "type": "string",
                    "description": "Description of all open Xcode windows",
                }
            },
            "required": ["message"],
        },
        "title": "List Windows",
    },
]


# Canned tools/call responses keyed by tool name. The wire shape mirrors
# what real mcpbridge returned: `content[0].text` carries a JSON-encoded
# projection, and `structuredContent` carries the same data in typed form
# matching the tool's outputSchema.
TOOL_RESPONSES = {
    "XcodeListWindows": {
        "content": [
            {
                "type": "text",
                "text": json.dumps({"message": XCODE_LIST_WINDOWS_MESSAGE}),
            }
        ],
        "structuredContent": {"message": XCODE_LIST_WINDOWS_MESSAGE},
    },
}


class State:
    def __init__(self):
        self.init_received = False
        self.initialized = False
        # Last observed `notifications/cancelled` requestId (as the mock
        # saw it — i.e., the bridge-facing id the router rewrote to).
        # Tests read this via the __last_cancel probe tool.
        self.last_cancel_request_id = None


def log(msg):
    sys.stderr.write(f"[mock-mcpbridge] {msg}\n")
    sys.stderr.flush()


def handle(req, state, emit):
    method = req.get("method")
    rid = req.get("id")

    if method == "initialize":
        state.init_received = True
        return {"jsonrpc": "2.0", "id": rid, "result": INIT_RESULT}

    if method == "notifications/initialized":
        if state.init_received:
            state.initialized = True
        return None

    if method == "notifications/cancelled":
        if state.initialized:
            params = req.get("params") or {}
            state.last_cancel_request_id = params.get("requestId")
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

        # Test-only probe tools (prefix `__`) — exercise router behavior
        # that real mcpbridge triggers asynchronously in production.
        if tool_name == "__emit_progress":
            progress_token = (params.get("_meta") or {}).get("progressToken")
            if progress_token is not None:
                emit({
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {
                        "progressToken": progress_token,
                        "progress": 50,
                        "message": "halfway",
                    },
                })
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {"content": [{"type": "text", "text": "progress emitted"}]},
            }

        if tool_name == "__emit_broadcast":
            emit({
                "jsonrpc": "2.0",
                "method": "notifications/tools/list_changed",
                "params": {},
            })
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {"content": [{"type": "text", "text": "broadcast emitted"}]},
            }

        if tool_name == "__last_cancel":
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {
                    "content": [{
                        "type": "text",
                        "text": json.dumps({"requestId": state.last_cancel_request_id}),
                    }]
                },
            }

        if tool_name in TOOL_RESPONSES:
            return {"jsonrpc": "2.0", "id": rid, "result": TOOL_RESPONSES[tool_name]}
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

    def emit(obj):
        out = json.dumps(obj)
        log(f"emit: {out[:120]}")
        sys.stdout.write(out + "\n")
        sys.stdout.flush()

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
        resp = handle(req, state, emit)
        if resp is not None:
            emit(resp)


if __name__ == "__main__":
    main()
