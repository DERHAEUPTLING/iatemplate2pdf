#!/usr/bin/env node

// MCP server tests for iatemplate2pdf
// Usage: node mcp/test.js

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { mkdtempSync, writeFileSync, existsSync, statSync, readdirSync, mkdirSync, readFileSync, renameSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir, homedir } from "node:os";

const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const NC = "\x1b[0m";

let passed = 0;
let failed = 0;

function pass(msg) { passed++; console.log(`${GREEN}✓${NC} ${msg}`); }
function fail(msg, detail) { failed++; console.log(`${RED}✗${NC} ${msg}: ${detail}`); }

const tmp = mkdtempSync(join(tmpdir(), "mcp-test-"));
const serverPath = new URL("./server.js", import.meta.url).pathname;

// Find first available template for tests
function findFirstTemplate() {
  const home = homedir();
  const searchPaths = [
    join(home, "Library/Containers/pro.writer.mac/Data/Library/Application Support/iA Writer/Templates"),
    join(home, "Library/Application Support/iA Writer/Templates"),
    "/Library/Application Support/iA Writer/Templates",
  ];
  for (const dir of searchPaths) {
    let items;
    try { items = readdirSync(dir); } catch { continue; }
    for (const item of items) {
      if (!item.endsWith(".iatemplate")) continue;
      const fullPath = join(dir, item);
      if (existsSync(join(fullPath, "Contents/Info.plist"))) return fullPath;
    }
  }
  return null;
}

const TEST_TEMPLATE = findFirstTemplate();
const TEST_AUTHOR = "Test Author";

// Backup config before tests, restore after
const configPath = join(homedir(), ".config", "iatemplate2pdf", "config.json");
let configBackup = null;
try { configBackup = readFileSync(configPath, "utf-8"); } catch {}

console.log("");
console.log("Running MCP tests...");
if (TEST_TEMPLATE) console.log(`Using template: ${TEST_TEMPLATE}`);
console.log("");

const transport = new StdioClientTransport({
  command: "node",
  args: [serverPath],
});

const client = new Client({ name: "test-client", version: "1.0.0" });

