import Foundation
import MCP

// MARK: - MCP Server (native, no Node.js required)

func startMCPServer() async {
    let server = Server(
        name: "iatemplate2pdf",
        version: "1.0.0",
        capabilities: .init(tools: .init())
    )

    let tool = Tool(
        name: "iatemplate2pdf",
        description: "Convert one or more Markdown files to PDF using an iA Writer template. "
            + "Produces PDFs with headers, footers, page numbers, and custom typography — "
            + "identical to iA Writer's native PDF export.",
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

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [tool])
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard params.name == "iatemplate2pdf" else {
            return CallTool.Result(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        return await handleConversion(params.arguments)
    }

    let transport = StdioTransport()
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
