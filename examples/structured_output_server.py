#!/usr/bin/env python3
"""
MCP Server with Structured Output Support (MCP 2025-06-18)

This server demonstrates the structured tool outputs feature introduced in MCP 2025-06-18.
Tools declare outputSchema and return structuredContent for type-safe, validated responses.

To run this server:
1. Install mcp: pip install mcp
2. Run the server: python structured_output_server.py
3. Run the test client: bundle exec ruby examples/test_structured_outputs.rb

Features demonstrated:
- Tools with outputSchema declarations
- Structured content responses with validation
- Backward compatibility with text content
"""

from mcp.server.models import InitializationOptions
from mcp.server import NotificationOptions, Server
from mcp.server.stdio import stdio_server
from mcp import types
import json
import asyncio
from datetime import datetime

# Create server instance
server = Server("structured-output-server")

@server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    """Return list of available tools with output schemas."""
    return [
        types.Tool(
            name="get_weather",
            description="Get current weather data for a location with structured output",
            inputSchema={
                "type": "object",
                "properties": {
                    "location": {
                        "type": "string",
                        "description": "City name or coordinates"
                    },
                    "units": {
                        "type": "string",
                        "enum": ["celsius", "fahrenheit"],
                        "description": "Temperature units",
                        "default": "celsius"
                    }
                },
                "required": ["location"]
            },
            # Output schema defines the structure of structured content
            outputSchema={
                "type": "object",
                "properties": {
                    "location": {
                        "type": "string",
                        "description": "Location name"
                    },
                    "temperature": {
                        "type": "number",
                        "description": "Current temperature"
                    },
                    "conditions": {
                        "type": "string",
                        "description": "Weather conditions"
                    },
                    "humidity": {
                        "type": "number",
                        "description": "Humidity percentage"
                    },
                    "wind_speed": {
                        "type": "number",
                        "description": "Wind speed in km/h"
                    },
                    "timestamp": {
                        "type": "string",
                        "description": "ISO 8601 timestamp"
                    }
                },
                "required": ["location", "temperature", "conditions", "humidity"]
            }
        ),
        types.Tool(
            name="analyze_text",
            description="Analyze text and return detailed statistics with structured output",
            inputSchema={
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": "Text to analyze"
                    },
                    "include_words": {
                        "type": "boolean",
                        "description": "Include word frequency analysis",
                        "default": False
                    }
                },
                "required": ["text"]
            },
            outputSchema={
                "type": "object",
                "properties": {
                    "character_count": {
                        "type": "integer",
                        "description": "Total characters including spaces"
                    },
                    "word_count": {
                        "type": "integer",
                        "description": "Total words"
                    },
                    "line_count": {
                        "type": "integer",
                        "description": "Total lines"
                    },
                    "sentence_count": {
                        "type": "integer",
                        "description": "Estimated sentence count"
                    },
                    "average_word_length": {
                        "type": "number",
                        "description": "Average characters per word"
                    },
                    "top_words": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "word": {"type": "string"},
                                "count": {"type": "integer"}
                            }
                        },
                        "description": "Most frequent words"
                    }
                },
                "required": ["character_count", "word_count", "line_count"]
            }
        ),
        types.Tool(
            name="calculate_stats",
            description="Calculate statistical measures for a dataset with structured output",
            inputSchema={
                "type": "object",
                "properties": {
                    "numbers": {
                        "type": "array",
                        "items": {"type": "number"},
                        "description": "Array of numbers to analyze"
                    }
                },
                "required": ["numbers"]
            },
            outputSchema={
                "type": "object",
                "properties": {
                    "count": {
                        "type": "integer",
                        "description": "Number of values"
                    },
                    "sum": {
                        "type": "number",
                        "description": "Sum of all values"
                    },
                    "mean": {
                        "type": "number",
                        "description": "Average value"
                    },
                    "median": {
                        "type": "number",
                        "description": "Median value"
                    },
                    "min": {
                        "type": "number",
                        "description": "Minimum value"
                    },
                    "max": {
                        "type": "number",
                        "description": "Maximum value"
                    },
                    "range": {
                        "type": "number",
                        "description": "Difference between max and min"
                    }
                },
                "required": ["count", "sum", "mean", "min", "max"]
            }
        ),
    ]

