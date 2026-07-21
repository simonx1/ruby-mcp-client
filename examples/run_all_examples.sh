#!/usr/bin/env bash
#
# run_all_examples.sh — pre-release regression runner for the ruby-mcp-client examples.
#
# Boots the appropriate server for each example (mostly Python; some npx MCP servers),
# waits for it to be ready, runs the Ruby client with a timeout, judges PASS/FAIL from
# the exit code AND the captured output (most examples print ✅/❌ but exit 0 regardless),
# then tears the server down. Prints a summary table at the end.
#
# Usage:
#   examples/run_all_examples.sh              # run everything runnable on this machine
#   RUN_AI=0 examples/run_all_examples.sh     # skip the paid-LLM examples
#   RUN_NPX=0 examples/run_all_examples.sh    # skip examples needing npx MCP servers
#   LOG_DIR=/path examples/run_all_examples.sh
#
# Env knobs:
#   RUN_AI   (default 1)   run the LLM examples that make real, paid API calls
#   RUN_NPX  (default 1)   run examples that spawn npx-based MCP servers (filesystem/playwright)
#   PYTHON   (default python3)
#   LOG_DIR  (default a fresh mktemp dir; path is printed)
#   TIMEOUT  (default 120) per-example timeout in seconds
#
# Secrets: examples/secrets.env (gitignored) is sourced automatically if present.
# Copy examples/secrets.env.example to examples/secrets.env and set ZAPIER_MCP_TOKEN
# to run streamable_http_example.rb against Zapier. See that template for details.
#
# Requires (checked at startup): ruby+bundler, python3 with `flask`, `fastmcp`, `mcp`,
# a real `python` binary on PATH, lsof, curl. npx examples additionally need node/npx.
# LLM examples need the relevant API keys in the environment.

set -uo pipefail

# ---- locate repo root (this script lives in examples/) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---- config ----
PYTHON="${PYTHON:-python3}"
RUN_AI="${RUN_AI:-1}"
RUN_NPX="${RUN_NPX:-1}"
TIMEOUT="${TIMEOUT:-120}"
LOG_DIR="${LOG_DIR:-$(mktemp -d -t mcp-examples-XXXXXX)}"
mkdir -p "$LOG_DIR"

# Load local secrets (gitignored) if present — e.g. ZAPIER_MCP_TOKEN. See
# examples/secrets.env.example for the template.
SECRETS_FILE="$REPO_ROOT/examples/secrets.env"
if [ -f "$SECRETS_FILE" ]; then
  set -a; . "$SECRETS_FILE"; set +a
fi

# canned stdin for the interactive elicitation examples: 200 blank lines.
# Empty input => "invalid choice, decline by default" and text prompts fall back to
# their defaults, so the demo completes without hanging (and never hits EOF/nil).
STDIN_BLANKS="$LOG_DIR/blank_input.txt"
: >"$STDIN_BLANKS"
for _ in $(seq 1 200); do echo >>"$STDIN_BLANKS"; done

# "accept" stdin: drives the elicitation demos down the happy path (accept + real
# values, confirm=true), then pads with blank lines so a miscount can never hit EOF
# (nil.chomp) — it just falls through to defaults/decline. Pass/fail still gates on
# the completion marker, so exact alignment is not required for correctness.
STDIN_ACCEPT="$LOG_DIR/accept_input.txt"
{
  printf 'a\nRelease Test\nCI\n'      # create_document: accept, title, author
  printf 'a\nHello from the runner\n' # create_document: accept, content
  printf 'a\ntrue\ncleanup\n'         # delete_files: accept, confirm=true, reason
  printf 'development\nv1.0.0\n'       # deploy: environment, version
  printf 'a\ntrue\n'                  # deploy: accept, confirm=true
  for _ in $(seq 1 40); do echo; done # padding — never hit EOF
} >"$STDIN_ACCEPT"

# ---- colors ----
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; DIM=$'\033[2m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; DIM=""; N=""
fi

