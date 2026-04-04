#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { homedir } from "node:os";

const execFileAsync = promisify(execFile);

// Find the binary — check common locations
function findBinary() {
  const candidates = [
    // Same repo (development)
    resolve(dirname(new URL(import.meta.url).pathname), "../.build/release/iatemplate2pdf"),
    // Homebrew
    "/opt/homebrew/bin/iatemplate2pdf",
    "/usr/local/bin/iatemplate2pdf",
  ];
  for (const path of candidates) {
    if (existsSync(path)) return path;
  }
  return "iatemplate2pdf"; // fallback to PATH
}

const BINARY = findBinary();

// Read config.json
function loadConfig() {
  const configPath = join(homedir(), ".config", "iatemplate2pdf", "config.json");
  try {
    return JSON.parse(readFileSync(configPath, "utf-8"));
  } catch {
    return {};
  }
}

// Find available iA Writer templates
function findTemplates() {
  const home = homedir();
  const searchPaths = [
    join(home, "Library/Containers/pro.writer.mac/Data/Library/Application Support/iA Writer/Templates"),
    join(home, "Library/Application Support/iA Writer/Templates"),
    "/Library/Application Support/iA Writer/Templates",
  ];

  const results = [];
  for (const dir of searchPaths) {
    let items;
    try { items = readdirSync(dir); } catch { continue; }
    for (const item of items) {
      if (!item.endsWith(".iatemplate")) continue;
      const fullPath = join(dir, item);
      const plist = join(fullPath, "Contents/Info.plist");
      if (existsSync(plist)) {
        results.push({ name: item.replace(/\.iatemplate$/, ""), path: fullPath });
      }
    }
  }

  // Deduplicate by name (prefer first found)
  const seen = new Set();
  return results.filter((t) => {
    if (seen.has(t.name)) return false;
    seen.add(t.name);
    return true;
  });
}

const server = new McpServer({
  name: "iatemplate2pdf",
  version: "1.0.0",
});

server.tool(
  "iatemplate2pdf",
  "Convert one or more Markdown files to PDF using an iA Writer template. " +
  "Produces PDFs with headers, footers, page numbers, and custom typography — " +
  "identical to iA Writer's native PDF export.",
  {
    files: z.array(z.string()).describe(
      "Absolute paths to Markdown files to convert"
    ),
    output_dir: z.string().optional().describe(
      "Output directory for the PDFs. If omitted, PDFs are placed next to the source files."
    ),
    template: z.string().optional().describe(
      "Path to an .iatemplate bundle. If omitted, uses the configured default template."
    ),
    title: z.string().optional().describe(
      "Document title (used in header). Only applies when converting a single file. If omitted, the first H1 heading from the Markdown is used."
    ),
    author: z.string().optional().describe(
      "Author name. If omitted, uses the configured default author."
    ),
  },
  async ({ files, output_dir, template, title, author }) => {
    if (!files || files.length === 0) {
      return { content: [{ type: "text", text: "Error: No files provided" }] };
    }

    // Validate all files exist
    const missing = files.filter((f) => !existsSync(f));
    if (missing.length > 0) {
      return {
        content: [{ type: "text", text: `Error: Files not found:\n${missing.join("\n")}` }],
      };
    }

    // Resolve template: parameter > config > ask user
    const config = loadConfig();

    if (!template) {
      const savedTemplate = config.defaultTemplate;
      if (savedTemplate && existsSync(savedTemplate)) {
        template = savedTemplate;
      } else {
        // No template configured — list available ones for the LLM to ask the user
        const templates = findTemplates();
        if (templates.length === 0) {
          return {
            content: [{ type: "text", text: "Error: No iA Writer templates found. Install iA Writer or place .iatemplate bundles in ~/Library/Application Support/iA Writer/Templates/" }],
          };
        }
        const list = templates.map((t) => `  - "${t.name}" → ${t.path}`).join("\n");
        return {
          content: [{
            type: "text",
            text: `No default template configured. Please ask the user which template to use and call again with the \`template\` parameter.\n\nAvailable templates:\n${list}`,
          }],
        };
      }
    }

    // Resolve author: parameter > config > ask user
    if (!author) {
      const savedAuthor = config.author;
      if (savedAuthor) {
        author = savedAuthor;
      } else {
        return {
          content: [{
            type: "text",
            text: "No default author configured. Please ask the user for their name and call again with the `author` parameter.",
          }],
        };
      }
    }

    const args = ["--non-interactive", ...files];

    args.push("--template", template);
    args.push("--author", author);

    if (output_dir) {
      args.push("--output-dir", output_dir);
    }
    if (title && files.length === 1) {
      args.push("--title", title);
    }

    try {
      const { stdout, stderr } = await execFileAsync(BINARY, args, {
        timeout: 30_000,
      });

      const output = (stderr || "") + (stdout || "");
      return { content: [{ type: "text", text: output || "Conversion complete." }] };
    } catch (err) {
      const msg = err.stderr || err.message || "Unknown error";
      return { content: [{ type: "text", text: `Error: ${msg}` }] };
    }
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
