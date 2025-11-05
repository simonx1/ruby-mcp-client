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

from pydantic import BaseModel, Field
from mcp.server.fastmcp import Context, FastMCP
from mcp.server.session import ServerSession

app = FastMCP(name="elicitation-demo")


# Pydantic models for elicitation schemas
class DocumentTitle(BaseModel):
    """Schema for document title."""
    title: str = Field(description="The document title", min_length=1)


class DocumentContent(BaseModel):
    """Schema for document content."""
    content: str = Field(description="The document content", min_length=1)


class ConfirmOperation(BaseModel):
    """Schema for operation confirmation."""
    confirm: bool = Field(description="Confirm the operation")


@app.tool()
async def create_document(
    format: str,
    ctx: Context[ServerSession, None]
) -> str:
    """Create a document with user-provided title and content. Uses elicitation to ask for details."""

    # Request document title via elicitation
    title_result = await ctx.elicit(
        message="Please provide a title for the document:",
        schema=DocumentTitle,
    )

    if title_result.action == "decline":
        return "User declined to provide document title. Operation cancelled."
    elif title_result.action == "cancel":
        return "User cancelled the operation."

    title = title_result.data.title if title_result.data else "Untitled"

    # Request document content via elicitation
    content_result = await ctx.elicit(
        message=f"Please provide content for '{title}':",
        schema=DocumentContent,
    )

    if content_result.action == "decline":
        return f"User declined to provide content. Document '{title}' not created."
    elif content_result.action == "cancel":
        return "User cancelled the operation."

    content = content_result.data.content if content_result.data else ""

    # Format the document based on the requested format
    if format == "markdown":
        document = f"# {title}\n\n{content}"
    elif format == "html":
        document = f"<html><head><title>{title}</title></head><body><h1>{title}</h1><p>{content}</p></body></html>"
    else:
        document = f"{title}\n\n{content}"

    return f"Document created successfully!\n\nFormat: {format}\n\n{document}"


@app.tool()
async def send_notification(
    message: str,
    ctx: Context[ServerSession, None]
) -> str:
    """Sends a notification after confirming with the user via elicitation."""

    # Request confirmation via elicitation
    confirmation_result = await ctx.elicit(
        message=f"📢 Ready to send notification:\n\n\"{message}\"\n\nWould you like to send this notification?",
        schema=ConfirmOperation,
    )

    if confirmation_result.action == "decline":
        return "User declined to send the notification."
    elif confirmation_result.action == "cancel":
        return "User cancelled the notification."

    confirmed = confirmation_result.data.confirm if confirmation_result.data else False

    if not confirmed:
        return "Notification not confirmed. Not sent."

    # Simulate sending the notification
    return f"✓ Notification sent successfully: \"{message}\""


if __name__ == "__main__":
    app.run()
