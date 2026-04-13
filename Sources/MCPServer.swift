import Foundation
import MCP

// MARK: - MCP Server (native, no Node.js required)

func startMCPServer() async {
    let server = Server(
        name: "iatemplate2pdf",
        version: "1.0.0",
        capabilities: .init(tools: .init())
    )

    let convertTool = Tool(
        name: "iatemplate2pdf",
        description: "Convert one or more Markdown files to PDF using an iA Writer template. "
            + "Produces PDFs with headers, footers, page numbers, and custom typography — "
            + "identical to iA Writer's native PDF export. "
            + "If the server reports that no default template or author is configured, "
            + "call `list_templates` and `set_defaults` first to bootstrap the configuration.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "files": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Absolute paths to Markdown files to convert"),
                ]),
                "output_dir": .object([
                    "type": .string("string"),
                    "description": .string("Output directory for the PDFs. If omitted, PDFs are placed next to the source files."),
                ]),
                "template": .object([
                    "type": .string("string"),
                    "description": .string("Path to an .iatemplate bundle. If omitted, uses the configured default template."),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string("Document title (used in header). Only applies when converting a single file. If omitted, the first H1 heading from the Markdown is used."),
                ]),
                "author": .object([
                    "type": .string("string"),
                    "description": .string("Author name. If omitted, uses the configured default author."),
                ]),
            ]),
            "required": .array([.string("files")]),
        ])
    )

    let listTemplatesTool = Tool(
        name: "list_templates",
        description: "List all iA Writer templates found on the system, plus the currently configured "
            + "default template and author. Use this to discover available templates before calling "
            + "`set_defaults`, or to check the current configuration.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    let setDefaultsTool = Tool(
        name: "set_defaults",
        description: "Persist default template and/or author name in the user's config "
            + "(\(AppConfig.configFileDisplay)). Equivalent to the CLI `--setup` command, "
            + "but callable from MCP. At least one of `template` or `author` must be provided. "
            + "The `template` parameter accepts either an absolute path to a `.iatemplate` bundle "
            + "or a template name (as shown by `list_templates`). Relative paths are not supported. "
            + "Call `list_templates` first if you don't know which templates are available.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "template": .object([
                    "type": .string("string"),
                    "description": .string("Template name (e.g. \"Standard\") or absolute path to a .iatemplate bundle. Optional."),
                ]),
                "author": .object([
                    "type": .string("string"),
                    "description": .string("Author name used in document headers. Optional."),
                ]),
            ]),
        ])
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [convertTool, listTemplatesTool, setDefaultsTool])
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "iatemplate2pdf":
            return await handleConversion(params.arguments)
        case "list_templates":
            return handleListTemplates()
        case "set_defaults":
            return handleSetDefaults(params.arguments)
        default:
            return textResult("Unknown tool: \(params.name)", isError: true)
        }
    }

    let transport = StdioTransport()
    // Note: the process does not exit cleanly on stdin EOF. The MCP SDK's
    // receive loop terminates, but request handlers run as detached tasks
    // the SDK doesn't track, and main.swift's RunLoop.main.run() can't be
    // unwound via CFRunLoopStop. Real MCP hosts keep stdin open and SIGTERM
    // on shutdown, so this is harmless in production. Test scripts must
    // poll for expected responses and kill the process (see scripts/test-mcp.sh).
    do {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    } catch {
        fputs("MCP server error: \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Tool handler

private func handleConversion(_ arguments: [String: Value]?) async -> CallTool.Result {
    // Extract parameters
    guard let args = arguments,
          let filesValue = args["files"]?.arrayValue else {
        return textResult("Error: No files provided", isError: true)
    }

    let files = filesValue.compactMap { $0.stringValue }
    if files.isEmpty {
        return textResult("Error: No files provided", isError: true)
    }

    // Validate all files exist
    let fm = FileManager.default
    let missing = files.filter { !fm.fileExists(atPath: $0) }
    if !missing.isEmpty {
        return textResult("Error: Files not found:\n\(missing.joined(separator: "\n"))", isError: true)
    }

    // Resolve template
    var templatePath = args["template"]?.stringValue
    if templatePath == nil {
        let saved = AppConfig.loadDefaultTemplate()
        if let saved, fm.fileExists(atPath: saved) {
            templatePath = saved
        } else {
            let templates = AppConfig.findTemplates()
            if templates.isEmpty {
                return textResult(
                    "Error: No iA Writer templates found. Install iA Writer or place .iatemplate bundles in ~/Library/Application Support/iA Writer/Templates/",
                    isError: true
                )
            }
            let list = templates.map { "  - \"\($0.name)\" → \($0.path)" }.joined(separator: "\n")
            return textResult(
                "No default template configured. Please ask the user which template to use and call again with the `template` parameter.\n\nAvailable templates:\n\(list)"
            )
        }
    }

    // Resolve author
    var author = args["author"]?.stringValue
    if author == nil {
        let saved = AppConfig.loadAuthor()
        if let saved {
            author = saved
        } else {
            return textResult(
                "No default author configured. Please ask the user for their name and call again with the `author` parameter."
            )
        }
    }

    let outputDir = args["output_dir"]?.stringValue
    let titleFlag = args["title"]?.stringValue

    let resolvedTemplate = templatePath!
    let resolvedAuthor = author!
    let result: String = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let output = runConversionProcess(
                files: files,
                templatePath: resolvedTemplate,
                author: resolvedAuthor,
                outputDir: outputDir,
                titleFlag: titleFlag
            )
            continuation.resume(returning: output)
        }
    }

    let isError = result.hasPrefix("Error:")
    return textResult(result, isError: isError)
}