try {
  // Test 1: Connect and initialize
  await client.connect(transport);
  pass("Server connects and initializes");

  // Test 2: List tools
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "iatemplate2pdf");
  if (tool) {
    pass("Tool 'iatemplate2pdf' is registered");
  } else {
    fail("Tool listing", `Found: ${tools.map((t) => t.name).join(", ")}`);
  }

  // Test 3: Convert single file (with explicit template + author)
  const mdPath = join(tmp, "test.md");
  const pdfPath = join(tmp, "test.pdf");
  writeFileSync(mdPath, "# Test\n\nHello from MCP.\n");

  const result1 = await client.callTool({
    name: "iatemplate2pdf",
    arguments: { files: [mdPath], template: TEST_TEMPLATE, author: TEST_AUTHOR },
  });
  if (existsSync(pdfPath) && statSync(pdfPath).size > 0) {
    pass("Single file conversion via MCP");
  } else {
    const text = result1.content?.[0]?.text || "no output";
    fail("Single file conversion", text);
  }

  // Test 4: Batch conversion with output-dir
  const outDir = join(tmp, "batch-out");
  const md1 = join(tmp, "batch1.md");
  const md2 = join(tmp, "batch2.md");
  writeFileSync(md1, "# Batch 1\n\nFirst file.\n");
  writeFileSync(md2, "# Batch 2\n\nSecond file.\n");

  await client.callTool({
    name: "iatemplate2pdf",
    arguments: { files: [md1, md2], output_dir: outDir, template: TEST_TEMPLATE, author: TEST_AUTHOR },
  });
  const pdf1 = join(outDir, "batch1.pdf");
  const pdf2 = join(outDir, "batch2.pdf");
  if (existsSync(pdf1) && existsSync(pdf2)) {
    pass("Batch conversion via MCP (2 files)");
  } else {
    fail("Batch conversion", "Not all PDFs created");
  }

  // Test 5: Missing config returns helpful message (not an error)
  // Temporarily remove config to test the interactive flow
  try { renameSync(configPath, configPath + ".bak"); } catch {}
  const noConfigResult = await client.callTool({
    name: "iatemplate2pdf",
    arguments: { files: [mdPath] },
  });
  const noConfigText = noConfigResult.content?.[0]?.text || "";
  if (noConfigText.includes("Available templates") || noConfigText.includes("ask the user")) {
    pass("Missing config returns template list for LLM");
  } else {
    fail("Missing config", noConfigText);
  }
  // Restore config
  try { renameSync(configPath + ".bak", configPath); } catch {}

  // Test 6: Non-existent file
  const result3 = await client.callTool({
    name: "iatemplate2pdf",
    arguments: { files: ["/nonexistent/file.md"] },
  });
  const errText = result3.content?.[0]?.text || "";
  if (errText.includes("Error")) {
    pass("Non-existent file returns error");
  } else {
    fail("Non-existent file", "Expected error message");
  }

  // Test 6: Empty file list
  const result4 = await client.callTool({
    name: "iatemplate2pdf",
    arguments: { files: [] },
  });
  const errText2 = result4.content?.[0]?.text || "";
  if (errText2.includes("Error")) {
    pass("Empty file list returns error");
  } else {
    fail("Empty file list", "Expected error message");
  }

  // --- Local test files (./tests/*.md) ---
  const testsDir = resolve(new URL("../tests", import.meta.url).pathname);

  let localFiles = [];
  try {
    localFiles = readdirSync(testsDir).filter((f) => f.endsWith(".md"));
  } catch {}

  if (localFiles.length > 0) {
    console.log("");
    console.log(`Found ${localFiles.length} local test files in tests/`);
    console.log("");

    const mcpOutDir = join(testsDir, "output", "mcp");
    mkdirSync(mcpOutDir, { recursive: true });

    // Single file conversion for each
    for (const file of localFiles) {
      const mdPath = join(testsDir, file);
      const pdfName = file.replace(/\.md$/, ".pdf");
      const pdfPath = join(mcpOutDir, pdfName);

      await client.callTool({
        name: "iatemplate2pdf",
        arguments: { files: [mdPath], output_dir: mcpOutDir },
      });

      if (existsSync(pdfPath) && statSync(pdfPath).size > 0) {
        pass(`Local file via MCP: ${file} → PDF`);
      } else {
        fail(`Local file via MCP: ${file}`, "PDF not created");
      }
    }

    // Batch conversion of all local files
    const batchOutDir = join(testsDir, "output", "mcp-batch");
    mkdirSync(batchOutDir, { recursive: true });

    const allPaths = localFiles.map((f) => join(testsDir, f));
    await client.callTool({
      name: "iatemplate2pdf",
      arguments: { files: allPaths, output_dir: batchOutDir },
    });

    const batchPdfs = readdirSync(batchOutDir).filter((f) => f.endsWith(".pdf"));
    if (batchPdfs.length === localFiles.length) {
      pass(`Local batch via MCP: ${localFiles.length} files → ${batchPdfs.length} PDFs`);
    } else {
      fail("Local batch via MCP", `Expected ${localFiles.length}, got ${batchPdfs.length}`);
    }

    console.log("");
    console.log(`PDFs written to tests/output/mcp/`);
  }

} catch (e) {
  fail("Unexpected error", e.message);
} finally {
  await client.close();
}

// Summary
console.log("");
const total = passed + failed;
console.log(`Results: ${passed}/${total} passed`);
if (failed > 0) {
  console.log(`${RED}${failed} test(s) failed${NC}`);
  process.exit(1);
} else {
  console.log(`${GREEN}All tests passed${NC}`);
}
