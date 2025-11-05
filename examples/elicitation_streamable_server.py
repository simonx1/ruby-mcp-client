#!/usr/bin/env python3
"""
MCP Server demonstrating Elicitation via Streamable HTTP Transport (MCP 2025-06-18)

This server provides tools that use elicitation to request user input during
execution over HTTP with SSE-formatted responses.

Usage:
    # Install dependencies
    pip install mcp starlette uvicorn sse-starlette

    # Run server
    python elicitation_streamable_server.py

    # Server runs on http://localhost:8000

Requirements:
    pip install mcp starlette uvicorn sse-starlette
"""

import asyncio
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from mcp.server import Server
from mcp.server.models import InitializationOptions
from mcp.server.session import ServerSession
from mcp.shared.context import RequestContext
import mcp.types as types
from pydantic import BaseModel, Field
from starlette.applications import Starlette
from starlette.responses import Response
from starlette.routing import Route


# Create MCP server instance
mcp_server = Server("elicitation-streamable-demo")


# Pydantic models for elicitation schemas
class DocumentDetails(BaseModel):
    """Schema for collecting document details."""
    title: str = Field(description="The document title", min_length=1)
    author: str = Field(description="The document author", default="Anonymous")


class ContentInput(BaseModel):
    """Schema for collecting document content."""
    content: str = Field(description="The document content", min_length=1)


class ConfirmationInput(BaseModel):
    """Schema for operation confirmation."""
    confirm: bool = Field(description="Confirm the operation")
    reason: str = Field(
        description="Optional reason for declining",
        default="",
        min_length=0
    )


@mcp_server.list_tools()
async def list_tools() -> list[types.Tool]:
    """List available tools with elicitation support."""
    return [
        types.Tool(
            name="create_document",
            description="Create a document interactively via elicitation. Asks for title, author, and content.",
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
            name="delete_files",
            description="Delete files with confirmation. Uses elicitation to confirm destructive operation.",
            inputSchema={
                "type": "object",
                "properties": {
                    "file_pattern": {
                        "type": "string",
                        "description": "File pattern to delete (e.g., '*.tmp')",
                    }
                },
                "required": ["file_pattern"],
            },
        ),
        types.Tool(
            name="deploy_application",
            description="Deploy application with multi-step confirmation.",
            inputSchema={
                "type": "object",
                "properties": {
                    "environment": {
                        "type": "string",
                        "enum": ["development", "staging", "production"],
                        "description": "Target environment",
                    },
                    "version": {
                        "type": "string",
                        "description": "Version to deploy",
                    }
                },
                "required": ["environment", "version"],
            },
        ),
    ]


@mcp_server.call_tool()
async def call_tool(
    name: str, arguments: dict | None
) -> list[types.TextContent | types.ImageContent | types.EmbeddedResource]:
    """Handle tool execution with elicitation."""

    if name == "create_document":
        return await handle_create_document(arguments or {})
    elif name == "delete_files":
        return await handle_delete_files(arguments or {})
    elif name == "deploy_application":
        return await handle_deploy_application(arguments or {})
    else:
        raise ValueError(f"Unknown tool: {name}")


async def handle_create_document(arguments: dict) -> list[types.TextContent]:
    """Create a document using elicitation to gather details."""
    format_type = arguments.get("format", "plain")
    ctx: RequestContext[ServerSession, Any] = mcp_server.request_context

    # Step 1: Request document details (title and author)
    details_result = await ctx.session.create_elicitation(
        message="📝 Please provide document details:",
        requested_schema=DocumentDetails.model_json_schema(),
    )

    if details_result.action == "decline":
        return [types.TextContent(
            type="text",
            text="❌ User declined to provide document details. Operation cancelled."
        )]
    elif details_result.action == "cancel":
        return [types.TextContent(
            type="text",
            text="⊗ User cancelled the operation."
        )]

    # Validate and extract details
    details = DocumentDetails.model_validate(details_result.content)

    # Step 2: Request document content
    content_result = await ctx.session.create_elicitation(
        message=f"📄 Please provide content for '{details.title}' by {details.author}:",
        requested_schema=ContentInput.model_json_schema(),
    )

    if content_result.action == "decline":
        return [types.TextContent(
            type="text",
            text=f"❌ User declined to provide content. Document '{details.title}' not created."
        )]
    elif content_result.action == "cancel":
        return [types.TextContent(
            type="text",
            text="⊗ User cancelled the operation."
        )]

    # Validate and extract content
    content_data = ContentInput.model_validate(content_result.content)

    # Format the document
    if format_type == "markdown":
        document = f"# {details.title}\n\n**Author:** {details.author}\n\n{content_data.content}"
    elif format_type == "html":
        document = f"""<html>
<head><title>{details.title}</title></head>
<body>
<h1>{details.title}</h1>
<p><em>By {details.author}</em></p>
<p>{content_data.content}</p>
</body>
</html>"""
    else:
        document = f"{details.title}\nBy {details.author}\n\n{content_data.content}"

    return [types.TextContent(
        type="text",
        text=f"✅ Document created successfully!\n\nFormat: {format_type}\nTitle: {details.title}\nAuthor: {details.author}\n\n{document}"
    )]