// MARK: - list_templates handler

private func handleListTemplates() -> CallTool.Result {
    let templates = AppConfig.findTemplates()
    let currentTemplate = AppConfig.loadDefaultTemplate()
    let currentAuthor = AppConfig.loadAuthor()

    var lines: [String] = []

    if templates.isEmpty {
        lines.append("No iA Writer templates found on this system.")
        lines.append("Install iA Writer, or place .iatemplate bundles in one of:")
        for dir in AppConfig.templateSearchPaths {
            lines.append("  \(dir)")
        }
    } else {
        lines.append("Available templates:")
        for t in templates {
            let marker = (t.path == currentTemplate) ? " (current default)" : ""
            lines.append("  - \(t.name)\(marker)")
            lines.append("      \(t.path)")
        }
    }

    lines.append("")
    lines.append("Current configuration:")
    lines.append("  default template: \(currentTemplate ?? "(not set)")")
    lines.append("  author:           \(currentAuthor ?? "(not set)")")

    return textResult(lines.joined(separator: "\n"))
}

// MARK: - set_defaults handler

private func handleSetDefaults(_ arguments: [String: Value]?) -> CallTool.Result {
    let templateArg = arguments?["template"]?.stringValue
    let authorArg = arguments?["author"]?.stringValue

    if templateArg == nil && authorArg == nil {
        return textResult(
            "Error: set_defaults requires at least one of `template` or `author`.",
            isError: true
        )
    }

    // Validate everything before any mutation, so a bad author doesn't
    // leave a half-applied template save behind.
    var resolvedTemplate: String?
    if let templateInput = templateArg {
        let resolution = resolveTemplateInput(templateInput)
        if let error = resolution.error {
            return textResult(error, isError: true)
        }
        resolvedTemplate = resolution.path
    }

    var resolvedAuthor: String?
    if let authorInput = authorArg {
        let trimmed = authorInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return textResult(
                "Error: `author` must not be empty. Provide a non-whitespace name like \"Jane Doe\".",
                isError: true
            )
        }
        resolvedAuthor = trimmed
    }

    var changes: [String] = []
    if let path = resolvedTemplate {
        AppConfig.saveDefaultTemplate(path)
        changes.append("default template → \(path)")
    }
    if let author = resolvedAuthor {
        AppConfig.saveAuthor(author)
        changes.append("author → \(author)")
    }

    var lines = ["Saved:"]
    lines.append(contentsOf: changes.map { "  \($0)" })
    lines.append("")
    lines.append("Config file: \(AppConfig.configFileDisplay)")
    return textResult(lines.joined(separator: "\n"))
}

