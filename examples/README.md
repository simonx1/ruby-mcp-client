# ruby-mcp-client Examples

Runnable examples for the Ruby MCP client, plus a harness that runs them all. For the library API, installation, and full feature docs, see the [main README](../README.md).

## Run Everything: `run_all_examples.sh`

`run_all_examples.sh` starts and stops each example's server automatically, runs every example that can run on the current machine, and prints a `PASS`/`FAIL`/`SKIP` summary. Most examples print their own success/failure marks but exit `0` regardless, so the harness combines the exit code with an output scan — a Ruby/Python traceback, `Connection refused`, a `❌` mark, or a missing success marker all count as failures. (The `❌` check is suppressed with `IGNORE_XMARK=1` for the interactive elicitation demos, where `❌` can be legitimate "declined" output.) It exits `0` only if nothing failed — `SKIP`s do not affect the exit status.

Run it from the repository root (run `bundle install` first):

```bash
examples/run_all_examples.sh                       # run everything runnable on this machine
RUN_AI=0 examples/run_all_examples.sh              # skip the paid LLM examples
RUN_NPX=0 examples/run_all_examples.sh             # skip the npx-based example (json_input)
LOG_DIR=/path examples/run_all_examples.sh         # choose the log directory
PYTHON=python3.12 TIMEOUT=180 examples/run_all_examples.sh
```

| Variable | Default | Effect |
|----------|---------|--------|
| `RUN_AI` | `1` | Set to `0` to skip the LLM integrations, which make **real, paid** API calls. |
| `RUN_NPX` | `1` | Set to `0` (or leave `npx` off `PATH`) to skip the `npx`-based example (`json_input`). The LLM examples also spawn `npx` servers, but are gated by `RUN_AI` and their keys. |
| `PYTHON` | `python3` | Interpreter used for the Python/Flask/FastMCP servers and the import preflight checks. |
| `TIMEOUT` | `120` | Per-example wall-clock timeout in seconds; a timeout is reported as a `FAIL`. |
| `LOG_DIR` | fresh `mktemp` dir | Directory for per-example and per-server logs; the path is printed after preflight and in the summary. |

**Prerequisites:** `bundle install`, plus `ruby`, `bundle`, `curl`, `lsof`, both a `python3` and a `python` on `PATH`, the Python packages `flask` / `fastmcp` / `mcp`, and `npx` (Node) for the browser/filesystem examples. Missing tools produce a warning and cause the affected examples to be skipped or fail — never an abort.

**Secrets:** copy the tracked template to `secrets.env` (gitignored, auto-sourced) and set `ZAPIER_MCP_TOKEN` to enable the Zapier example:

```bash
cp secrets.env.example secrets.env
```

The LLM examples additionally need `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or a Vertex `VERTEX_CREDENTIALS_FILE` in the environment; each is skipped when its credentials are absent.

## Per-Topic Guides

| Guide | Covers |
|-------|--------|
| [README_ECHO_SERVER.md](README_ECHO_SERVER.md) | FastMCP echo server + Ruby client (tools, prompts, resources) |
| [STREAMABLE_HTTP_TESTING.md](STREAMABLE_HTTP_TESTING.md) | Streamable HTTP transport test servers/clients, ping/pong, notifications |
| [elicitation/README.md](elicitation/README.md) | Server-initiated elicitation over stdio, SSE, and Streamable HTTP |

## Example Index

### Protocol and Feature Demos (self-contained stdio)

Each of these spawns its own Python server over stdio — no external server or secrets needed.

| Example | What it shows |
|---------|---------------|
| `test_mcp_2025_11_25.rb` | Full MCP 2025-11-25 run — the one example with a real nonzero-exit pass/fail gate |
| `test_structured_outputs.rb` | Structured tool outputs and output schemas |
| `test_tool_annotations.rb` | Tool annotation hints |

### Echo Servers (FastMCP / Flask)

The harness starts the paired Python server, then runs the Ruby client against it.

| Example | Server / transport |
|---------|--------------------|
| `echo_server_client.rb` + `echo_server.py` | SSE, port `8000` |
| `echo_server_streamable_client.rb` + `echo_server_streamable.py` | Streamable HTTP, port `8931` |
| `test_mcp_protocol_features.rb` | Protocol features against `echo_server_streamable.py` (`:8931`) |
| `test_ping_pong.rb` | Ping/pong keepalive against `echo_server_streamable.py` (`:8931`) |

### AI Integrations (real, paid API calls)

| Example | Needs |
|---------|-------|
| `ruby_anthropic_mcp.rb` | `ANTHROPIC_API_KEY` + `npx` |
| `openai_ruby_mcp.rb` | `OPENAI_API_KEY` + `npx` |
| `ruby_openai_mcp.rb`, `ruby_llm_mcp.rb` | `OPENAI_API_KEY` + `npx` + Playwright MCP on `:8931` |
| `gemini_ai_mcp.rb` | Vertex `VERTEX_CREDENTIALS_FILE` JSON + `npx` (default model `gemini-2.5-flash`, override with `VERTEX_MODEL`) |

### Servers, Remote, and Auth

| Example | Notes |
|---------|-------|
| `json_input_mcp_servers_example.rb` | Loads servers from JSON (Playwright + filesystem); needs `npx` |
| `streamable_http_example.rb` | Zapier remote MCP; needs `ZAPIER_MCP_TOKEN` (else skipped) |
| `tasks_example.rb` | Task-augmented tools; needs a task-capable remote HTTP MCP server (always skipped by the harness) |
| `oauth_browser_auth.rb`, `oauth_example.rb` | OAuth 2.1 flows — interactive / illustrative (always skipped by the harness) |

### Elicitation

Server-initiated user interactions over stdio, SSE, and Streamable HTTP. The `test_elicitation*.rb` clients prompt for input; the harness drives them non-interactively with canned stdin (blank input to decline, an "accept" fixture for the happy path). See [elicitation/README.md](elicitation/README.md).

### Python Servers and Fixtures

| File | Role |
|------|------|
| `echo_server.py` | FastMCP SSE echo server |
| `echo_server_streamable.py` | Flask Streamable HTTP echo server |
| `echo_server_with_annotations.py` | Echo server advertising tool annotations |
| `mcp_2025_11_25_server.py` | Backs `test_mcp_2025_11_25.rb` |
| `structured_output_server.py` | Backs `test_structured_outputs.rb` |
| `sample_server_definition.json` | Example server-definition JSON |

---

Back to the [main README](../README.md).
