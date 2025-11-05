#!/usr/bin/env python3
"""
MCP Server demonstrating Elicitation (MCP 2025-06-18)

This server provides tools that use elicitation to request user input
during tool execution. Demonstrates all three response actions:
- accept: User provides requested input
- decline: User refuses to provide input
- cancel: User cancels the operation

Usage:
    python elicitation_server.py

Requirements:
    pip install mcp
"""

import asyncio
import json
from typing import Any
from mcp.server.models import InitializationOptions
import mcp.types as types
from mcp.server import NotificationOptions, Server
import mcp.server.stdio


app = Server("elicitation-demo")


@app.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    """List available tools with elicitation support."""
    return [
        types.Tool(
            name="create_document",
            description="Create a document with user-provided title and content. Uses elicitation to ask for details.",
            inputSchema={
                "type": "object",
                "properties": {
                    "format": {
                        "type": "string",
                        "enum": ["markdown", "plain", "html"],
                        "description": "The document format",
                    }
                },
                "required": ["format"],
            },
        ),
        types.Tool(
            name="sensitive_operation",
            description="Performs a sensitive operation that requires explicit user confirmation via elicitation.",
            inputSchema={
                "type": "object",
                "properties": {
                    "operation": {
                        "type": "string",
                        "description": "The operation to perform",
                    }
                },
                "required": ["operation"],
            },
        ),
    ]


@app.call_tool()
async def handle_call_tool(
    name: str, arguments: dict | None
) -> list[types.TextContent | types.ImageContent | types.EmbeddedResource]:
    """Handle tool execution with elicitation."""

    if name == "create_document":
        return await handle_create_document(arguments or {})
    elif name == "sensitive_operation":
        return await handle_sensitive_operation(arguments or {})
    else:
        raise ValueError(f"Unknown tool: {name}")


async def handle_create_document(arguments: dict) -> list[types.TextContent]:
    """Create a document using elicitation to gather title and content."""
    format_type = arguments.get("format", "plain")

    # Request document title via elicitation
    title_schema = {
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": "The document title",
                "minLength": 1,
            }
        },
        "required": ["title"],
    }

    try:
        title_result = await app.request_context.session.create_elicitation(
            message="Please provide a title for the document:",
            requested_schema=title_schema,
        )

        if title_result.action == "decline":
            return [
                types.TextContent(
                    type="text",
                    text="User declined to provide document title. Operation cancelled.",
                )
            ]
        elif title_result.action == "cancel":
            return [
                types.TextContent(
                    type="text",
                    text="User cancelled the operation.",
                )
            ]

        title = title_result.content.get("title", "Untitled")

        # Request document content via elicitation
        content_schema = {
            "type": "object",
            "properties": {
                "content": {
                    "type": "string",
                    "description": "The document content",
                    "minLength": 1,
                }
            },
            "required": ["content"],
        }

        content_result = await app.request_context.session.create_elicitation(
            message=f"Please provide content for '{title}':",
            requested_schema=content_schema,
        )

        if content_result.action == "decline":
            return [
                types.TextContent(
                    type="text",
                    text=f"User declined to provide content. Document '{title}' not created.",
                )
            ]
        elif content_result.action == "cancel":
            return [
                types.TextContent(
                    type="text",
                    text="User cancelled the operation.",
                )
            ]

        content = content_result.content.get("content", "")

        # Format the document based on the requested format
        if format_type == "markdown":
            document = f"# {title}\n\n{content}"
        elif format_type == "html":
            document = f"<html><head><title>{title}</title></head><body><h1>{title}</h1><p>{content}</p></body></html>"
        else:
            document = f"{title}\n\n{content}"

        return [
            types.TextContent(
                type="text",
                text=f"Document created successfully!\n\nFormat: {format_type}\n\n{document}",
            )
        ]

    except Exception as e:
        return [
            types.TextContent(
                type="text",
                text=f"Error during elicitation: {str(e)}",
            )
        ]


async def handle_sensitive_operation(arguments: dict) -> list[types.TextContent]:
    """Perform a sensitive operation with user confirmation via elicitation."""
    operation = arguments.get("operation", "unknown")

    # Request confirmation via elicitation
    confirmation_schema = {
        "type": "object",
        "properties": {
            "confirm": {
                "type": "boolean",
                "description": "Confirm the operation",
            }
        },
        "required": ["confirm"],
    }

    try:
        confirmation_result = await app.request_context.session.create_elicitation(
            message=f"⚠️  You are about to perform: '{operation}'\n\nThis is a sensitive operation. Do you want to proceed?",
            requested_schema=confirmation_schema,
        )

        if confirmation_result.action == "decline":
            return [
                types.TextContent(
                    type="text",
                    text="User declined to confirm. Operation cancelled.",
                )
            ]
        elif confirmation_result.action == "cancel":
            return [
                types.TextContent(
                    type="text",
                    text="User cancelled the operation.",
                )
            ]

        confirmed = confirmation_result.content.get("confirm", False)

        if not confirmed:
            return [
                types.TextContent(
                    type="text",
                    text="Operation not confirmed. Cancelled.",
                )
            ]

        # Simulate performing the operation
        return [
            types.TextContent(
                type="text",
                text=f"✓ Operation '{operation}' completed successfully (with user confirmation).",
            )
        ]

    except Exception as e:
        return [
            types.TextContent(
                type="text",
                text=f"Error during elicitation: {str(e)}",
            )
        ]


async def main():
    """Run the MCP server."""
    # Run the server using stdin/stdout streams
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await app.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="elicitation-demo",
                server_version="1.0.0",
                capabilities=app.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={},
                ),
            ),
        )


if __name__ == "__main__":
    asyncio.run(main())
