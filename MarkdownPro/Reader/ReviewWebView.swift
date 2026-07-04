import SwiftUI
import WebKit
import MarkdownProCore

/// A text selection captured in the rendered document, with W3C
/// TextQuoteSelector context so it can be re-anchored later.
struct ReviewSelection: Equatable {
    var quote: String
    var prefix: String
    var suffix: String
}

/// The Review Center's document pane: renderer.html plus the annotation
/// layer, bridged over the "review" script-message handler.
struct ReviewWebView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    /// Current-round open annotations, painted as highlights.
    let annotations: [MarkdownProCore.Annotation]
    var onSelection: (ReviewSelection) -> Void
    var onAnnotationClicked: (Int64) -> Void
    var onAnchors: ([Int64: Bool]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "review")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        if let rendererURL = Bundle.main.url(forResource: "renderer", withExtension: "html") {
            webView.loadFileURL(rendererURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.push(markdown: markdown, baseURL: baseURL, annotations: annotations)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // The content controller retains the handler; break the cycle.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "review")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReviewWebView
        weak var webView: WKWebView?
        private var pageLoaded = false
        private var lastRendered: String?
        private var lastAnnotationsJSON: String?

        init(_ parent: ReviewWebView) {
            self.parent = parent
        }

        func push(markdown: String, baseURL: URL?, annotations: [MarkdownProCore.Annotation]) {
            guard pageLoaded, let webView else { return }

            // Annotations first: renderMarkdown ends with __reviewRepaint().
            let list = annotations.map { a -> [String: Any] in
                ["id": a.id, "quote": a.quote, "prefix": a.prefix, "suffix": a.suffix]
            }
            if let data = try? JSONSerialization.data(withJSONObject: list) {
                let json = String(decoding: data, as: UTF8.self)
                if json != lastAnnotationsJSON {
                    lastAnnotationsJSON = json
                    webView.evaluateJavaScript("window.setReviewAnnotations(\(json))")
                }
            }

            let key = (baseURL?.path ?? "") + "|" + markdown
            if key != lastRendered {
                lastRendered = key
                if let payload = try? JSONSerialization.data(withJSONObject: [markdown, baseURL?.absoluteString ?? ""]) {
                    let json = String(decoding: payload, as: UTF8.self)
                    webView.evaluateJavaScript("window.renderMarkdown((\(json))[0], (\(json))[1])")
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            push(markdown: parent.markdown, baseURL: parent.baseURL, annotations: parent.annotations)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "selection":
                let selection = ReviewSelection(quote: body["quote"] as? String ?? "",
                                                prefix: body["prefix"] as? String ?? "",
                                                suffix: body["suffix"] as? String ?? "")
                guard !selection.quote.isEmpty else { return }
                parent.onSelection(selection)
            case "annotationClicked":
                if let id = body["id"] as? Int { parent.onAnnotationClicked(Int64(id)) }
            case "anchors":
                guard let map = body["anchored"] as? [String: Bool] else { return }
                var anchored: [Int64: Bool] = [:]
                for (key, value) in map {
                    if let id = Int64(key) { anchored[id] = value }
                }
                parent.onAnchors(anchored)
            default:
                break
            }
        }

        // Open clicked links in the default browser (same as MarkdownWebView).
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
