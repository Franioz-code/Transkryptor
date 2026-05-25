import AppKit
import WebKit

/// Renderuje diagramy (mermaid) i wzory (LaTeX/mhchem przez MathJax) do obrazów PNG,
/// używając ukrytego WKWebView. Dzięki temu w notatkach są zwykłymi obrazami — wyglądają
/// dobrze i przechodzą do Apple Notes / PDF tak samo jak zrzuty ekranu.
@MainActor
final class DiagramRasterizer: NSObject, WKNavigationDelegate {
    static let shared = DiagramRasterizer()

    private var webView: WKWebView?
    private var window: NSWindow?
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var isLoaded = false

    private let canvasWidth: CGFloat = 1600
    private let canvasHeight: CGFloat = 2600

    private static func bundleJS(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    private static let mermaidJS = bundleJS("mermaid.min")
    private static let mathJaxJS = bundleJS("tex-svg-full")

    // MARK: - Publiczne API

    func renderMermaid(_ code: String) async -> Data? { await render(kind: "mermaid", source: code) }
    func renderMath(_ latex: String) async -> Data? { await render(kind: "math", source: latex) }

    /// Przetwarza Markdown notatek: zamienia bloki ```mermaid oraz wzory `$$…$$` / `\[…\]`
    /// na osadzone obrazy. Przy niepowodzeniu render zostawia oryginalny blok (bezpieczny fallback).
    func process(markdown: String, course: String, title: String, date: Date,
                 storage: StorageService) async -> String {
        guard markdown.contains("```mermaid") || markdown.contains("$$") || markdown.contains("\\[") else {
            return markdown
        }

        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var diagramN = 0
        var mathN = 0

        func emitImage(_ data: Data, math: Bool) -> Bool {
            let name: String
            if math { mathN += 1; name = String(format: "wzor-%02d.png", mathN) }
            else { diagramN += 1; name = String(format: "diagram-%02d.png", diagramN) }
            guard let rel = try? storage.saveAssetImage(data, name: name, course: course, title: title, date: date)
            else { return false }
            out.append("![\(math ? "Wzór" : "Diagram")](\(rel))")
            return true
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blok ```mermaid … ```
            if trimmed.hasPrefix("```"),
               trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "mermaid" {
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 } // zamykające ```
                let code = body.joined(separator: "\n")
                if let data = await renderMermaid(code), emitImage(data, math: false) { continue }
                out.append("```mermaid"); out.append(contentsOf: body); out.append("```")
                continue
            }

            // Blok $$ … $$ (otwierający na osobnej linii)
            if trimmed == "$$" {
                var body: [String] = []
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                    body.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                let latex = body.joined(separator: "\n")
                if let data = await renderMath(latex), emitImage(data, math: true) { continue }
                out.append("$$"); out.append(contentsOf: body); out.append("$$")
                continue
            }

            // Jednolinijkowe $$ … $$
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
                let latex = String(trimmed.dropFirst(2).dropLast(2))
                if let data = await renderMath(latex), emitImage(data, math: true) { i += 1; continue }
                out.append(line); i += 1; continue
            }

            // Blok \[ … \]
            if trimmed == "\\[" {
                var body: [String] = []
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "\\]" {
                    body.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                let latex = body.joined(separator: "\n")
                if let data = await renderMath(latex), emitImage(data, math: true) { continue }
                out.append("\\["); out.append(contentsOf: body); out.append("\\]")
                continue
            }
            if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
                let latex = String(trimmed.dropFirst(2).dropLast(2))
                if let data = await renderMath(latex), emitImage(data, math: true) { i += 1; continue }
                out.append(line); i += 1; continue
            }

            out.append(line)
            i += 1
        }
        // Zwolnij WebView (z ~5 MB bibliotek + proces WebKita) — diagramy są rzadkie,
        // więc nie trzymamy go w pamięci między generacjami.
        teardown()
        return out.joined(separator: "\n")
    }

    /// Zwalnia WebView i okno renderujące, oddając pamięć systemowi.
    private func teardown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        webView?.navigationDelegate = nil
        webView = nil
        isLoaded = false
    }

    // MARK: - Render

    private func render(kind: String, source: String) async -> Data? {
        let clean = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        await setup()
        guard let webView else { return nil }
        do {
            // Mostek przez completionHandler — bezpośrednie `try await` rozwiązywało się do
            // przeciążenia zwracającego Void (wynik [w,h] był gubiony → render zawsze nil).
            let result: Any = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
                webView.callAsyncJavaScript(
                    "return await window.__render(kind, src);",
                    arguments: ["kind": kind, "src": clean],
                    in: nil,
                    in: .page
                ) { cont.resume(with: $0) }
            }
            guard let arr = result as? [Any], arr.count == 2,
                  let w = (arr[0] as? NSNumber)?.doubleValue,
                  let h = (arr[1] as? NSNumber)?.doubleValue,
                  w >= 1, h >= 1 else { return nil }

            try? await Task.sleep(for: .milliseconds(40))

            // createPDF renderuje przez proces WebKita (nie zrzut ekranu) — działa
            // bezgłowo, w tle i niezależnie od widoczności okna/Spaces.
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0,
                                 width: min(w, Double(canvasWidth)),
                                 height: min(h, Double(canvasHeight)))
            let pdf: Data = try await withCheckedThrowingContinuation { cont in
                webView.createPDF(configuration: config) { cont.resume(with: $0) }
            }
            return Self.png(fromPDF: pdf)
        } catch {
            return nil
        }
    }

    // MARK: - Konfiguracja WebView

    private func setup() async {
        if isLoaded { return }
        if webView == nil { build() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loadContinuation = c
            webView?.loadHTMLString(Self.pageHTML, baseURL: nil)
        }
        isLoaded = true
    }

    private func build() {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.mathJaxConfig,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let mathJax = Self.mathJaxJS {
            controller.addUserScript(WKUserScript(source: mathJax,
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let mermaid = Self.mermaidJS {
            controller.addUserScript(WKUserScript(source: mermaid,
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let frame = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let wv = WKWebView(frame: frame, configuration: config)
        wv.navigationDelegate = self

        // Niewidoczne okno (alpha 0) trzymające WebView „przy życiu". createPDF renderuje
        // przez proces WebKita (nie zrzut ekranu), więc nie wymaga malowania okna — ale gdy
        // WebView nie jest w żadnym oknie, system usypia jego proces i PDF wychodzi pusty.
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.alphaValue = 0
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.level = .normal
        win.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        win.contentView = wv
        win.setFrameOrigin(.zero)
        win.orderFrontRegardless()

        webView = wv
        window = win
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    /// Rasteryzuje PDF (z createPDF) do PNG w 2× dla ostrości, na białym tle.
    private static func png(fromPDF data: Data) -> Data? {
        guard let pdfImage = NSImage(data: data) else { return nil }
        let size = pdfImage.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.set()
        NSRect(origin: .zero, size: size).fill()
        pdfImage.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - HTML / JS

    private static let mathJaxConfig = """
    window.MathJax = {
      startup: { typeset: false },
      svg: { fontCache: 'none' },
      options: { enableMenu: false }
    };
    """

    private static let pageHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>
      html,body{margin:0;padding:0;background:#ffffff;}
      #stage{display:inline-block;padding:14px;background:#ffffff;
             font-family:-apple-system,system-ui,sans-serif;color:#111;}
      #stage svg{display:block;}
      mjx-container{margin:0 !important;}
      mjx-container svg{font-size:140%;}
    </style></head><body><div id="stage"></div>
    <script>
    window.__render = async function(kind, src){
      var stage = document.getElementById('stage');
      stage.innerHTML = '';
      if(kind === 'mermaid'){
        if(typeof mermaid === 'undefined') throw new Error('mermaid-missing');
        var el = document.createElement('div');
        el.className = 'mermaid';
        el.textContent = src;
        stage.appendChild(el);
        await mermaid.run({nodes:[el]});
      } else {
        if(typeof MathJax === 'undefined') throw new Error('mathjax-missing');
        var node = await MathJax.tex2svgPromise(src, {display:true});
        stage.appendChild(node);
      }
      void stage.offsetWidth;
      var r = stage.getBoundingClientRect();
      return [Math.ceil(r.width), Math.ceil(r.height)];
    };
    if(typeof mermaid !== 'undefined'){
      mermaid.initialize({startOnLoad:false, securityLevel:'loose', theme:'default',
                          fontFamily:'-apple-system, system-ui, sans-serif'});
    }
    </script></body></html>
    """
}
