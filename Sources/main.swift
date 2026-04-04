import AppKit
import WebKit
import PDFKit

// MARK: - Default template path

let defaultTemplatePath = NSString(string: "~/Library/Containers/pro.writer.mac/Data/Library/Application Support/iA Writer/Templates/DERHAEUPTLING.iatemplate").expandingTildeInPath

// MARK: - Template config from Info.plist

struct TemplateConfig {
    let templateDir: String
    let headerHeight: CGFloat
    let footerHeight: CGFloat
    let headerFile: String?
    let footerFile: String?

    var resourcesDir: String { (templateDir as NSString).appendingPathComponent("Contents/Resources") }
    var resourcesURL: URL { URL(fileURLWithPath: resourcesDir) }

    static func load(from dir: String) -> TemplateConfig? {
        let plistPath = (dir as NSString).appendingPathComponent("Contents/Info.plist")
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
        let path = (resourcesDir as NSString).appendingPathComponent(name)
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    func inlineCSS() -> String {
        ["normalize.css", "core.css", "style.css"]
            .compactMap { readResource($0) }
            .joined(separator: "\n")
    }

    /// Inline all external resources (<link href="...css">, <img src="...svg">) so
    /// WKWebView can render them in print mode without file access issues.
    func inlineResources(in html: String) -> String {
        // Strip HTML comments first to avoid inlining commented-out resources
        let commentPattern = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->", options: [])
        var result = commentPattern.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")

        // Inline CSS: <link ... href="X.css" ... /> → <style>...</style>
        let cssPattern = try! NSRegularExpression(pattern: #"<link[^>]+href="([^"]+\.css)"[^>]*/?\s*>"#)
        for match in cssPattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            let fullRange = Range(match.range, in: result)!
            let fileRange = Range(match.range(at: 1), in: result)!
            let filename = String(result[fileRange])
            if let css = readResource(filename) {
                result.replaceSubrange(fullRange, with: "<style>\(css)</style>")
            }
        }

        // Inline SVG: <img src="X.svg" width="W" height="H" class="C" ...> → inline SVG
        let imgPattern = try! NSRegularExpression(pattern: #"<img\s+src="([^"]+\.svg)"([^>]*)>"#)
        for match in imgPattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            let fullRange = Range(match.range, in: result)!
            let filenameRange = Range(match.range(at: 1), in: result)!
            let attrsRange = Range(match.range(at: 2), in: result)!
            let filename = String(result[filenameRange])
            let attrs = String(result[attrsRange])

            if var svg = readResource(filename) {
                // Transfer width, height, class from <img> to <svg>
                var extra = ""
                let patterns: [(String, String)] = [
                    (#"width="([^"]+)""#, "width"),
                    (#"height="([^"]+)""#, "height"),
                    (#"class="([^"]+)""#, "class"),
                ]
                for (pat, attr) in patterns {
                    let re = try! NSRegularExpression(pattern: pat)
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

struct PageConfig {
    let paperWidth: CGFloat = 595.28
    let paperHeight: CGFloat = 841.89
    // Body CSS handles horizontal padding (12pt 50pt in print mode).
    // NSPrintInfo margins only control the non-printable area.
    // Vertical margins = header/footer height (90pt each from template).
    // Horizontal margins = 0 — CSS body padding handles it.
    let marginTop: CGFloat = 90
    let marginBottom: CGFloat = 90
    let marginLeft: CGFloat = 0
    let marginRight: CGFloat = 0
}

// MARK: - Markdown → HTML

func markdownToHTML(_ path: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/cmark-gfm")
    proc.arguments = ["--unsafe", "--extension", "table", path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    do { try proc.run(); proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    } catch { return nil }
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

// MARK: - Synchronous WKWebView → PDF render (blocks until done)
// Uses a nested RunLoop to allow sequential renders

func renderHTMLToPDF(html: String, baseURL: URL, outputPath: String, paperSize: NSSize, margins: NSEdgeInsets) -> Bool {
    var success = false
    let done = DispatchSemaphore(value: 0)

    let webView = WKWebView(
        frame: NSRect(x: 0, y: 0, width: paperSize.width, height: paperSize.height),
        configuration: WKWebViewConfiguration()
    )

    class NavHandler: NSObject, WKNavigationDelegate {
        let outputURL: URL
        let paperSize: NSSize
        let margins: NSEdgeInsets
        var onDone: ((Bool) -> Void)?

        init(outputURL: URL, paperSize: NSSize, margins: NSEdgeInsets) {
            self.outputURL = outputURL
            self.paperSize = paperSize
            self.margins = margins
        }

        func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let pi = NSPrintInfo()
                pi.paperSize = self.paperSize
                pi.topMargin = self.margins.top
                pi.bottomMargin = self.margins.bottom
                pi.leftMargin = self.margins.left
                pi.rightMargin = self.margins.right
                pi.isHorizontallyCentered = false
                pi.isVerticallyCentered = false
                pi.jobDisposition = .save
                pi.dictionary().setObject(self.outputURL, forKey: NSPrintInfo.AttributeKey.jobSavingURL as NSCopying)

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

    let outputURL = URL(fileURLWithPath: outputPath)
    let handler = NavHandler(outputURL: outputURL, paperSize: paperSize, margins: margins)
    handler.onDone = { result in
        success = result
        done.signal()
    }
    webView.navigationDelegate = handler
    objc_setAssociatedObject(webView, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

    webView.loadHTMLString(html, baseURL: baseURL)

    // Pump the run loop until rendering is done
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }

    return success
}

// MARK: - Load first page of a PDF file (keeps vector data)
// We must retain the PDFDocument, otherwise the PDFPage becomes invalid

var retainedDocs: [PDFDocument] = []  // keep docs alive until program exits

func loadPDFPage(from path: String) -> PDFPage? {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
          let page = doc.page(at: 0) else { return nil }
    retainedDocs.append(doc)
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
        // Draw original body content
        original.draw(with: box, to: ctx)

        let b = original.bounds(for: box)

        // Draw header PDF page at top (vector, no rasterization)
        if let hdr = headerPage {
            let hdrBounds = hdr.bounds(for: .mediaBox)
            ctx.saveGState()
            // Translate to top of page, scale to fit header area
            let scaleX = b.width / hdrBounds.width
            let scaleY = hdrH / hdrBounds.height
            ctx.translateBy(x: 0, y: b.height - hdrH)
            ctx.scaleBy(x: scaleX, y: scaleY)
            hdr.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }

        // Draw footer PDF page at bottom (vector, no rasterization)
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

// MARK: - Main

func printUsage() {
    fputs("Usage: md2pdf <input.md> [output.pdf] [--template <path>] [--title <title>] [--author <author>]\n", stderr)
}

var args = CommandLine.arguments; args.removeFirst()
guard !args.isEmpty else { printUsage(); exit(1) }

var inputPath: String?
var outputPath: String?
var templatePath = defaultTemplatePath
var title: String?
var author = "Martin Schwenzer"

var i = 0
while i < args.count {
    switch args[i] {
    case "--template": i += 1; if i < args.count { templatePath = args[i] }
    case "--title":    i += 1; if i < args.count { title = args[i] }
    case "--author":   i += 1; if i < args.count { author = args[i] }
    case "--help", "-h": printUsage(); exit(0)
    default:
        if inputPath == nil { inputPath = args[i] }
        else if outputPath == nil { outputPath = args[i] }
    }
    i += 1
}

guard let input = inputPath else { fputs("Error: No input\n", stderr); exit(1) }

let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
let output = outputPath ?? (inputURL.deletingPathExtension().path + ".pdf")
let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
let docTitle = title ?? inputURL.deletingPathExtension().lastPathComponent

guard FileManager.default.fileExists(atPath: templatePath) else {
    fputs("Error: Template not found\n", stderr); exit(1)
}
guard let template = TemplateConfig.load(from: templatePath) else {
    fputs("Error: Invalid template\n", stderr); exit(1)
}
guard let contentHTML = markdownToHTML(inputURL.path) else {
    fputs("Error: Markdown conversion failed\n", stderr); exit(1)
}

let dateFmt = DateFormatter()
dateFmt.dateFormat = "dd.MM.yyyy"
let dateStr = dateFmt.string(from: Date())

fputs("Converting: \(inputURL.path)\n", stderr)
fputs("Template:   \((templatePath as NSString).lastPathComponent)\n", stderr)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let pg = PageConfig()
let tmp = FileManager.default.temporaryDirectory

// Step 1: Render body PDF
fputs("Rendering body...\n", stderr)
let bodyHTML = buildBodyHTML(content: contentHTML, template: template)
let bodyPDF = tmp.appendingPathComponent("md2pdf-body.pdf").path
let bodyOk = renderHTMLToPDF(
    html: bodyHTML, baseURL: template.resourcesURL, outputPath: bodyPDF,
    paperSize: NSSize(width: pg.paperWidth, height: pg.paperHeight),
    margins: NSEdgeInsets(top: pg.marginTop, left: pg.marginLeft, bottom: pg.marginBottom, right: pg.marginRight)
)
guard bodyOk else { fputs("Error: Body render failed\n", stderr); exit(1) }

guard let bodyDoc = PDFDocument(url: URL(fileURLWithPath: bodyPDF)) else {
    fputs("Error: Cannot read body PDF\n", stderr); exit(1)
}
let pageCount = bodyDoc.pageCount
fputs("Body: \(pageCount) pages\n", stderr)

// Step 2: Render header (once — same for all pages, kept as vector PDFPage)
var headerPage: PDFPage? = nil
if let headerHTML = template.headerHTML(title: docTitle, date: dateStr) {
    fputs("Rendering header...\n", stderr)
    let headerPDFPath = tmp.appendingPathComponent("md2pdf-header.pdf").path
    let zeroMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    let hdrOk = renderHTMLToPDF(
        html: headerHTML, baseURL: template.resourcesURL, outputPath: headerPDFPath,
        paperSize: NSSize(width: pg.paperWidth, height: template.headerHeight),
        margins: zeroMargins
    )
    if hdrOk { headerPage = loadPDFPage(from: headerPDFPath) }
    // Don't delete yet — PDFPage may reference the file
}

// Step 3: Render footers (one per page, kept as vector PDFPages)
fputs("Rendering footers...\n", stderr)
var footerPages: [PDFPage?] = []
for p in 1...pageCount {
    if let footerHTML = template.footerHTML(pageNumber: p, pageCount: pageCount) {
        let footerPDFPath = tmp.appendingPathComponent("md2pdf-footer-\(p).pdf").path
        let zeroMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let ftrOk = renderHTMLToPDF(
            html: footerHTML, baseURL: template.resourcesURL, outputPath: footerPDFPath,
            paperSize: NSSize(width: pg.paperWidth, height: template.footerHeight),
            margins: zeroMargins
        )
        footerPages.append(ftrOk ? loadPDFPage(from: footerPDFPath) : nil)
    } else {
        footerPages.append(nil)
    }
}

// Step 4: Compose final PDF (all vector, no rasterization)
fputs("Composing...\n", stderr)
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

let ok = result.write(to: outputURL)

// Clean up temp files after final PDF is written
try? FileManager.default.removeItem(atPath: bodyPDF)
let hdrTmp = tmp.appendingPathComponent("md2pdf-header.pdf").path
try? FileManager.default.removeItem(atPath: hdrTmp)
for p in 1...pageCount {
    let ftrTmp = tmp.appendingPathComponent("md2pdf-footer-\(p).pdf").path
    try? FileManager.default.removeItem(atPath: ftrTmp)
}

if ok { fputs("PDF saved to: \(outputURL.path)\n", stderr) }
else { fputs("Error: Write failed\n", stderr) }
exit(ok ? 0 : 1)