# ---- results accumulator: each entry "STATUS<TAB>name<TAB>reason<TAB>logfile" ----
results=()
add_result() { results+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"); }

section() { printf '\n%s══ %s ══%s\n' "$B" "$1" "$N"; }

# ---- port / server helpers (macOS-friendly: no setsid, use lsof to reap) ----
free_port() {
  local port="$1" pids
  pids="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 1
    pids="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
  fi
}

SERVER_PID=""
SERVER_PORT=""
SERVER_LOG=""
start_server() { # name port logfile  --  cmd...
  local name="$1" port="$2" logfile="$3"; shift 3
  free_port "$port"
  printf '%s  ↻ starting %s (port %s)…%s ' "$DIM" "$name" "$port" "$N"
  "$@" >"$logfile" 2>&1 &
  SERVER_PID=$!
  SERVER_PORT="$port"
  SERVER_LOG="$logfile"
}

wait_ready() { # retries
  # Readiness = the server's TCP port is in LISTEN. We detect that with lsof rather
  # than by issuing an HTTP request, for two reasons:
  #   1. Several servers expose a streaming /sse endpoint that never returns a
  #      completed HTTP response, so an HTTP probe would hang/time out when up.
  #   2. lsof is interface-agnostic: the npx Playwright server binds `localhost`
  #      which resolves to IPv6 ::1 on macOS, so an IPv4 127.0.0.1 probe misses it.
  local tries="${1:-40}" i=0
  while [ "$i" -lt "$tries" ]; do
    if lsof -nP -iTCP:"$SERVER_PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
      sleep 0.7; return 0  # settle briefly, then ready
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then return 1; fi  # server died
    sleep 0.5; i=$((i + 1))
  done
  return 1
}

stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  [ -n "$SERVER_PORT" ] && free_port "$SERVER_PORT"
  SERVER_PID=""; SERVER_PORT=""; SERVER_LOG=""
}

# ---- pass/fail judgement -------------------------------------------------
# Fails on: nonzero exit (incl. timeout=124), a hard error signature (Python
# Traceback, ECONNREFUSED, "server is running" hint, uncaught Ruby error), or a
# missing positive success marker when one is required.
#
# The ❌ glyph is a SOFT signal: most examples print it only on real errors, but
# the interactive elicitation demos also print it as legitimate business content
# ("Deletion not confirmed" when the user declines). Set IGNORE_XMARK=1 for those
# and gate on the completion marker instead.
FAIL_RE_HARD='Traceback \(most recent call|Errno::ECONNREFUSED|ECONNREFUSED|Connection refused|Make sure .*server is running|uninitialized constant|undefined method|NoMethodError|Could not connect|Failed to connect'

judge() { # logfile exit_code success_regex  ->  echoes "PASS" or "FAIL: reason"
  local log="$1" code="$2" success="$3"
  if [ "$code" -eq 124 ]; then echo "FAIL: timed out after ${RUN_TIMEOUT:-$TIMEOUT}s"; return; fi
  if [ "$code" -ne 0 ]; then
    echo "FAIL: exit code $code ($(grep -oE '[A-Za-z0-9_:]+Error|abort:.*' "$log" | head -1))"; return
  fi
  local hit
  hit="$(grep -oE "$FAIL_RE_HARD" "$log" | head -1 || true)"
  if [ -n "$hit" ]; then echo "FAIL: found '$hit' in output"; return; fi
  if [ "${IGNORE_XMARK:-0}" != "1" ] && grep -q '❌' "$log"; then
    echo "FAIL: found '❌' in output"; return
  fi
  if [ -n "$success" ] && ! grep -qE "$success" "$log"; then
    echo "FAIL: expected success marker /$success/ not found"; return
  fi
  echo "PASS"
}

