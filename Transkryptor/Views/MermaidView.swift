import SwiftUI
import WebKit

/// Renderuje diagram Mermaid jako prawdziwą grafikę (SVG) w lekkim WKWebView.
/// Biblioteka `mermaid.min.js` jest dołączona do aplikacji i wstrzykiwana lokalnie
/// (bez internetu). Wysokość dopasowuje się do wyrenderowanego diagramu.
struct MermaidView: View {
    let code: String
    @State private var height: CGFloat = 60

    var body: some View {
        MermaidWebView(code: code, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .padding(.vertical, 2)
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let code: String
    @Binding var height: CGFloat

    /// Treść biblioteki wczytana raz (3 MB) i współdzielona między diagramami.
    private static let mermaidJS: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        if let js = Self.mermaidJS {
            controller.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        controller.add(context.coordinator, name: "sizeHandler")

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(into: webView, code: code)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastCode != code {
            context.coordinator.load(into: webView, code: code)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let parent: MermaidWebView
        var lastCode = "\u{0}"   // wymuś pierwsze załadowanie
        init(_ parent: MermaidWebView) { self.parent = parent }

        func load(into webView: WKWebView, code: String) {
            lastCode = code
            let json = (try? JSONEncoder().encode(code))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            webView.loadHTMLString(Self.html(jsonCode: json), baseURL: nil)
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "sizeHandler", let num = message.body as? NSNumber else { return }
            let h = CGFloat(num.doubleValue)
            DispatchQueue.main.async {
                if abs(self.parent.height - h) > 1 { self.parent.height = max(40, h) }
            }
        }

        private static func html(jsonCode: String) -> String {
            """
            <!DOCTYPE html><html><head><meta charset="utf-8">
            <style>
              html,body{margin:0;padding:0;background:#ffffff;-webkit-text-size-adjust:100%;}
              #c{padding:14px;box-sizing:border-box;}
              .mermaid{display:flex;justify-content:center;}
              svg{max-width:100%;height:auto;}
            </style></head>
            <body>
            <div id="c"><div class="mermaid" id="d"></div></div>
            <script>
            (function(){
              function report(){ try{ window.webkit.messageHandlers.sizeHandler.postMessage(document.body.scrollHeight); }catch(e){} }
              function fail(msg){ document.getElementById('c').innerHTML='<pre style="color:#b00020;font:12px -apple-system;white-space:pre-wrap;margin:0;">'+msg+'</pre>'; report(); }
              function draw(){
                var code = \(jsonCode);
                var el = document.getElementById('d');
                el.textContent = code;
                if(typeof mermaid==='undefined'){ fail('Nie można załadować silnika diagramów.'); return; }
                try{
                  mermaid.initialize({startOnLoad:false, securityLevel:'loose', theme:'default', fontFamily:'-apple-system, system-ui, sans-serif'});
                  mermaid.run({nodes:[el]}).then(function(){ report(); setTimeout(report,120); })
                    .catch(function(e){ fail(String((e&&e.message)||e)); });
                }catch(e){ fail(String((e&&e.message)||e)); }
              }
              window.addEventListener('resize', report);
              if(document.readyState==='loading'){ document.addEventListener('DOMContentLoaded', draw); } else { draw(); }
            })();
            </script>
            </body></html>
            """
        }
    }
}
