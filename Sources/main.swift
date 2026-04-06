import AppKit
import WebKit
import PDFKit
import cmark
import CMarkBridge

// MARK: - Helpers

extension String {
    func appendingPath(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }
}

// MARK: - Markdown → HTML (statically linked cmark-gfm, no external dependency)

func markdownToHTML(_ markdown: String) -> String? {
    let md = markdown

    cmark_gfm_core_extensions_ensure_registered()

    let parser = cmark_parser_new(CMARK_OPT_UNSAFE)!
    defer { cmark_parser_free(parser) }

    // Attach GFM extensions
    for ext in ["table", "strikethrough", "autolink", "tasklist"] {
        if let e = cmark_find_syntax_extension(ext) {
            cmark_parser_attach_syntax_extension(parser, e)
        }
    }

    cmark_parser_feed(parser, md, md.utf8.count)
    guard let doc = cmark_parser_finish(parser) else { return nil }
    defer { cmark_node_free(doc) }

    guard let html = cmark_render_html(doc, CMARK_OPT_UNSAFE, cmark_parser_get_syntax_extensions(parser)) else { return nil }
    defer { free(html) }

    return String(cString: html)
}

// MARK: - Config (persistent default template)

struct AppConfig {
    static let configDir = NSString(string: "~/.config/iatemplate2pdf").expandingTildeInPath
    static let configFile = configDir.appendingPath("config.json")

    static func systemUserName() -> String {
        return NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    }

    // Directories where iA Writer stores templates
    static let templateSearchPaths: [String] = [
        NSString(string: "~/Library/Containers/pro.writer.mac/Data/Library/Application Support/iA Writer/Templates").expandingTildeInPath,
        NSString(string: "~/Library/Application Support/iA Writer/Templates").expandingTildeInPath,
        "/Library/Application Support/iA Writer/Templates",
    ]