# ---- run one example ----------------------------------------------------
# run_example <name> <success_regex|-> <stdin_file|-> -- <cmd...>
run_example() {
  local name="$1" success="$2" stdin_file="$3"; shift 3
  [ "$1" = "--" ] && shift
  [ "$success" = "-" ] && success=""   # "-" is the "no positive marker" sentinel
  local log="$LOG_DIR/${name//\//__}.log"
  local t="${RUN_TIMEOUT:-$TIMEOUT}"
  printf '  %s▶ %-42s%s ' "$N" "$name" "$N"
  local code
  if [ "$stdin_file" != "-" ]; then
    timeout "$t" "$@" <"$stdin_file" >"$log" 2>&1; code=$?
  else
    timeout "$t" "$@" </dev/null >"$log" 2>&1; code=$?
  fi
  local verdict; verdict="$(judge "$log" "$code" "$success")"
  if [ "$verdict" = "PASS" ]; then
    printf '%s✔ PASS%s\n' "$G" "$N"
    add_result "PASS" "$name" "" "$log"
  else
    printf '%s✘ %s%s\n' "$R" "$verdict" "$N"
    add_result "FAIL" "$name" "${verdict#FAIL: }" "$log"
  fi
}

skip_example() { # name reason
  printf '  %s⤼ %-42s SKIP — %s%s\n' "$Y" "$1" "$2" "$N"
  add_result "SKIP" "$1" "$2" ""
}

# =========================================================================
# Preflight
# =========================================================================
section "Preflight"
missing=0
check() { if "$@" >/dev/null 2>&1; then printf '  %s✔%s %s\n' "$G" "$N" "$*"; else printf '  %s✘%s %s\n' "$R" "$N" "$*"; missing=1; fi; }
check command -v ruby
check command -v bundle
check command -v "$PYTHON"
check command -v python
check command -v curl
check command -v lsof
check "$PYTHON" -c 'import flask'
check "$PYTHON" -c 'import fastmcp'
check "$PYTHON" -c 'import mcp'
if [ "$RUN_NPX" = "1" ]; then check command -v npx; fi
if [ "$missing" = "1" ]; then
  printf '\n%sPreflight found missing prerequisites — some examples will be skipped/fail.%s\n' "$Y" "$N"
fi
printf '\nLogs: %s\n' "$LOG_DIR"

# =========================================================================
# Group A — self-contained stdio (Ruby spawns its own Python server). No secrets.
# =========================================================================
section "Group A · self-contained stdio servers"
# The only example with a real nonzero-exit PASS/FAIL harness — the hard gate.
run_example "test_mcp_2025_11_25.rb" "Results:.*passed|All .*passed" - -- \
  bundle exec ruby examples/test_mcp_2025_11_25.rb
run_example "test_structured_outputs.rb" "Structured outputs demo completed successfully" - -- \
  bundle exec ruby examples/test_structured_outputs.rb
run_example "test_tool_annotations.rb" "Tool annotations demo completed successfully" - -- \
  bundle exec ruby examples/test_tool_annotations.rb
# Interactive over stdio: self-launches its server; feed blank stdin (declines).
run_example "elicitation/test_elicitation.rb" "Document Creation|Notification|declined" "$STDIN_BLANKS" -- \
  bundle exec ruby examples/elicitation/test_elicitation.rb

# =========================================================================
# Group B — external fastmcp SSE server (echo_server.py, port 8000)
# =========================================================================
section "Group B · echo_server.py (SSE, :8000)"
start_server "echo_server.py" 8000 "$LOG_DIR/_server_echo_sse.log" \
  "$PYTHON" examples/echo_server.py
if wait_ready 40; then
  run_example "echo_server_client.rb" "All features tested successfully" - -- \
    bundle exec ruby examples/echo_server_client.rb
else
  skip_example "echo_server_client.rb" "echo_server.py (SSE :8000) did not become ready"
fi
stop_server

