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

### From GitHub Release (recommended)

Download the universal binary (arm64 + x86_64) from [Releases](https://github.com/DERHAEUPTLING/iatemplate2pdf/releases):

```bash
curl -sL https://github.com/DERHAEUPTLING/iatemplate2pdf/releases/latest/download/iatemplate2pdf-macos-universal.tar.gz | tar xz
sudo mv iatemplate2pdf /usr/local/bin/
```

### From source

Requires Swift 6+ (ships with Xcode 16+). Compiles the binary locally:

```bash
git clone https://github.com/DERHAEUPTLING/iatemplate2pdf.git
cd iatemplate2pdf
swift build
# Symlink into PATH (survives rebuilds):
sudo ln -sf "$(pwd)/.build/debug/iatemplate2pdf" /usr/local/bin/iatemplate2pdf
```

## Setup

On first use, iatemplate2pdf will detect installed iA Writer templates and ask you to choose a default template and set your author name:

```
No default template configured.

Available templates:

  [1] Helvetica
  [2] DERHAEUPTLING
  [3] Letter

Choose default template [1-3]: 2
Default template set to: DERHAEUPTLING

Author name [Martin Schwenzer]: Martin Schwenzer
Author set to: Martin Schwenzer
```

You can change this anytime:

```bash
iatemplate2pdf --setup               # Configure template & author
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

# Override title and author for a single conversion
iatemplate2pdf doc.md --title "My Document" --author "Jane Doe"

# Batch conversion
iatemplate2pdf *.md --output-dir ./export/
```

### Options

| Flag                  | Description                           | Default                    |
| --------------------- | ------------------------------------- | -------------------------- |
| `--template <path>`   | Path to `.iatemplate` bundle          | Saved config               |
| `--title <text>`      | Document title (single file only)     | First H1 heading           |
| `--author <text>`     | Author name                           | Saved config / system user |
| `--output-dir <path>` | Output directory for batch conversion | —                          |
| `--setup`             | Configure default template and author | —                          |
| `--list-templates`    | Show available templates              | —                          |
| `--non-interactive`   | Never prompt for input (scripts/MCP)  | Auto-detected via TTY      |

## MCP Server

iatemplate2pdf includes a native MCP server — no Node.js required. The same binary handles both CLI and MCP modes.

### Register globally in Claude Code

```bash
claude mcp add --scope user iatemplate2pdf -- iatemplate2pdf mcp-server
```

### MCP Tool

**`iatemplate2pdf`** — Convert Markdown files to PDF

Parameters:

- `files` (required): Array of absolute paths to `.md` files
- `output_dir` (optional): Output directory for PDFs
- `template` (optional): Path to `.iatemplate` bundle
- `title` (optional): Document title (single file only; default: first H1)
- `author` (optional): Author name

If `template` or `author` are not provided and not configured, the MCP server returns a helpful message listing available templates or asking for the author name — so the LLM can ask the user and call again with the correct parameters.

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
swift build

# CLI tests
./scripts/test-cli.sh

# MCP server tests
./scripts/test-mcp.sh
```

## Planned Features

- **Configurable paper size:** Currently hardcoded to A4 (595.28 × 841.89 pt). Could support US Letter, Legal, etc. via `--paper-size` flag and `config.json` default.

## Author

Built by Martin Schwenzer — [DER HÄUPTLING](https://derhaeuptling.de), Webdesign, SEO and online Marketing.

## License

MIT