    static func findTemplates() -> [(name: String, path: String)] {
        var results: [(String, String)] = []
        let fm = FileManager.default
        for dir in templateSearchPaths {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".iatemplate") {
                let fullPath = dir.appendingPath(item)
                let name = (item as NSString).deletingPathExtension
                // Verify it's a valid template (has Info.plist)
                let plist = fullPath.appendingPath("Contents/Info.plist")
                if fm.fileExists(atPath: plist) {
                    results.append((name, fullPath))
                }
            }
        }
        // Deduplicate by name (prefer first found)
        var seen = Set<String>()
        return results.filter { seen.insert($0.0).inserted }
    }

    private static func loadConfig() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func saveConfig(_ config: [String: Any]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
            fm.createFile(atPath: configFile, contents: data)
        }
    }

    private static func updateConfig(key: String, value: Any) {
        var config = loadConfig() ?? [:]
        config[key] = value
        saveConfig(config)
    }

    static func loadDefaultTemplate() -> String? {
        guard let config = loadConfig(),
              let path = config["defaultTemplate"] as? String,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    static func saveDefaultTemplate(_ path: String) {
        updateConfig(key: "defaultTemplate", value: path)
    }

    static func loadAuthor() -> String? {
        guard let config = loadConfig(),
              let author = config["author"] as? String, !author.isEmpty else {
            return nil
        }
        return author
    }

    static func saveAuthor(_ name: String) {
        updateConfig(key: "author", value: name)
    }

    /// Ask user for author name. Returns author string.
    static func interactiveAuthorSetup() -> String {
        let systemName = systemUserName()
        let current = loadAuthor()

        if let cur = current {
            fputs("Current author: \(cur)\n", stderr)
        }

        fputs("Author name [\(systemName)]: ", stderr)
        let line = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let author = line.isEmpty ? systemName : line
        saveAuthor(author)
        fputs("Author set to: \(author)\n\n", stderr)
        return author
    }

    /// Interactive template selection. Returns chosen template path, or nil if none available.
    static func interactiveSetup() -> String? {
        let templates = findTemplates()

        if templates.isEmpty {
            fputs("No iA Writer templates found.\n", stderr)
            fputs("Install iA Writer or place .iatemplate bundles in:\n", stderr)
            for dir in templateSearchPaths {
                fputs("  \(dir)\n", stderr)
            }
            return nil
        }

        fputs("\nAvailable templates:\n\n", stderr)
        for (i, t) in templates.enumerated() {
            fputs("  [\(i + 1)] \(t.name)\n", stderr)
            fputs("      \(t.path)\n", stderr)
        }
        fputs("\n", stderr)

        // If only one template, auto-select
        if templates.count == 1 {
            fputs("Only one template found — using \(templates[0].name).\n", stderr)
            saveDefaultTemplate(templates[0].path)
            fputs("Saved as default.\n\n", stderr)
        } else {
            fputs("Choose default template [1-\(templates.count)]: ", stderr)
            guard let line = readLine(), let choice = Int(line),
                  choice >= 1, choice <= templates.count else {
                fputs("Invalid choice.\n", stderr)
                return nil
            }

            let selected = templates[choice - 1]
            saveDefaultTemplate(selected.path)
            fputs("Default template set to: \(selected.name)\n\n", stderr)
        }

        return loadDefaultTemplate()
    }

    /// Resolve template path: --template flag > config > interactive setup
    static func resolveTemplate(flagValue: String?, nonInteractive: Bool) -> String? {
        if let flag = flagValue { return flag }
        if let saved = loadDefaultTemplate() { return saved }

        if nonInteractive {
            fputs("Error: No default template configured. Run: iatemplate2pdf --setup\n", stderr)
            return nil
        }

        fputs("No default template configured.\n", stderr)
        return interactiveSetup()
    }

    /// Resolve author: --author flag > config > interactive > system username
    static func resolveAuthor(flagValue: String?, nonInteractive: Bool) -> String {
        if let flag = flagValue { return flag }
        if let saved = loadAuthor() { return saved }

        if nonInteractive { return systemUserName() }

        fputs("No author configured.\n", stderr)
        return interactiveAuthorSetup()
    }
}

// MARK: - Template config from Info.plist

struct TemplateConfig {
    let templateDir: String
    let headerHeight: CGFloat
    let footerHeight: CGFloat
    let headerFile: String?
    let footerFile: String?

    var resourcesDir: String { templateDir.appendingPath("Contents/Resources") }
    var resourcesURL: URL { URL(fileURLWithPath: resourcesDir) }

    static func load(from dir: String) -> TemplateConfig? {
        let plistPath = dir.appendingPath("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return TemplateConfig(
            templateDir: dir,
            headerHeight: CGFloat((plist["IATemplateHeaderHeight"] as? Int) ?? 0),
            footerHeight: CGFloat((plist["IATemplateFooterHeight"] as? Int) ?? 0),
            headerFile: plist["IATemplateHeaderFile"] as? String,
            footerFile: plist["IATemplateFooterFile"] as? String
        )
    }