# =========================================================================
# Group C — external Flask streamable server (echo_server_streamable.py, :8931)
# =========================================================================
section "Group C · echo_server_streamable.py (Streamable HTTP, :8931)"
start_server "echo_server_streamable.py" 8931 "$LOG_DIR/_server_echo_streamable.log" \
  "$PYTHON" examples/echo_server_streamable.py
if wait_ready 40; then
  run_example "echo_server_streamable_client.rb" "Connected successfully" - -- \
    bundle exec ruby examples/echo_server_streamable_client.rb
  run_example "test_mcp_protocol_features.rb" "Connected successfully" - -- \
    bundle exec ruby examples/test_mcp_protocol_features.rb
  run_example "test_ping_pong.rb" "Test completed" - -- \
    bundle exec ruby examples/test_ping_pong.rb
  # NOTE: streamable_http_example.rb is intentionally NOT run against this local
  # server. It calls the *first advertised tool* with no arguments — which only
  # makes sense for the remote server it targets (Zapier). Against echo_server it
  # correctly raises ValidationError (echo needs `message`). The streamable
  # transport itself is already covered by the two clients above. See Group G.
else
  skip_example "echo_server_streamable_client.rb" "echo_server_streamable.py (:8931) not ready"
  skip_example "test_mcp_protocol_features.rb"    "echo_server_streamable.py (:8931) not ready"
  skip_example "test_ping_pong.rb"                "echo_server_streamable.py (:8931) not ready"
fi
stop_server

# =========================================================================
# Group D — elicitation Flask server (elicitation_streamable_server.py, :8000)
# =========================================================================
section "Group D · elicitation_streamable_server.py (:8000)"
start_server "elicitation_streamable_server.py" 8000 "$LOG_DIR/_server_elicitation.log" \
  "$PYTHON" examples/elicitation/elicitation_streamable_server.py
if wait_ready 40; then
  run_example "elicitation/test_elicitation_sse_simple.rb" "Success" - -- \
    bundle exec ruby examples/elicitation/test_elicitation_sse_simple.rb
  # Interactive: feed accept answers. ❌ can be legitimate content here (a declined
  # confirmation), so tolerate it and gate on the end-of-run "Transport Summary".
  # Pin MCP_SERVER_URL/ENDPOINT to the local server so a value inherited from
  # secrets.env (e.g. an ngrok URL for the OAuth example) can't redirect it.
  IGNORE_XMARK=1 run_example "elicitation/test_elicitation_streamable.rb" "Transport Summary" "$STDIN_ACCEPT" -- \
    env MCP_SERVER_URL=http://localhost:8000 MCP_SERVER_ENDPOINT=/mcp \
    bundle exec ruby examples/elicitation/test_elicitation_streamable.rb
else
  skip_example "elicitation/test_elicitation_sse_simple.rb" "elicitation server (:8000) not ready"
  skip_example "elicitation/test_elicitation_streamable.rb" "elicitation server (:8000) not ready"
fi
stop_server

# =========================================================================
# Group E — npx MCP servers (Playwright :8931 / filesystem stdio)
# =========================================================================
section "Group E · npx-based MCP servers"
if [ "$RUN_NPX" != "1" ] || ! command -v npx >/dev/null 2>&1; then
  skip_example "json_input_mcp_servers_example.rb" "RUN_NPX=0 or npx unavailable"
else
  # json_input uses BOTH a filesystem stdio server (self-launched) and a Playwright
  # MCP server on :8931 (external). Start Playwright, then run.
  start_server "playwright-mcp" 8931 "$LOG_DIR/_server_playwright.log" \
    npx -y @playwright/mcp@latest --port 8931
  if wait_ready 60; then
    RUN_TIMEOUT=300 run_example "json_input_mcp_servers_example.rb" "Connected to MCP servers|tools" - -- \
      bundle exec ruby examples/json_input_mcp_servers_example.rb
  else
    skip_example "json_input_mcp_servers_example.rb" "Playwright MCP (:8931) did not become ready"
  fi
  stop_server
fi

