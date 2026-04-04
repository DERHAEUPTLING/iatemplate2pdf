# iatemplate2pdf

Markdown to PDF using [iA Writer templates](https://github.com/iainc/iA-Writer-Templates). Native macOS CLI tool — same WebKit rendering engine as iA Writer, vector-sharp output.

## What it does

1. Converts Markdown to HTML (via `cmark-gfm`)
2. Applies an iA Writer `.iatemplate` bundle (CSS, fonts, layout)
3. Renders header + footer from the template (logo, page numbers, etc.)
4. Outputs a PDF that matches iA Writer's export — vector graphics, no rasterization

## Requirements

- macOS 13+
- [cmark-gfm](https://github.com/github/cmark-gfm): `brew install cmark-gfm`
- At least one `.iatemplate` bundle (ships with iA Writer, or [build your own](https://github.com/iainc/iA-Writer-Templates))

## Build

```bash
swift build -c release
```

The binary is at `.build/release/iatemplate2pdf`.

## Usage

```bash
# Basic — uses default template (DERHAEUPTLING)
iatemplate2pdf input.md

# Specify output path
iatemplate2pdf input.md output.pdf

# Use a different template
iatemplate2pdf input.md --template ~/path/to/Helvetica.iatemplate

# Set title and author (used in header/title page if template supports it)
iatemplate2pdf input.md --title "My Document" --author "Jane Doe"
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--template <path>` | Path to `.iatemplate` bundle | DERHAEUPTLING (from iA Writer) |
| `--title <text>` | Document title | Filename without extension |
| `--author <text>` | Author name | "Martin Schwenzer" |

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

## Template compatibility

Any `.iatemplate` bundle that follows the [iA Writer template spec](https://github.com/iainc/iA-Writer-Templates) should work:

- Custom header/footer with logos, page numbers, dates
- Custom fonts (must be installed on the system)
- CSS print styles
- SVG assets

## License

MIT
