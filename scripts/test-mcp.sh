#!/bin/bash
# MCP server tests for iatemplate2pdf (native Swift server)
# Usage: ./scripts/test-mcp.sh

set -euo pipefail

BINARY=".build/debug/iatemplate2pdf"
TMPDIR=$(mktemp -d)
PASSED=0
FAILED=0

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { ((PASSED++)); echo -e "${GREEN}✓${NC} $1"; }
fail() { ((FAILED++)); echo -e "${RED}✗${NC} $1: $2"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

if [[ ! -x "$BINARY" ]]; then
  echo "Binary not found. Run: swift build"
  exit 1
fi

# Helper: send JSON-RPC messages to the MCP server and capture stdout
# Uses a subshell with sleep to keep stdin open while the server processes
mcp_call() {
  local messages="$1"
  local wait_secs="${2:-5}"
  (echo "$messages"; sleep "$wait_secs") | $BINARY mcp-server 2>/dev/null
}

# Init messages (sent before every test group)
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo ""
echo "Running MCP server tests..."
echo ""

# Test 1: Initialize
RESP=$(mcp_call "$INIT" 2)
if echo "$RESP" | grep -q '"serverInfo"'; then
  pass "Server connects and initializes"
else
  fail "Initialize" "No serverInfo in response"
fi

# Test 2: List tools
RESP=$(mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}" 2)
if echo "$RESP" | grep -q '"iatemplate2pdf"'; then
  pass "Tool 'iatemplate2pdf' is registered"
else
  fail "Tool listing" "Tool not found"
fi

# Test 3: Non-existent file returns error
RESP=$(mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[\"/nonexistent/file.md\"]}}}" 3)
if echo "$RESP" | grep -q "Error"; then
  pass "Non-existent file returns error"
else
  fail "Non-existent file" "No error in response"
fi

# Test 4: Empty file list returns error
RESP=$(mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[]}}}" 3)
if echo "$RESP" | grep -q "Error"; then
  pass "Empty file list returns error"
else
  fail "Empty file list" "No error in response"
fi

# Test 5: Single file conversion
MD="$TMPDIR/test.md"
echo -e "# Test\n\nHello from MCP." > "$MD"
mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[\"$MD\"]}}}" 10 > /dev/null
PDF="$TMPDIR/test.pdf"
if [[ -f "$PDF" && -s "$PDF" ]]; then
  pass "Single file conversion via MCP"
else
  fail "Single file conversion" "PDF not created"
fi

# Test 6: Batch conversion with output-dir
MD1="$TMPDIR/batch1.md"
MD2="$TMPDIR/batch2.md"
OUTDIR="$TMPDIR/batch-out"
echo -e "# Batch 1\n\nFirst." > "$MD1"
echo -e "# Batch 2\n\nSecond." > "$MD2"
mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[\"$MD1\",\"$MD2\"],\"output_dir\":\"$OUTDIR\"}}}" 15 > /dev/null
if [[ -f "$OUTDIR/batch1.pdf" && -f "$OUTDIR/batch2.pdf" ]]; then
  pass "Batch conversion via MCP (2 files)"
else
  fail "Batch conversion" "Not all PDFs created"
fi

# Test 7: Local test files
TESTS_DIR="./tests"
if [[ -d "$TESTS_DIR" ]]; then
  MCPOUT="$(cd "$TESTS_DIR" && pwd)/output/mcp"
  mkdir -p "$MCPOUT"
  LOCAL_FILES=$(find "$TESTS_DIR" -maxdepth 1 -name "*.md" | sort)
  FILE_COUNT=$(echo "$LOCAL_FILES" | wc -l | tr -d ' ')

  if [[ $FILE_COUNT -gt 0 ]]; then
    echo ""
    echo "Found $FILE_COUNT local test files in tests/"
    echo ""

    for md in $LOCAL_FILES; do
      NAME=$(basename "${md%.md}")
      ABSPATH="$(cd "$(dirname "$md")" && pwd)/$(basename "$md")"
      mcp_call "$INIT
{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"tools/call\",\"params\":{\"name\":\"iatemplate2pdf\",\"arguments\":{\"files\":[\"$ABSPATH\"],\"output_dir\":\"$MCPOUT\"}}}" 10 > /dev/null
      if [[ -f "$MCPOUT/$NAME.pdf" && -s "$MCPOUT/$NAME.pdf" ]]; then
        pass "Local file via MCP: $(basename "$md") → PDF"
      else
        fail "Local file via MCP: $(basename "$md")" "PDF not created"
      fi
    done

    echo ""
    echo "PDFs written to tests/output/mcp/"
  fi
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