# =========================================================================
# Group F — LLM integration examples (REAL, paid API calls)
# =========================================================================
section "Group F · LLM integrations (real API calls)"
if [ "$RUN_AI" != "1" ]; then
  for e in ruby_anthropic_mcp.rb openai_ruby_mcp.rb ruby_openai_mcp.rb ruby_llm_mcp.rb gemini_ai_mcp.rb; do
    skip_example "$e" "RUN_AI=0"
  done
else
  # F1 — stdio filesystem server (self-launched via npx). Need API keys.
  if [ -n "${ANTHROPIC_API_KEY:-}" ] && command -v npx >/dev/null 2>&1; then
    run_example "ruby_anthropic_mcp.rb" "Tool result received" - -- \
      bundle exec ruby examples/ruby_anthropic_mcp.rb
  else
    skip_example "ruby_anthropic_mcp.rb" "needs ANTHROPIC_API_KEY + npx"
  fi
  if [ -n "${OPENAI_API_KEY:-}" ] && command -v npx >/dev/null 2>&1; then
    run_example "openai_ruby_mcp.rb" - - -- \
      bundle exec ruby examples/openai_ruby_mcp.rb
  else
    skip_example "openai_ruby_mcp.rb" "needs OPENAI_API_KEY + npx"
  fi
  # Vertex/Gemini — needs a real service-account JSON.
  GCREDS="${VERTEX_CREDENTIALS_FILE:-examples/google-credentials.json}"
  if [ -f "$GCREDS" ] && command -v npx >/dev/null 2>&1; then
    run_example "gemini_ai_mcp.rb" "Tool executed successfully|Final response" - -- \
      env VERTEX_CREDENTIALS_FILE="$GCREDS" \
      bundle exec ruby examples/gemini_ai_mcp.rb
  else
    skip_example "gemini_ai_mcp.rb" "needs VERTEX_CREDENTIALS_FILE (service account) + npx"
  fi

  # F2 — need an external Playwright MCP server on :8931.
  if [ -n "${OPENAI_API_KEY:-}" ] && command -v npx >/dev/null 2>&1; then
    start_server "playwright-mcp" 8931 "$LOG_DIR/_server_playwright2.log" \
      npx -y @playwright/mcp@latest --port 8931
    if wait_ready 60; then
      RUN_TIMEOUT=240 run_example "ruby_openai_mcp.rb" - - -- \
        bundle exec ruby examples/ruby_openai_mcp.rb
      RUN_TIMEOUT=240 run_example "ruby_llm_mcp.rb" "Assistant:" - -- \
        bundle exec ruby examples/ruby_llm_mcp.rb
    else
      skip_example "ruby_openai_mcp.rb" "Playwright MCP (:8931) not ready"
      skip_example "ruby_llm_mcp.rb"    "Playwright MCP (:8931) not ready"
    fi
    stop_server
  else
    skip_example "ruby_openai_mcp.rb" "needs OPENAI_API_KEY + npx + Playwright"
    skip_example "ruby_llm_mcp.rb"    "needs OPENAI_API_KEY + npx + Playwright"
  fi
fi

# =========================================================================
# Group G — require real external services / interactive browser (not headless)
# =========================================================================
section "Group G · real remote services / interactive"
# streamable_http_example.rb → Zapier MCP. Runs for real when ZAPIER_MCP_TOKEN is
# set (in examples/secrets.env); sent as `Authorization: Bearer <token>`.
if [ -n "${ZAPIER_MCP_TOKEN:-}" ]; then
  ZAPIER_URL="${ZAPIER_MCP_URL:-https://mcp.zapier.com/api/v1/connect}"
  run_example "streamable_http_example.rb (→ Zapier)" "Example completed successfully" - -- \
    env MCP_SERVER_URL="$ZAPIER_URL" MCP_BEARER_TOKEN="$ZAPIER_MCP_TOKEN" \
    bundle exec ruby examples/streamable_http_example.rb
