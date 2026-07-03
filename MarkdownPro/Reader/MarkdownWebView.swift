import SwiftUI
import WebKit

/// Renders markdown via the bundled renderer.html (marked + highlight.js
/// + mermaid, all local — no network). Content is passed in with
/// evaluateJavaScript after the page loads.
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    /// Directory of the source file, used so relative image paths resolve.
    let baseURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // let SwiftUI background through
        context.coordinator.webView = webView

        if let rendererURL = Bundle.main.url(forResource: "renderer", withExtension: "html") {
            // Read access to / lets the page load local images referenced by docs.
            webView.loadFileURL(rendererURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(markdown: markdown, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var pageLoaded = false
        private var pending: (markdown: String, baseURL: URL?)?
        private var lastRendered: String?

        func render(markdown: String, baseURL: URL?) {
            guard pageLoaded else {
                pending = (markdown, baseURL)
                return
            }
            let key = (baseURL?.path ?? "") + "|" + markdown
            guard key != lastRendered else { return }
            lastRendered = key
            guard let webView,
                  let payload = try? JSONSerialization.data(withJSONObject: [markdown, baseURL?.absoluteString ?? ""]) else {
                return
            }
            let json = String(decoding: payload, as: UTF8.self)
            webView.evaluateJavaScript("window.renderMarkdown((\(json))[0], (\(json))[1])")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            if let pending {
                self.pending = nil
                render(markdown: pending.markdown, baseURL: pending.baseURL)
            }
        }

        // Open clicked links in the default browser instead of navigating the view.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