@server.call_tool()
async def handle_call_tool(
    name: str, arguments: dict
):
    """Handle tool calls and return structured content with text fallback."""

    if name == "get_weather":
        location = arguments.get("location", "Unknown")
        units = arguments.get("units", "celsius")

        # Simulate weather data
        structured_data = {
            "location": location,
            "temperature": 22.5 if units == "celsius" else 72.5,
            "conditions": "Partly cloudy",
            "humidity": 65,
            "wind_speed": 15.5,
            "timestamp": datetime.utcnow().isoformat() + "Z"
        }

        # Return tuple of (content, structured_data) for backward compatibility
        # The Python SDK will automatically handle both
        return (
            [types.TextContent(type="text", text=json.dumps(structured_data, indent=2))],
            structured_data
        )

    elif name == "analyze_text":
        text = arguments.get("text", "")
        include_words = arguments.get("include_words", False)

        words = text.split()
        sentences = text.count('.') + text.count('!') + text.count('?')

        # Calculate word frequency
        top_words = []
        if include_words and words:
            from collections import Counter
            word_freq = Counter(w.lower().strip('.,!?;:') for w in words)
            top_words = [
                {"word": word, "count": count}
                for word, count in word_freq.most_common(5)
            ]

        structured_data = {
            "character_count": len(text),
            "word_count": len(words),
            "line_count": text.count('\n') + 1,
            "sentence_count": max(1, sentences),
            "average_word_length": sum(len(w) for w in words) / len(words) if words else 0,
            "top_words": top_words
        }

        return (
            [types.TextContent(type="text", text=json.dumps(structured_data, indent=2))],
            structured_data
        )

    elif name == "calculate_stats":
        numbers = arguments.get("numbers", [])

        if not numbers:
            structured_data = {
                "count": 0,
                "sum": 0,
                "mean": 0,
                "median": 0,
                "min": 0,
                "max": 0,
                "range": 0
            }
        else:
            sorted_nums = sorted(numbers)
            n = len(numbers)
            median = sorted_nums[n // 2] if n % 2 == 1 else (sorted_nums[n // 2 - 1] + sorted_nums[n // 2]) / 2

            structured_data = {
                "count": n,
                "sum": sum(numbers),
                "mean": sum(numbers) / n,
                "median": median,
                "min": min(numbers),
                "max": max(numbers),
                "range": max(numbers) - min(numbers)
            }

        return (
            [types.TextContent(type="text", text=json.dumps(structured_data, indent=2))],
            structured_data
        )

    else:
        raise ValueError(f"Unknown tool: {name}")

async def main():
    """Run the MCP server using stdio transport."""
    print("🚀 MCP Server with Structured Outputs (2025-06-18)", flush=True)
    print("=" * 60, flush=True)
    print("Features:", flush=True)
    print("✅ Structured tool outputs with outputSchema", flush=True)
    print("✅ Type-safe responses with validation", flush=True)
    print("✅ Backward compatible text content", flush=True)
    print("✅ Stdio transport", flush=True)
    print("\nAvailable tools:", flush=True)
    print("  - get_weather: Weather data with structured output", flush=True)
    print("  - analyze_text: Text analysis with detailed statistics", flush=True)
    print("  - calculate_stats: Statistical calculations for datasets", flush=True)
    print("\nPress Ctrl+C to stop the server", flush=True)
    print("-" * 60, flush=True)

    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="structured-output-server",
                server_version="1.0.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={},
                ),
            ),
        )

if __name__ == "__main__":
    asyncio.run(main())