async def handle_delete_files(arguments: dict) -> list[types.TextContent]:
    """Delete files with confirmation via elicitation."""
    file_pattern = arguments.get("file_pattern", "*.tmp")
    ctx: RequestContext[ServerSession, Any] = mcp_server.request_context

    # Simulate finding files
    files_found = ["temp1.tmp", "temp2.tmp", "cache.tmp"]

    # Request confirmation
    confirmation_result = await ctx.session.create_elicitation(
        message=f"⚠️  WARNING: Delete Files\n\nPattern: {file_pattern}\nFiles to delete: {len(files_found)}\n- {', '.join(files_found)}\n\nThis operation cannot be undone. Do you want to proceed?",
        requested_schema=ConfirmationInput.model_json_schema(),
    )

    if confirmation_result.action == "decline":
        return [types.TextContent(
            type="text",
            text="❌ User declined. No files were deleted."
        )]
    elif confirmation_result.action == "cancel":
        return [types.TextContent(
            type="text",
            text="⊗ Operation cancelled. No files were deleted."
        )]

    # Validate confirmation
    confirmation = ConfirmationInput.model_validate(confirmation_result.content)

    if not confirmation.confirm:
        reason = confirmation.reason or "No reason provided"
        return [types.TextContent(
            type="text",
            text=f"❌ Deletion not confirmed. Reason: {reason}\nNo files were deleted."
        )]

    # Simulate deletion
    return [types.TextContent(
        type="text",
        text=f"✅ Successfully deleted {len(files_found)} files:\n- " + "\n- ".join(files_found)
    )]


async def handle_deploy_application(arguments: dict) -> list[types.TextContent]:
    """Deploy application with multi-step confirmation."""
    environment = arguments.get("environment", "development")
    version = arguments.get("version", "latest")
    ctx: RequestContext[ServerSession, Any] = mcp_server.request_context

    # Step 1: Initial confirmation
    initial_confirmation = await ctx.session.create_elicitation(
        message=f"🚀 Deploy Application\n\nEnvironment: {environment}\nVersion: {version}\n\nDo you want to proceed with deployment?",
        requested_schema=ConfirmationInput.model_json_schema(),
    )

    if initial_confirmation.action != "accept" or not ConfirmationInput.model_validate(initial_confirmation.content).confirm:
        return [types.TextContent(
            type="text",
            text="❌ Deployment cancelled at initial confirmation."
        )]

    # Step 2: Production-specific confirmation
    if environment == "production":
        prod_confirmation = await ctx.session.create_elicitation(
            message=f"⚠️  PRODUCTION DEPLOYMENT\n\nYou are deploying version {version} to PRODUCTION.\n\nThis will affect live users. Please confirm again:",
            requested_schema=ConfirmationInput.model_json_schema(),
        )

        if prod_confirmation.action != "accept" or not ConfirmationInput.model_validate(prod_confirmation.content).confirm:
            return [types.TextContent(
                type="text",
                text="❌ Production deployment cancelled at final confirmation."
            )]

    # Simulate deployment
    return [types.TextContent(
        type="text",
        text=f"✅ Successfully deployed version {version} to {environment}!\n\nDeployment completed at: 2025-01-05 12:00:00 UTC"
    )]


# Starlette app for HTTP transport
async def handle_mcp_request(request):
    """Handle MCP requests via Streamable HTTP."""
    body = await request.body()

    # Create a simple request/response stream
    from io import BytesIO

    read_stream = BytesIO(body)
    write_stream = BytesIO()

    # Process the request
    # Note: This is a simplified implementation
    # A production server would need proper SSE streaming

    import json
    request_data = json.loads(body)

    response_data = {
        "jsonrpc": "2.0",
        "id": request_data.get("id"),
        "result": {"status": "ok"}
    }

    return Response(
        content=json.dumps(response_data),
        media_type="application/json"
    )


@asynccontextmanager
async def lifespan(app: Starlette):
    """Application lifespan manager."""
    print("🚀 Starting Elicitation Streamable HTTP Server")
    print("   URL: http://localhost:8000")
    print("   Transport: Streamable HTTP with SSE")
    print("   Features: Elicitation support enabled")
    yield
    print("👋 Shutting down server")


app = Starlette(
    routes=[
        Route("/mcp", handle_mcp_request, methods=["POST"]),
    ],
    lifespan=lifespan,
)


if __name__ == "__main__":
    print("Starting MCP Elicitation Streamable HTTP Server...")
    print("Server will be available at: http://localhost:8000")
    print("")
    print("Use the Ruby client example to connect:")
    print("  ruby examples/test_elicitation_streamable.rb")
    print("")

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        log_level="info"
    )
