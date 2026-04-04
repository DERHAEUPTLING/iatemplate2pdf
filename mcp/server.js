#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { resolve, dirname, basename, join } from "node:path";

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
      "Path to an .iatemplate bundle. If omitted, uses the default template."
    ),
    title: z.string().optional().describe(
      "Document title (used in header). Only applies when converting a single file."
    ),
    author: z.string().optional().describe(
      "Author name. Defaults to 'Martin Schwenzer'."
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

    const args = [...files];

    if (output_dir) {
      args.push("--output-dir", output_dir);
    }
    if (template) {
      args.push("--template", template);
    }
    if (title && files.length === 1) {
      args.push("--title", title);
    }
    if (author) {
      args.push("--author", author);
    }

    try {
      const { stdout, stderr } = await execFileAsync(BINARY, args, {
        timeout: 120_000, // 2 minutes for large batches
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