/// Resolve a template argument that may be either an absolute path to an
/// .iatemplate bundle or a template name. On success, `path` is the canonical
/// bundle path and `error` is nil. On failure, `error` holds a user-facing message.
private func resolveTemplateInput(_ input: String) -> (path: String?, error: String?) {
    let fm = FileManager.default

    // Path-like: anything containing a slash. Must be absolute.
    if input.contains("/") {
        guard input.hasPrefix("/") else {
            return (nil,
                "Error: '\(input)' looks like a path but is not absolute. "
                + "Use an absolute path (starting with /) or a template name from list_templates.")
        }
        let normalized = URL(fileURLWithPath: input).path
        guard fm.fileExists(atPath: normalized) else {
            return (nil, "Error: '\(normalized)' does not exist.")
        }
        let plist = normalized.appendingPath("Contents/Info.plist")
        guard fm.fileExists(atPath: plist) else {
            return (nil,
                "Error: '\(normalized)' is not a valid .iatemplate bundle (missing Contents/Info.plist).")
        }
        return (normalized, nil)
    }

    let templates = AppConfig.findTemplates()
    if let match = templates.first(where: { $0.name == input }) {
        return (match.path, nil)
    }
    let available = templates.isEmpty
        ? "(no templates found on this system)"
        : templates.map { "  - \($0.name)" }.joined(separator: "\n")
    return (nil,
        "Error: Template '\(input)' not found. Available templates:\n\(available)\n"
        + "Call list_templates to see full paths, or set_defaults again with one of these names.")
}

// MARK: - Conversion via subprocess
// WebKit rendering requires the main thread with its own RunLoop,
// which conflicts with the MCP server's event loop. We solve this
// by invoking ourselves as a CLI subprocess — same approach as the
// original Node.js MCP server, but without needing Node.js.

private func runConversionProcess(
    files: [String],
    templatePath: String,
    author: String,
    outputDir: String?,
    titleFlag: String?
) -> String {
    let binary = ProcessInfo.processInfo.arguments[0]
    var args = ["--non-interactive"] + files
    args += ["--template", templatePath]
    args += ["--author", author]
    if let dir = outputDir { args += ["--output-dir", dir] }
    if let title = titleFlag, files.count == 1 { args += ["--title", title] }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = args

    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = FileHandle.nullDevice
    // Close stdin so the subprocess doesn't inherit MCP's stdin pipe
    process.standardInput = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return "Error: Failed to start conversion: \(error.localizedDescription)"
    }

    // Read stderr before waitUntilExit to avoid pipe buffer deadlock
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let stderrOutput = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if process.terminationStatus != 0 {
        return stderrOutput.isEmpty
            ? "Error: Conversion failed (exit code \(process.terminationStatus))"
            : stderrOutput
    }

    // Build result from checking output files
    var results: [String] = []
    for file in files {
        let inputURL = URL(fileURLWithPath: file)
        let pdfName = inputURL.deletingPathExtension().lastPathComponent + ".pdf"
        let pdfPath: String
        if let dir = outputDir {
            pdfPath = URL(fileURLWithPath: dir).appendingPathComponent(pdfName).path
        } else {
            pdfPath = inputURL.deletingPathExtension().appendingPathExtension("pdf").path
        }
        if FileManager.default.fileExists(atPath: pdfPath) {
            results.append("Converted: \(inputURL.lastPathComponent) → \(pdfPath)")
        } else {
            results.append("Error: Conversion failed for \(inputURL.lastPathComponent)")
        }
    }

    if files.count > 1 {
        let succeeded = results.filter { $0.hasPrefix("Converted:") }.count
        results.append("\nDone: \(succeeded)/\(files.count) files converted")
    }

    return results.joined(separator: "\n")
}

// MARK: - Helper

private func textResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    CallTool.Result(
        content: [.text(text: text, annotations: nil, _meta: nil)],
        isError: isError ? true : nil
    )
}