else
  skip_example "streamable_http_example.rb" "set ZAPIER_MCP_TOKEN in examples/secrets.env to run against Zapier (Authorization: Bearer). Transport also verified locally by echo_server_streamable_client.rb + test_mcp_protocol_features.rb"
fi
# tasks_example.rb → Zapier MCP. Zapier does not (yet) implement the
# experimental 2025-11-25 tasks capability, so against it the example
# demonstrates the client's capability-aware degradation (TaskError /
# CapabilityError) rather than a full task lifecycle.
if [ -n "${ZAPIER_MCP_TOKEN:-}" ]; then
  ZAPIER_URL="${ZAPIER_MCP_URL:-https://mcp.zapier.com/api/v1/connect}"
  run_example "tasks_example.rb (→ Zapier)" "Tasks example completed" - -- \
    env MCP_SERVER_URL="$ZAPIER_URL" MCP_BEARER_TOKEN="$ZAPIER_MCP_TOKEN" \
    bundle exec ruby examples/tasks_example.rb
else
  skip_example "tasks_example.rb" "set ZAPIER_MCP_TOKEN in examples/secrets.env to run against Zapier; a full task lifecycle additionally needs a task-capable server (MCP_SERVER_URL)"
fi

# oauth_example.rb → walks the OAuth API; connects to Zapier for real when
# ZAPIER_MCP_TOKEN is set (Authorization: Bearer), otherwise stays illustrative.
if [ -n "${ZAPIER_MCP_TOKEN:-}" ]; then
  run_example "oauth_example.rb (→ Zapier)" "Connected to Zapier MCP" - -- \
    bundle exec ruby examples/oauth_example.rb
else
  skip_example "oauth_example.rb" "set ZAPIER_MCP_TOKEN in examples/secrets.env to connect to Zapier; otherwise illustrative only"
fi

# oauth_browser_auth.rb → full interactive browser OAuth: opens a browser and waits
# for a human to authorize, so it is OFF by default. Set RUN_OAUTH=1 (and provide
# MCP_SERVER_URL, e.g. in examples/secrets.env) to run it, with a generous timeout
# for the manual step.
if [ "${RUN_OAUTH:-0}" = "1" ] && [ -n "${MCP_SERVER_URL:-}" ]; then
  RUN_TIMEOUT=300 run_example "oauth_browser_auth.rb" "Successfully connected to MCP server" - -- \
    bundle exec ruby examples/oauth_browser_auth.rb
else
  skip_example "oauth_browser_auth.rb" "interactive browser OAuth; set RUN_OAUTH=1 and MCP_SERVER_URL (e.g. in examples/secrets.env) to run it"
fi

# =========================================================================
# Summary
# =========================================================================
section "Summary"
pass=0; fail=0; skip=0
printf '%s\n' "$DIM$(printf '%.0s─' {1..64})$N"
for row in "${results[@]}"; do
  IFS=$'\t' read -r status name reason _log <<<"$row"
  case "$status" in
    PASS) printf '  %s✔ PASS%s  %s\n' "$G" "$N" "$name"; pass=$((pass+1));;
    FAIL) printf '  %s✘ FAIL%s  %-44s %s%s%s\n' "$R" "$N" "$name" "$DIM" "$reason" "$N"; fail=$((fail+1));;
    SKIP) printf '  %s⤼ SKIP%s  %-44s %s%s%s\n' "$Y" "$N" "$name" "$DIM" "$reason" "$N"; skip=$((skip+1));;
  esac
done
printf '%s\n' "$DIM$(printf '%.0s─' {1..64})$N"
printf '  %sPASS %d%s   %sFAIL %d%s   %sSKIP %d%s   (of %d)\n' \
  "$G" "$pass" "$N" "$R" "$fail" "$N" "$Y" "$skip" "$N" "${#results[@]}"
printf '  Logs: %s\n\n' "$LOG_DIR"

[ "$fail" -eq 0 ]