    func readResource(_ name: String) -> String? {
        let path = resourcesDir.appendingPath(name)
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    func inlineCSS() -> String {
        ["normalize.css", "core.css", "style.css"]
            .compactMap { readResource($0) }
            .joined(separator: "\n")
    }

    // Pre-compiled regex patterns (compiled once, reused across calls)
    private static let commentRegex = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->", options: [])
    private static let cssRegex = try! NSRegularExpression(pattern: #"<link[^>]+href="([^"]+\.css)"[^>]*/?\s*>"#)
    private static let imgRegex = try! NSRegularExpression(pattern: #"<img\s+src="([^"]+\.svg)"([^>]*)>"#)
    private static let widthRegex = try! NSRegularExpression(pattern: #"width="([^"]+)""#)
    private static let heightRegex = try! NSRegularExpression(pattern: #"height="([^"]+)""#)
    private static let classRegex = try! NSRegularExpression(pattern: #"class="([^"]+)""#)

    /// Inline all external resources (<link href="...css">, <img src="...svg">) so
    /// WKWebView can render them in print mode without file access issues.
    func inlineResources(in html: String) -> String {
        // Strip HTML comments first to avoid inlining commented-out resources
        var result = Self.commentRegex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")

        // Inline CSS: <link ... href="X.css" ... /> → <style>...</style>
        for match in Self.cssRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            let fullRange = Range(match.range, in: result)!
            let fileRange = Range(match.range(at: 1), in: result)!
            let filename = String(result[fileRange])
            if let css = readResource(filename) {
                result.replaceSubrange(fullRange, with: "<style>\(css)</style>")
            }
        }

        // Inline SVG: <img src="X.svg" width="W" height="H" class="C" ...> → inline SVG
        for match in Self.imgRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            let fullRange = Range(match.range, in: result)!
            let filenameRange = Range(match.range(at: 1), in: result)!
            let attrsRange = Range(match.range(at: 2), in: result)!
            let filename = String(result[filenameRange])
            let attrs = String(result[attrsRange])

            if var svg = readResource(filename) {
                var extra = ""
                let attrRegexes: [(NSRegularExpression, String)] = [
                    (Self.widthRegex, "width"),
                    (Self.heightRegex, "height"),
                    (Self.classRegex, "class"),
                ]
                for (re, attr) in attrRegexes {
                    if let m = re.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) {
                        let val = String(attrs[Range(m.range(at: 1), in: attrs)!])
                        extra += " \(attr)=\"\(val)\""
                    }
                }
                svg = svg.replacingOccurrences(of: "<svg ", with: "<svg\(extra) ")
                result.replaceSubrange(fullRange, with: svg)
            }
        }

        return result
    }

    func headerHTML(title: String, date: String) -> String? {
        guard let file = headerFile, let html = readResource("\(file).html") else { return nil }
        let populated = html
            .replacingOccurrences(of: "<span data-title>&nbsp;</span>", with: "<span>\(title)</span>")
            .replacingOccurrences(of: "<span data-date>&nbsp;</span>", with: "<span>\(date)</span>")
        return inlineResources(in: populated)
    }

    func footerHTML(pageNumber: Int, pageCount: Int) -> String? {
        guard let file = footerFile, let html = readResource("\(file).html") else { return nil }
        let populated = html
            .replacingOccurrences(of: "data-page-number >&nbsp;", with: "data-page-number>\(pageNumber)")
            .replacingOccurrences(of: "data-page-number>&nbsp;", with: "data-page-number>\(pageNumber)")
            .replacingOccurrences(of: "data-page-count >&nbsp;", with: "data-page-count>\(pageCount)")
            .replacingOccurrences(of: "data-page-count>&nbsp;", with: "data-page-count>\(pageCount)")
        return inlineResources(in: populated)
    }
}

enum PageConfig {
    static let paperWidth: CGFloat = 595.28
    static let paperHeight: CGFloat = 841.89
    static let marginTop: CGFloat = 90
    static let marginBottom: CGFloat = 90
    static let marginLeft: CGFloat = 0
    static let marginRight: CGFloat = 0
}

// MARK: - Extract first H1 from Markdown

func extractFirstH1(from text: String) -> String? {
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

func readFile(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(data: data, encoding: .utf8)
}

// MARK: - Build body HTML

func buildBodyHTML(content: String, template: TemplateConfig) -> String {
    let css = template.inlineCSS()
    return """
    <!doctype html>
    <html class="mac">
    <head><meta charset="UTF-8"><style>\(css)
    /* Ensure background colors print (WebKit suppresses them by default) */
    * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    </style></head>
    <body data-document>\(content)</body>
    </html>
    """
}

// MARK: - Reusable WebView renderer

class PDFRenderer {
    private let webView: WKWebView
    private let navDelegate: NavDelegate

    init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 595, height: 842), configuration: config)
        navDelegate = NavDelegate()
        webView.navigationDelegate = navDelegate
        objc_setAssociatedObject(webView, "navDelegate", navDelegate, .OBJC_ASSOCIATION_RETAIN)
    }

    func render(html: String, baseURL: URL, outputPath: String, paperSize: NSSize, margins: NSEdgeInsets) -> Bool {
        var success = false
        let sem = DispatchSemaphore(value: 0)

        let outputURL = URL(fileURLWithPath: outputPath)
        navDelegate.outputURL = outputURL
        navDelegate.paperSize = paperSize
        navDelegate.margins = margins
        navDelegate.onDone = { result in
            success = result
            sem.signal()
        }

        webView.loadHTMLString(html, baseURL: baseURL)

        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        return success
    }
}

private class NavDelegate: NSObject, WKNavigationDelegate {
    var outputURL: URL!
    var paperSize: NSSize!
    var margins: NSEdgeInsets!
    var onDone: ((Bool) -> Void)?

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
        // Wait for WebKit layout completion via requestAnimationFrame
        wv.evaluateJavaScript("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))") { _, _ in
            let pi = NSPrintInfo()
            pi.paperSize = self.paperSize
            pi.topMargin = self.margins.top
            pi.bottomMargin = self.margins.bottom
            pi.leftMargin = self.margins.left
            pi.rightMargin = self.margins.right
            pi.isHorizontallyCentered = false
            pi.isVerticallyCentered = false
            pi.jobDisposition = .save
            pi.dictionary().setObject(self.outputURL!, forKey: NSPrintInfo.AttributeKey.jobSavingURL as NSCopying)

            let op = wv.printOperation(with: pi)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.runModal(for: NSWindow(), delegate: self, didRun: #selector(self.didRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    func webView(_ wv: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
        onDone?(false)
    }

    @objc func didRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        onDone?(success)
    }
}

// MARK: - Load first page of a PDF file (keeps vector data)

func loadPDFPage(from path: String, retainIn docs: inout [PDFDocument]) -> PDFPage? {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
          let page = doc.page(at: 0) else { return nil }
    docs.append(doc)
    return page
}

// MARK: - PDFKit: Overlay header/footer as vector PDF pages

class AnnotatedPDFPage: PDFPage {
    private let original: PDFPage
    private let headerPage: PDFPage?
    private let footerPage: PDFPage?
    private let hdrH: CGFloat
    private let ftrH: CGFloat

