#!/usr/bin/env python3
"""
MCP Echo Server with Tool Annotations Example

This server demonstrates MCP 2025-03-26 tool annotations feature.
It provides tools with different annotation types (readOnly, destructive, requiresConfirmation).

To run this server:
1. Install mcp: pip install mcp
2. Run the server: python echo_server_with_annotations.py
3. Run the test client: bundle exec ruby examples/test_tool_annotations.rb

The server provides:
- read_data: A read-only tool that safely reads data
- delete_data: A destructive tool that requires confirmation
- update_data: A tool that modifies data
- analyze_text: A read-only analysis tool
"""

from mcp.server.models import InitializationOptions
from mcp.server import NotificationOptions, Server
from mcp.server.stdio import stdio_server
from mcp import types
import json
import asyncio

# Create server instance
server = Server("echo-server-with-annotations")

# Simple in-memory data store
data_store = {
    "user_1": {"name": "Alice", "role": "admin"},
    "user_2": {"name": "Bob", "role": "user"},
}

@server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    """Return list of available tools with annotations."""
    return [
        types.Tool(
            name="read_data",
            description="Read data from the store (safe, read-only operation)",
            inputSchema={
                "type": "object",
                "properties": {
                    "key": {
                        "type": "string",
                        "description": "The key to read from the data store"
                    }
                },
                "required": ["key"]
            },
            annotations={
                "readOnly": True
            }
        ),
        types.Tool(
            name="delete_data",
            description="Delete data from the store (destructive operation)",
            inputSchema={
                "type": "object",
                "properties": {
                    "key": {
                        "type": "string",
                        "description": "The key to delete from the data store"
                    }
                },
                "required": ["key"]
            },
            annotations={
                "destructive": True,
                "requiresConfirmation": True
            }
        ),
        types.Tool(
            name="update_data",
            description="Update data in the store (modifies data)",
            inputSchema={
                "type": "object",
                "properties": {
                    "key": {
                        "type": "string",
                        "description": "The key to update in the data store"
                    },
                    "value": {
                        "type": "object",
                        "description": "The new value to set"
                    }
                },
                "required": ["key", "value"]
            },
            annotations={
                "requiresConfirmation": False
            }
        ),
        types.Tool(
            name="analyze_text",
            description="Analyze text and return statistics (safe, read-only operation)",
            inputSchema={
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": "The text to analyze"
                    }
                },
                "required": ["text"]
            },
            annotations={
                "readOnly": True
            }
        ),
    ]

@server.call_tool()
async def handle_call_tool(
    name: str, arguments: dict
) -> list[types.TextContent | types.ImageContent | types.EmbeddedResource]:
    """Handle tool calls based on the tool name."""

    if name == "read_data":
        key = arguments.get("key")
        if key in data_store:
            result = data_store[key]
            return [
                types.TextContent(
                    type="text",
                    text=json.dumps(result, indent=2)
                )
            ]
        else:
            return [
                types.TextContent(
                    type="text",
                    text=f"Error: Key '{key}' not found in data store"
                )
            ]

    elif name == "delete_data":
        key = arguments.get("key")
        if key in data_store:
            deleted_value = data_store.pop(key)
            return [
                types.TextContent(
                    type="text",
                    text=f"Deleted key '{key}' with value: {json.dumps(deleted_value)}"
                )
            ]
        else:
            return [
                types.TextContent(
                    type="text",
                    text=f"Error: Key '{key}' not found in data store"
                )
            ]

    elif name == "update_data":
        key = arguments.get("key")
        value = arguments.get("value")
        old_value = data_store.get(key)
        data_store[key] = value
        return [
            types.TextContent(
                type="text",
                text=f"Updated key '{key}'. Old value: {json.dumps(old_value)}, New value: {json.dumps(value)}"
            )
        ]

    elif name == "analyze_text":
        text = arguments.get("text", "")
        words = text.split()
        chars = len(text)
        lines = text.count('\n') + 1

        result = {
            "word_count": len(words),
            "character_count": chars,
            "line_count": lines,
            "average_word_length": sum(len(word) for word in words) / len(words) if words else 0
        }

        return [
            types.TextContent(
                type="text",
                text=json.dumps(result, indent=2)
            )
        ]

    else:
        raise ValueError(f"Unknown tool: {name}")

async def main():
    """Run the MCP server using stdio transport."""
    print("🚀 MCP Echo Server with Tool Annotations", flush=True)
    print("=" * 50, flush=True)
    print("Features:", flush=True)
    print("✅ Tool annotations (readOnly, destructive, requiresConfirmation)", flush=True)
    print("✅ Stdio transport", flush=True)
    print("\nAvailable tools:", flush=True)
    print("  - read_data: Read-only data access [readOnly]", flush=True)
    print("  - delete_data: Destructive deletion [destructive, requiresConfirmation]", flush=True)
    print("  - update_data: Data modification", flush=True)
    print("  - analyze_text: Text analysis [readOnly]", flush=True)
    print("\nPress Ctrl+C to stop the server", flush=True)
    print("-" * 50, flush=True)

    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="echo-server-with-annotations",
                server_version="1.0.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={},
                ),
            ),
        )

if __name__ == "__main__":
    asyncio.run(main())
