# TODO — iatemplate2pdf

## Stand: 2026-04-04

### Was ist passiert

1. **Nativer MCP-Server in Swift implementiert** — kein Node.js mehr nötig
   - `Sources/MCPServer.swift` erstellt — MCP-Server über stdin/stdout (JSON-RPC)
   - `Sources/main.swift` — Subcommand `mcp-server` eingefügt
   - `Package.swift` — MCP SDK (`modelcontextprotocol/swift-sdk`) als Dependency hinzugefügt
   - Aufruf: `iatemplate2pdf mcp-server`
   - Registrierung: `claude mcp add --scope user iatemplate2pdf -- iatemplate2pdf mcp-server`

2. **Swift 6.0 / Swift 5 Language Mode Problem gelöst**
   - `swift-tools-version: 6.0` ist nötig für das MCP SDK
   - Aber Swift 6 Language Mode bricht die WebKit-Rendering-Logik (Deadlock durch `@MainActor`-Enforcement auf `WKWebView` + `DispatchSemaphore`/`RunLoop`-Pumping)
   - **Workaround:** `.swiftLanguageMode(.v5)` in Package.swift — nutzt Swift 6 Toolchain, aber Swift 5 Runtime-Semantik
   - **Offene Frage:** Wäre es besser, den Code auf Swift 6 Concurrency zu migrieren (async/await für PDFRenderer)? Das würde den Workaround überflüssig machen, ist aber deutlich mehr Aufwand. Der PDFRenderer müsste von `DispatchSemaphore`+RunLoop auf `withCheckedContinuation` umgebaut werden, und es muss sichergestellt werden, dass WebKit-Callbacks auf dem MainActor ankommen.

3. **MCP-Server nutzt Subprocess-Ansatz**
   - Direkter Aufruf von `convertFile()` im MCP-Prozess deadlockt (WebKit braucht den Main Thread, der aber vom MCP-Transport belegt ist)
   - Lösung: MCP-Server ruft sich selbst als CLI-Subprocess auf (`ProcessInfo.processInfo.arguments[0]`)
   - Gleicher Ansatz wie der alte Node.js-Server, aber ohne Node.js
   - Funktioniert, ist aber nicht elegant — jeder Tool-Call startet einen neuen Prozess

4. **Node.js MCP-Server entfernt** — `mcp/` Ordner gelöscht (war in anderer Session)

5. **CLI-Tests: 22/22 bestanden** (`scripts/test-cli.sh`)

6. **Binary-Installation via Symlink:**
   ```bash
   sudo ln -sf $(pwd)/.build/debug/iatemplate2pdf /usr/local/bin/iatemplate2pdf
   ```

### Was noch offen ist

#### MCP-Test-Script fertigstellen
- `scripts/test-mcp.sh` existiert, wurde aber noch nicht erfolgreich durchlaufen
- Das Script startet den MCP-Server, sendet JSON-RPC über stdin und prüft ob PDFs erzeugt werden
- Manueller Smoke-Test (initialize → tools/list → tools/call) hat funktioniert
- Das Script muss noch verifiziert werden

#### MCP live in Claude Code testen
- MCP-Server wurde registriert (`claude mcp add`), aber der Live-Test in einer Claude-Session stand noch aus
- Symlink muss existieren (`which iatemplate2pdf` prüfen)
- Falls Timeout-Probleme: MCP mit vollem Pfad registrieren:
  ```bash
  claude mcp add --scope user iatemplate2pdf -- /Users/nook/Sites/iatemplate2pdf/.build/debug/iatemplate2pdf mcp-server
  ```

#### Erster Release
- `git tag v1.0.0 && git push --tags` löst den GitHub Actions Workflow aus
- `.github/workflows/release.yml` existiert, baut Universal Binary (arm64 + x86_64)
- Release-Build funktioniert (`swift build -c release` getestet)
- Vor Release: alle offenen Änderungen committen

#### Offene Architektur-Frage
**Warum zwei verschiedene Swift-Versionen (`swift-tools-version: 6.0` + `.swiftLanguageMode(.v5)`)?**

Das MCP SDK braucht `swift-tools-version: 6.0`, aber der bestehende Code (PDFRenderer mit WKWebView + DispatchSemaphore + RunLoop-Pumping) funktioniert nicht unter Swift 6 Language Mode, weil Swift 6 die `@MainActor`-Isolation zur Laufzeit erzwingt. Das führt zu einem Deadlock: der Semaphore blockiert den Main Thread, und die WebKit-Callbacks, die den Semaphore signalen müssten, können nicht ausgeführt werden weil sie jetzt strikt auf dem MainActor laufen müssen.

Wäre es besser, den gesamten Code auf Swift 6 Concurrency (async/await) zu migrieren? Das würde bedeuten:
- `PDFRenderer.render()` auf `async` umbauen (mit `withCheckedContinuation` statt `DispatchSemaphore`)
- Sicherstellen dass WKWebView-Operationen auf `@MainActor` laufen
- Den MCP-Server dann direkt `convertFile()` aufrufen lassen statt Subprocess
- Kein `.swiftLanguageMode(.v5)` Workaround mehr nötig
- Eine einheitliche, zukunftssichere Codebasis

Aufwand: Moderat. Betrifft hauptsächlich `PDFRenderer` und `NavDelegate` in `main.swift`. Die restliche Logik (Markdown-Parsing, Template-Loading, Config) ist nicht betroffen.

### Geänderte Dateien (noch nicht committet)

```
modified:   Package.resolved
modified:   Package.swift
modified:   README.md
modified:   Sources/main.swift
modified:   scripts/test-cli.sh
deleted:    mcp/package-lock.json
deleted:    mcp/package.json
deleted:    mcp/server.js
deleted:    mcp/test.js
new:        Sources/MCPServer.swift
new:        scripts/test-mcp.sh
```