    init(original: PDFPage, header: PDFPage?, footer: PDFPage?, headerH: CGFloat, footerH: CGFloat) {
        self.original = original
        self.headerPage = header
        self.footerPage = footer
        self.hdrH = headerH
        self.ftrH = footerH
        super.init()
    }

    override func bounds(for box: PDFDisplayBox) -> NSRect { original.bounds(for: box) }

    override func draw(with box: PDFDisplayBox, to ctx: CGContext) {
        original.draw(with: box, to: ctx)

        let b = original.bounds(for: box)

        if let hdr = headerPage {
            let hdrBounds = hdr.bounds(for: .mediaBox)
            ctx.saveGState()
            let scaleX = b.width / hdrBounds.width
            let scaleY = hdrH / hdrBounds.height
            ctx.translateBy(x: 0, y: b.height - hdrH)
            ctx.scaleBy(x: scaleX, y: scaleY)
            hdr.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }

        if let ftr = footerPage {
            let ftrBounds = ftr.bounds(for: .mediaBox)
            ctx.saveGState()
            let scaleX = b.width / ftrBounds.width
            let scaleY = ftrH / ftrBounds.height
            ctx.scaleBy(x: scaleX, y: scaleY)
            ftr.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
    }
}

// MARK: - Convert a single Markdown file to PDF

func convertFile(inputURL: URL, outputURL: URL, template: TemplateConfig, renderer: PDFRenderer, markdown: String, docTitle: String, author: String) -> Bool {
    guard let contentHTML = markdownToHTML(markdown) else {
        fputs("Error: Markdown conversion failed for \(inputURL.lastPathComponent)\n", stderr)
        return false
    }

    let dateFmt = DateFormatter()
    dateFmt.dateStyle = .medium
    dateFmt.locale = Locale.current
    let dateStr = dateFmt.string(from: Date())

    fputs("  Rendering body...\n", stderr)

    let tmp = FileManager.default.temporaryDirectory
    let bodyPDF = tmp.appendingPathComponent("md2pdf-body-\(UUID().uuidString).pdf").path
    let bodyHTML = buildBodyHTML(content: contentHTML, template: template)
    let bodyOk = renderer.render(
        html: bodyHTML, baseURL: template.resourcesURL, outputPath: bodyPDF,
        paperSize: NSSize(width: PageConfig.paperWidth, height: PageConfig.paperHeight),
        margins: NSEdgeInsets(top: PageConfig.marginTop, left: PageConfig.marginLeft, bottom: PageConfig.marginBottom, right: PageConfig.marginRight)
    )
    guard bodyOk else { fputs("  Error: Body render failed\n", stderr); return false }

    guard let bodyDoc = PDFDocument(url: URL(fileURLWithPath: bodyPDF)) else {
        fputs("  Error: Cannot read body PDF\n", stderr); return false
    }
    let pageCount = bodyDoc.pageCount
    fputs("  Body: \(pageCount) pages\n", stderr)

    var tempFiles = [bodyPDF]
    var retainedDocs: [PDFDocument] = []

    var headerPage: PDFPage? = nil
    if let headerHTML = template.headerHTML(title: docTitle, date: dateStr) {
        let headerPDFPath = tmp.appendingPathComponent("md2pdf-header-\(UUID().uuidString).pdf").path
        tempFiles.append(headerPDFPath)
        let zeroMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let hdrOk = renderer.render(
            html: headerHTML, baseURL: template.resourcesURL, outputPath: headerPDFPath,
            paperSize: NSSize(width: PageConfig.paperWidth, height: template.headerHeight),
            margins: zeroMargins
        )
        if hdrOk { headerPage = loadPDFPage(from: headerPDFPath, retainIn: &retainedDocs) }
    }

    var footerPages: [PDFPage?] = []
    for p in 1...pageCount {
        if let footerHTML = template.footerHTML(pageNumber: p, pageCount: pageCount) {
            let footerPDFPath = tmp.appendingPathComponent("md2pdf-footer-\(UUID().uuidString).pdf").path
            tempFiles.append(footerPDFPath)
            let zeroMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            let ftrOk = renderer.render(
                html: footerHTML, baseURL: template.resourcesURL, outputPath: footerPDFPath,
                paperSize: NSSize(width: PageConfig.paperWidth, height: template.footerHeight),
                margins: zeroMargins
            )
            footerPages.append(ftrOk ? loadPDFPage(from: footerPDFPath, retainIn: &retainedDocs) : nil)
        } else {
            footerPages.append(nil)
        }
    }

    let result = PDFDocument()
    for p in 0..<pageCount {
        guard let page = bodyDoc.page(at: p) else { continue }
        let annotated = AnnotatedPDFPage(
            original: page,
            header: headerPage,
            footer: p < footerPages.count ? footerPages[p] : nil,
            headerH: template.headerHeight,
            footerH: template.footerHeight
        )
        result.insert(annotated, at: result.pageCount)
    }

    // Write PDF to temp file first, then re-write with metadata via CGPDFContext
    // (PDFDocument.documentAttributes misencodes titles starting with '/')
    let tmpPDF = tmp.appendingPathComponent("md2pdf-result-\(UUID().uuidString).pdf").path
    tempFiles.append(tmpPDF)
    guard result.write(to: URL(fileURLWithPath: tmpPDF)) else {
        fputs("  Error: Write failed\n", stderr)
        return false
    }

    let ok = writePDFWithMetadata(
        inputPath: tmpPDF, outputURL: outputURL,
        title: docTitle, author: author
    )
    if ok { fputs("  → \(outputURL.path)\n", stderr) }
    else { fputs("  Error: Metadata write failed\n", stderr) }

    // Clean up temp files and retained PDF documents
    for path in tempFiles {
        try? FileManager.default.removeItem(atPath: path)
    }

    return ok
}

// MARK: - Write PDF with correct metadata via CGPDFContext

func writePDFWithMetadata(inputPath: String, outputURL: URL, title: String, author: String) -> Bool {
    guard let inputDoc = CGPDFDocument(URL(fileURLWithPath: inputPath) as CFURL) else { return false }

    // Prefix title with a zero-width space if it starts with '/' to work around
    // a CoreGraphics bug where '/' triggers PDF Name Object encoding instead of string
    let safeTitle = title.hasPrefix("/") ? "\u{200B}\(title)" : title

    let auxInfo: [CFString: Any] = [
        kCGPDFContextTitle: safeTitle as CFString,
        kCGPDFContextAuthor: author as CFString,
    ]

    guard let consumer = CGDataConsumer(url: outputURL as CFURL) else { return false }
    var firstPageBox = inputDoc.page(at: 1)?.getBoxRect(.mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &firstPageBox, auxInfo as CFDictionary) else { return false }

    for i in 1...inputDoc.numberOfPages {
        guard let page = inputDoc.page(at: i) else { continue }
        var pageBox = page.getBoxRect(.mediaBox)
        ctx.beginPage(mediaBox: &pageBox)
        ctx.drawPDFPage(page)
        ctx.endPage()
    }

    ctx.closePDF()
    return true
}

// MARK: - CLI

func printUsage() {
    fputs("""
    Usage: iatemplate2pdf <input.md ...> [output.pdf] [options]

    Options:
      --template <path>     Path to .iatemplate bundle
      --title <text>        Document title (single file only; default: first H1)
      --author <text>       Author name (default: saved config or system user)
      --output-dir <path>   Output directory for batch conversion
      --setup               Configure default template and author
      --list-templates      List available iA Writer templates
      --non-interactive     Never prompt for input (for scripts/MCP)
      --help, -h            Show this help

    Subcommands:
      mcp-server            Run as MCP server (stdin/stdout JSON-RPC)

    Examples:
      iatemplate2pdf doc.md                          # Single file
      iatemplate2pdf doc.md output.pdf               # Single file with output path
      iatemplate2pdf *.md --output-dir ./export/     # Batch conversion
      iatemplate2pdf --setup                         # Configure template & author

    """, stderr)
}

var args = CommandLine.arguments; args.removeFirst()

// Handle --help with no args
if args.isEmpty { printUsage(); exit(0) }

// MCP server mode
if args.first == "mcp-server" {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task {
        await startMCPServer()
    }
    RunLoop.main.run()
}

var inputPaths: [String] = []
var outputPath: String?
var outputDir: String?
var templateFlag: String?
var titleFlag: String?
var authorFlag: String?
var runSetup = false
var listTemplates = false
var nonInteractive = false

var idx = 0
while idx < args.count {
    switch args[idx] {
    case "--template":
        idx += 1; guard idx < args.count else { fputs("Error: --template requires a value\n", stderr); exit(1) }
        templateFlag = args[idx]
    case "--title":
        idx += 1; guard idx < args.count else { fputs("Error: --title requires a value\n", stderr); exit(1) }
        titleFlag = args[idx]
    case "--author":
        idx += 1; guard idx < args.count else { fputs("Error: --author requires a value\n", stderr); exit(1) }
        authorFlag = args[idx]
    case "--output-dir":
        idx += 1; guard idx < args.count else { fputs("Error: --output-dir requires a value\n", stderr); exit(1) }
        outputDir = args[idx]
    case "--setup":           runSetup = true
    case "--list-templates":  listTemplates = true
    case "--non-interactive": nonInteractive = true
    case "--help", "-h":      printUsage(); exit(0)
    default:
        let arg = args[idx]
        if arg.hasPrefix("--") {
            fputs("Error: Unknown option: \(arg)\n", stderr)
            printUsage()
            exit(1)
        }
        if arg.hasSuffix(".pdf") && outputDir == nil && inputPaths.count == 1 {
            outputPath = arg
        } else {
            inputPaths.append(arg)
        }
    }
    idx += 1
}

// Auto-detect non-interactive mode when stdin is not a terminal
if isatty(STDIN_FILENO) == 0 {
    nonInteractive = true
}

// --list-templates: show and exit
if listTemplates {
    let templates = AppConfig.findTemplates()
    if templates.isEmpty {
        fputs("No templates found.\n", stderr)
    } else {
        let current = AppConfig.loadDefaultTemplate()
        fputs("Available templates:\n\n", stderr)
        for t in templates {
            let marker = (t.path == current) ? " (default)" : ""
            fputs("  \(t.name)\(marker)\n", stderr)
            fputs("  \(t.path)\n\n", stderr)
        }
    }
    exit(0)
}

// --setup: interactive configuration
if runSetup {
    guard let _ = AppConfig.interactiveSetup() else { exit(1) }
    _ = AppConfig.interactiveAuthorSetup()
    exit(0)
}

// Need input files for conversion
guard !inputPaths.isEmpty else { fputs("Error: No input files\n", stderr); exit(1) }

// Resolve template and author
guard let templatePath = AppConfig.resolveTemplate(flagValue: templateFlag, nonInteractive: nonInteractive) else {
    fputs("Error: No template available. Run: iatemplate2pdf --setup\n", stderr)
    exit(1)
}

guard FileManager.default.fileExists(atPath: templatePath) else {
    fputs("Error: Template not found at \(templatePath)\n", stderr)
    fputs("Run: iatemplate2pdf --setup\n", stderr)
    exit(1)
}
guard let template = TemplateConfig.load(from: templatePath) else {
    fputs("Error: Invalid template at \(templatePath)\n", stderr)
    exit(1)
}

let author = AppConfig.resolveAuthor(flagValue: authorFlag, nonInteractive: nonInteractive)

if let dir = outputDir {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = PDFRenderer()

var failures = 0

for inputPathStr in inputPaths {
    let inputURL = URL(fileURLWithPath: (inputPathStr as NSString).expandingTildeInPath)

    guard let markdown = readFile(inputURL.path) else {
        fputs("Error: Cannot read file: \(inputURL.path)\n", stderr)
        failures += 1
        continue
    }

    let outURL: URL
    if let dir = outputDir {
        let pdfName = inputURL.deletingPathExtension().lastPathComponent + ".pdf"
        outURL = URL(fileURLWithPath: dir).appendingPathComponent(pdfName)
    } else if let op = outputPath, inputPaths.count == 1 {
        outURL = URL(fileURLWithPath: (op as NSString).expandingTildeInPath)
    } else {
        outURL = inputURL.deletingPathExtension().appendingPathExtension("pdf")
    }

    let docTitle: String
    if let flag = titleFlag, inputPaths.count == 1 {
        docTitle = flag
    } else {
        docTitle = extractFirstH1(from: markdown) ?? inputURL.deletingPathExtension().lastPathComponent
    }
    fputs("Converting: \(inputURL.lastPathComponent)\n", stderr)

    let ok = convertFile(inputURL: inputURL, outputURL: outURL, template: template, renderer: renderer, markdown: markdown, docTitle: docTitle, author: author)
    if !ok { failures += 1 }
}

if inputPaths.count > 1 {
    fputs("\nDone: \(inputPaths.count - failures)/\(inputPaths.count) files converted\n", stderr)
}

exit(failures > 0 ? 1 : 0)
