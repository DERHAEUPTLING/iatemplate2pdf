#!/bin/bash
# CLI tests for iatemplate2pdf
# Usage: ./scripts/test-cli.sh [--build]

set -euo pipefail

BINARY=".build/release/iatemplate2pdf"
TMPDIR=$(mktemp -d)
PASSED=0
FAILED=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { ((PASSED++)); echo -e "${GREEN}✓${NC} $1"; }
fail() { ((FAILED++)); echo -e "${RED}✗${NC} $1: $2"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Build if requested
if [[ "${1:-}" == "--build" ]]; then
  echo "Building..."
  swift build -c release 2>&1 | tail -1
fi

if [[ ! -x "$BINARY" ]]; then
  echo "Binary not found. Run: swift build -c release"
  exit 1
fi

echo ""
echo "Running CLI tests..."
echo ""

# --- Create test fixtures ---

cat > "$TMPDIR/simple.md" << 'EOF'
# Hello World

This is a simple test document.

- Item 1
- Item 2
- Item 3
EOF

cat > "$TMPDIR/table.md" << 'EOF'
# GFM Table Test

| Name | Value |
|------|-------|
| Foo  | 42    |
| Bar  | 99    |

## Strikethrough

This is ~~deleted~~ text.

## Tasklist

- [x] Done
- [ ] Not done
EOF

cat > "$TMPDIR/unicode.md" << 'EOF'
# Unicode Test

Umlaute: äöüÄÖÜß
Sonderzeichen: ♡ → ★ · —
Anführungszeichen: „deutsch" und "english"
EOF

cat > "$TMPDIR/long.md" << 'EOF'
# Long Document

This document should produce multiple pages.

EOF

# Generate enough content for multiple pages
for i in $(seq 1 80); do
  echo "Paragraph $i: Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris." >> "$TMPDIR/long.md"
  echo "" >> "$TMPDIR/long.md"
done

# --- Tests ---

# Test 1: Help flag
if $BINARY --help 2>&1 | grep -q "Usage:"; then
  pass "Help flag shows usage"
else
  fail "Help flag" "No usage output"
fi

# Test 2: Single file conversion
if $BINARY "$TMPDIR/simple.md" 2>/dev/null; then
  if [[ -f "$TMPDIR/simple.pdf" && $(stat -f%z "$TMPDIR/simple.pdf") -gt 0 ]]; then
    pass "Single file conversion produces PDF"
  else
    fail "Single file conversion" "PDF not created or empty"
  fi
else
  fail "Single file conversion" "Command failed"
fi

# Test 3: Explicit output path
if $BINARY "$TMPDIR/simple.md" "$TMPDIR/custom-output.pdf" 2>/dev/null; then
  if [[ -f "$TMPDIR/custom-output.pdf" ]]; then
    pass "Explicit output path"
  else
    fail "Explicit output path" "PDF not at expected path"
  fi
else
  fail "Explicit output path" "Command failed"
fi

# Test 4: GFM extensions (tables, strikethrough, tasklist)
if $BINARY "$TMPDIR/table.md" 2>/dev/null; then
  if [[ -f "$TMPDIR/table.pdf" && $(stat -f%z "$TMPDIR/table.pdf") -gt 0 ]]; then
    pass "GFM extensions (table, strikethrough, tasklist)"
  else
    fail "GFM extensions" "PDF not created or empty"
  fi
else
  fail "GFM extensions" "Command failed"
fi

# Test 5: Unicode support
if $BINARY "$TMPDIR/unicode.md" 2>/dev/null; then
  if [[ -f "$TMPDIR/unicode.pdf" && $(stat -f%z "$TMPDIR/unicode.pdf") -gt 0 ]]; then
    pass "Unicode support (umlauts, special chars)"
  else
    fail "Unicode support" "PDF not created or empty"
  fi
else
  fail "Unicode support" "Command failed"
fi

# Test 6: Multi-page document
if $BINARY "$TMPDIR/long.md" 2>/dev/null; then
  if [[ -f "$TMPDIR/long.pdf" && $(stat -f%z "$TMPDIR/long.pdf") -gt 1000 ]]; then
    pass "Multi-page document"
  else
    fail "Multi-page document" "PDF too small or not created"
  fi
else
  fail "Multi-page document" "Command failed"
fi

# Test 7: Batch conversion with --output-dir
mkdir -p "$TMPDIR/batch-out"
if $BINARY "$TMPDIR/simple.md" "$TMPDIR/table.md" "$TMPDIR/unicode.md" --output-dir "$TMPDIR/batch-out" 2>/dev/null; then
  COUNT=$(ls "$TMPDIR/batch-out"/*.pdf 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$COUNT" == "3" ]]; then
    pass "Batch conversion (3 files → 3 PDFs)"
  else
    fail "Batch conversion" "Expected 3 PDFs, got $COUNT"
  fi
else
  fail "Batch conversion" "Command failed"
fi

# Test 8: Custom title
if $BINARY "$TMPDIR/simple.md" "$TMPDIR/titled.pdf" --title "Custom Title" 2>/dev/null; then
  if [[ -f "$TMPDIR/titled.pdf" ]]; then
    pass "Custom title flag"
  else
    fail "Custom title" "PDF not created"
  fi
else
  fail "Custom title" "Command failed"
fi

# Test 9: Non-existent input file
if $BINARY "$TMPDIR/does-not-exist.md" 2>/dev/null; then
  fail "Non-existent file" "Should have failed"
else
  pass "Non-existent file returns error"
fi

# Test 10: No arguments
if $BINARY 2>/dev/null; then
  fail "No arguments" "Should have failed"
else
  pass "No arguments returns error"
fi

# Test 11: --list-templates
LIST_OUTPUT=$($BINARY --list-templates 2>&1 || true)
if echo "$LIST_OUTPUT" | grep -q "Available templates"; then
  pass "--list-templates shows templates"
else
  fail "--list-templates" "No template listing"
fi

# Test 12: --setup (non-interactive, pipe choice)
# Backup and restore config
CONFIG_DIR="$HOME/.config/iatemplate2pdf"
CONFIG_BAK="$TMPDIR/config-backup.json"
if [[ -f "$CONFIG_DIR/config.json" ]]; then
  cp "$CONFIG_DIR/config.json" "$CONFIG_BAK"
fi
# Remove config to trigger setup
rm -f "$CONFIG_DIR/config.json" 2>/dev/null
if echo "1" | $BINARY --setup 2>&1 | grep -q "Default template set to:"; then
  if [[ -f "$CONFIG_DIR/config.json" ]]; then
    pass "--setup saves config"
  else
    fail "--setup" "Config not saved"
  fi
else
  fail "--setup" "Setup did not complete"
fi
# Restore original config
if [[ -f "$CONFIG_BAK" ]]; then
  cp "$CONFIG_BAK" "$CONFIG_DIR/config.json"
fi

# --- Local test files (./tests/*.md) ---

TESTS_DIR="./tests"
if compgen -G "$TESTS_DIR/*.md" > /dev/null 2>&1; then
  echo ""
  echo "Found local test files in $TESTS_DIR/"
  echo ""

  TESTS_OUT="$TESTS_DIR/output/cli"
  rm -rf "$TESTS_DIR/output"
  mkdir -p "$TESTS_OUT"

  # Single file conversion for each
  for md in "$TESTS_DIR"/*.md; do
    NAME=$(basename "$md" .md)
    if $BINARY "$md" "$TESTS_OUT/$NAME.pdf" 2>/dev/null; then
      if [[ -f "$TESTS_OUT/$NAME.pdf" && $(stat -f%z "$TESTS_OUT/$NAME.pdf") -gt 0 ]]; then
        pass "Local file: $NAME.md → PDF"
      else
        fail "Local file: $NAME.md" "PDF empty or not created"
      fi
    else
      fail "Local file: $NAME.md" "Conversion failed"
    fi
  done

  # Batch conversion of all local files
  MD_COUNT=$(ls "$TESTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
  BATCH_OUT="$TESTS_DIR/output/cli-batch"
  mkdir -p "$BATCH_OUT"
  if $BINARY "$TESTS_DIR"/*.md --output-dir "$BATCH_OUT" 2>/dev/null; then
    PDF_COUNT=$(ls "$BATCH_OUT"/*.pdf 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$PDF_COUNT" == "$MD_COUNT" ]]; then
      pass "Local batch: $MD_COUNT files → $PDF_COUNT PDFs"
    else
      fail "Local batch" "Expected $MD_COUNT PDFs, got $PDF_COUNT"
    fi
  else
    fail "Local batch" "Batch conversion failed"
  fi

  echo ""
  echo "PDFs written to $TESTS_DIR/output/"
else
  echo ""
  echo "(No local test files in $TESTS_DIR/ — skipping)"
fi

# --- Summary ---
echo ""
TOTAL=$((PASSED + FAILED))
echo "Results: $PASSED/$TOTAL passed"
if [[ $FAILED -gt 0 ]]; then
  echo -e "${RED}$FAILED test(s) failed${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed${NC}"
fi
