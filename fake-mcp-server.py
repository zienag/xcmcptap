#!/usr/bin/env python3
"""Fake MCP server over stdio. Echoes tool name and arguments back."""

import json
import sys


def handle(req):
    method = req.get("method")
    params = req.get("params", {})
    rid = req.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "fake-mcp-server", "version": "1.0.0"},
            },
        }

    if method in ("initialized", "notifications/initialized"):
        return None

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "tools": [
                    {
                        "name": "echo",
                        "description": "Echoes back the input",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "message": {
                                    "type": "string",
                                    "description": "Message to echo",
                                }
                            },
                        },
                    },
                    {
                        "name": "greet",
                        "description": "Returns a greeting",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string", "description": "Name"}
                            },
                        },
                    },
                ]
            },
        }

    if method == "tools/call":
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
                            {"tool": tool_name, "arguments": arguments, "echo": True}
                        ),
                    }
                ]
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
    sys.stderr.write("[fake-mcp] started\n")
    sys.stderr.flush()
    for raw_line in iter(sys.stdin.buffer.readline, b""):
        line = raw_line.decode().strip()
        sys.stderr.write(f"[fake-mcp] recv: {line[:120]}\n")
        sys.stderr.flush()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp = handle(req)
        if resp is not None:
            out = json.dumps(resp)
            sys.stderr.write(f"[fake-mcp] send: {out[:120]}\n")
            sys.stderr.flush()
            sys.stdout.write(out + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
