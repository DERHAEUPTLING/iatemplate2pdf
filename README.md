# iatemplate2pdf

Markdown to PDF using [iA Writer templates](https://github.com/iainc/iA-Writer-Templates). Native macOS CLI tool — same WebKit rendering engine as iA Writer, vector-sharp output.

## What it does

1. Converts Markdown to HTML (via statically linked cmark-gfm — no external dependencies)
2. Applies an iA Writer `.iatemplate` bundle (CSS, fonts, layout)
3. Renders header + footer from the template (logo, page numbers, etc.)
4. Outputs a PDF that matches iA Writer's export — vector graphics, no rasterization

## Requirements

- macOS 13+
- At least one `.iatemplate` bundle (ships with iA Writer, or [build your own](https://github.com/iainc/iA-Writer-Templates))

## Install

### From source (recommended)

```bash
git clone https://github.com/DERHAEUPTLING/iatemplate2pdf.git
cd iatemplate2pdf
swift build -c release
# Optionally copy to PATH:
cp .build/release/iatemplate2pdf /usr/local/bin/
```

### From GitHub Release

Download the universal binary (arm64 + x86_64) from [Releases](https://github.com/DERHAEUPTLING/iatemplate2pdf/releases):

```bash
curl -sL https://github.com/DERHAEUPTLING/iatemplate2pdf/releases/latest/download/iatemplate2pdf-macos-universal.tar.gz | tar xz
sudo mv iatemplate2pdf /usr/local/bin/
```

## Setup

On first use, iatemplate2pdf will detect installed iA Writer templates and ask you to choose a default:

```
No default template configured.

Available templates:

  [1] Helvetica
  [2] DERHAEUPTLING
  [3] Letter

Choose default template [1-3]: 2
Default template set to: DERHAEUPTLING
```

You can change this anytime:

```bash
iatemplate2pdf --setup               # Choose interactively
iatemplate2pdf --list-templates       # Show available templates
```

The config is stored in `~/.config/iatemplate2pdf/config.json`.

## Usage

```bash
# Single file
iatemplate2pdf doc.md

# Specify output path
iatemplate2pdf doc.md output.pdf

# Use a different template (one-off)
iatemplate2pdf doc.md --template ~/path/to/Custom.iatemplate

# Set title and author (used in header)
iatemplate2pdf doc.md --title "My Document" --author "Jane Doe"

# Batch conversion
iatemplate2pdf *.md --output-dir ./export/
```

### Options

| Flag                  | Description                           | Default            |
| --------------------- | ------------------------------------- | ------------------ |
| `--template <path>`   | Path to `.iatemplate` bundle          | Saved default      |
| `--title <text>`      | Document title                        | Filename           |
| `--author <text>`     | Author name                           | "Martin Schwenzer" |
| `--output-dir <path>` | Output directory for batch conversion | —                  |
| `--setup`             | Choose default template interactively | —                  |
| `--list-templates`    | Show available templates              | —                  |

## MCP Server

iatemplate2pdf includes an MCP server for use with Claude Code and other MCP clients.

### Register globally in Claude Code

```bash
claude mcp add --scope user iatemplate2pdf -- node /path/to/iatemplate2pdf/mcp/server.js
```

### MCP Tool

**`iatemplate2pdf`** — Convert Markdown files to PDF

Parameters:

- `files` (required): Array of absolute paths to `.md` files
- `output_dir` (optional): Output directory for PDFs
- `template` (optional): Path to `.iatemplate` bundle
- `title` (optional): Document title (single file only)
- `author` (optional): Author name

## How it works

iA Writer templates are macOS bundles containing HTML, CSS, and JavaScript:

```
Example.iatemplate/
  Contents/
    Info.plist          # Header/footer height, file references
    Resources/
      document.html     # Body layout
      header.html       # Header (logo, title, date)
      footer.html       # Footer (page numbers, branding)
      style.css         # Typography and layout
      *.svg             # Logos and icons
```

iatemplate2pdf reads `Info.plist` for configuration, inlines all CSS and SVG resources, then renders body, header, and footer as separate vector PDFs via macOS WebKit (`WKWebView` + `NSPrintOperation`). The final PDF is composed with PDFKit — everything stays vector, nothing gets rasterized.

## Tests

```bash
# CLI tests
./scripts/test-cli.sh

# MCP tests
node mcp/test.js
```

## Author

Built by Martin Schwenzer — [DER HÄUPTLING](https://derhaeuptling.de), Webdesign, SEO and online Marketing.

## License

MIT
