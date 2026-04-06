#!/bin/bash
# MCP server tests for iatemplate2pdf (native Swift server)
# Usage: ./scripts/test-mcp.sh

set -euo pipefail

BINARY=".build/debug/iatemplate2pdf"
TMPDIR=$(mktemp -d)
PASSED=0
FAILED=0
TIMEOUT=10  # Max seconds per MCP call

GREEN='\033[0;32m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m'

pass() { ((PASSED++)); echo -e "${GREEN}✓${NC} $1"; }
fail() { ((FAILED++)); echo -e "${RED}✗${NC} $1: $2"; }
info() { echo -e "${GRAY}  → $1${NC}"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

if [[ ! -x "$BINARY" ]]; then
  echo "Binary not found. Run: swift build"
  exit 1
fi

# Helper: send JSON-RPC to MCP server, capture stdout.
# The MCP server doesn't exit when stdin closes (SDK keeps waiting),
# so we poll the output for the expected number of responses and then kill.
mcp_call() {
  local messages="$1"
  local expected_responses="${2:-1}"
  local max_secs="${3:-$TIMEOUT}"
  local infile="$TMPDIR/.mcp_input"
  local outfile="$TMPDIR/.mcp_output"
  echo "$messages" > "$infile"
  > "$outfile"

  $BINARY mcp-server < "$infile" > "$outfile" 2>/dev/null &
  local pid=$!

  # Poll until we have enough response lines or timeout
  # Each iteration waits 0.5s, so max_iterations = max_secs * 2
  local max_iter=$(( max_secs * 2 ))
  local i=0
  while [[ $i -lt $max_iter ]]; do
    local lines
    lines=$(grep -c '"jsonrpc"' "$outfile" 2>/dev/null || true)
    if [[ "$lines" -ge "$expected_responses" ]]; then
      break
    fi
    sleep 0.5
    (( i++ )) || true
  done

  kill $pid 2>/dev/null
  wait $pid 2>/dev/null || true
  cat "$outfile"
}

# Init messages (sent before every test)
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo ""
echo "Running MCP server tests..."
echo ""

# Test 1: Initialize
info "Sending initialize..."
RESP=$(mcp_call "$INIT" 1)
if echo "$RESP" | grep -q '"serverInfo"'; then
  pass "Server connects and initializes"
else
  fail "Initialize" "No serverInfo in response"
  echo "$RESP"
fi

# Test 2: List tools
info "Requesting tools/list..."
RESP=$(mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}" 2)
if echo "$RESP" | grep -q '"iatemplate2pdf"'; then
  pass "Tool 'iatemplate2pdf' is registered"
else
  fail "Tool listing" "Tool not found"
  echo "$RESP"
fi

# Test 3: Non-existent file returns error
info "Calling with non-existent file..."
RESP=$(mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[\"/nonexistent/file.md\"]}}}" 2)
if echo "$RESP" | grep -q "Error"; then
  pass "Non-existent file returns error"
else
  fail "Non-existent file" "No error in response"
  echo "$RESP"
fi

# Test 4: Empty file list returns error
info "Calling with empty file list..."
RESP=$(mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[]}}}" 2)
if echo "$RESP" | grep -q "Error"; then
  pass "Empty file list returns error"
else
  fail "Empty file list" "No error in response"
  echo "$RESP"
fi

# Test 5: Single file conversion
MD="$TMPDIR/test.md"
echo -e "# Test\n\nHello from MCP." > "$MD"
info "Converting single file..."
RESP=$(mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[\"$MD\"]}}}" 2)
PDF="$TMPDIR/test.pdf"
if [[ -f "$PDF" && -s "$PDF" ]]; then
  pass "Single file conversion via MCP"
else
  fail "Single file conversion" "PDF not created"
  echo "$RESP"
fi

# Test 6: Batch conversion with output-dir
MD1="$TMPDIR/batch1.md"
MD2="$TMPDIR/batch2.md"
OUTDIR="$TMPDIR/batch-out"
echo -e "# Batch 1\n\nFirst." > "$MD1"
echo -e "# Batch 2\n\nSecond." > "$MD2"
info "Converting batch (2 files)..."
RESP=$(mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[\"$MD1\",\"$MD2\"],\"output_dir\":\"$OUTDIR\"}}}" 2 20)
if [[ -f "$OUTDIR/batch1.pdf" && -f "$OUTDIR/batch2.pdf" ]]; then
  pass "Batch conversion via MCP (2 files)"
else
  fail "Batch conversion" "Not all PDFs created"
  echo "$RESP"
fi

# Test 7+: Local test files
TESTS_DIR="./tests"
if [[ -d "$TESTS_DIR" ]] && compgen -G "$TESTS_DIR/*.md" > /dev/null 2>&1; then
  MCPOUT="$(cd "$TESTS_DIR" && pwd)/output/mcp"
  MCPBATCH="$(cd "$TESTS_DIR" && pwd)/output/mcp-batch"
  mkdir -p "$MCPOUT" "$MCPBATCH"

  # Collect file paths
  FILE_COUNT=0
  FILE_LIST_JSON=""
  while IFS= read -r -d '' md; do
    ((FILE_COUNT++))
    ABSPATH="$(cd "$(dirname "$md")" && pwd)/$(basename "$md")"
    NAME=$(basename "${md%.md}")

    # Build JSON array for batch test
    if [[ -n "$FILE_LIST_JSON" ]]; then FILE_LIST_JSON+=","; fi
    FILE_LIST_JSON+="\"$ABSPATH\""

    # Single file conversion
    info "Converting $NAME.md..."
    mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[\"$ABSPATH\"],\"output_dir\":\"$MCPOUT\"}}}" 2 > /dev/null
    if [[ -f "$MCPOUT/$NAME.pdf" && -s "$MCPOUT/$NAME.pdf" ]]; then
      pass "Local file via MCP: $(basename "$md") → PDF"
    else
      fail "Local file via MCP: $(basename "$md")" "PDF not created"
    fi
  done < <(find "$TESTS_DIR" -maxdepth 1 -name "*.md" -print0 | sort -z)

  # Batch conversion of all local files
  echo ""
  info "Batch converting $FILE_COUNT files..."
  mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":101,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[$FILE_LIST_JSON],\"output_dir\":\"$MCPBATCH\"}}}" 2 30 > /dev/null
  PDF_COUNT=$(find "$MCPBATCH" -name "*.pdf" | wc -l | tr -d ' ')
  if [[ "$PDF_COUNT" == "$FILE_COUNT" ]]; then
    pass "Local batch: $FILE_COUNT files → $PDF_COUNT PDFs"
  else
    fail "Local batch" "Expected $FILE_COUNT PDFs, got $PDF_COUNT"
  fi

  echo ""
  echo "PDFs written to tests/output/"
fi

# Summary
echo ""
TOTAL=$((PASSED + FAILED))
echo "Results: $PASSED/$TOTAL passed"
if [[ $FAILED -gt 0 ]]; then
  echo -e "${RED}${FAILED} test(s) failed${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed${NC}"
fi
