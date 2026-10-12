import Foundation
import UIKit
import WebKit

struct DetectedVideo: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let pageURL: URL?
    let title: String

    var isStream: Bool { url.absoluteString.lowercased().contains(".m3u8") }
}

/// Avoids the retain cycle WKUserContentController creates with its message handlers.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

final class BrowserTab: NSObject, ObservableObject, Identifiable {
    static let messageName = "veilVideo"
    static var userAgent: String?

    let id = UUID()
    let isPrivate: Bool
    let webView: WKWebView

    @Published var title = "New Tab"
    @Published var url: URL?
    @Published var progress = 0.0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var videos: [DetectedVideo] = []
    @Published var insecureOffer: URL?
    /// A restored tab's address. It loads the first time the tab is shown, so a launch
    /// with many saved tabs doesn't load them all at once.
    @Published private(set) var pendingURL: URL?

    private var observations: [NSKeyValueObservation] = []
    private var upgradedHosts = Set<String>()
    private var allowedHTTPHosts = Set<String>()
    private var lastUpgrade: (host: String, time: Date)?

    init(isPrivate: Bool, blockList: WKContentRuleList?) {
        self.isPrivate = isPrivate

        let config = WKWebViewConfiguration()
        // Private tabs each get their own throwaway store, so nothing is shared or kept.
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        config.allowsInlineMediaPlayback = true

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: VideoSniffer.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        if let blockList { controller.add(blockList) }
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        controller.add(WeakScriptHandler(self), name: Self.messageName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observe()

        if Self.userAgent == nil {
            webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                BrowserTab.userAgent = result as? String
            }
        }
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
    }

    private func observe() {
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in self?.progress = wv.estimatedProgress },
            webView.observe(\.title) { [weak self] wv, _ in
                let t = wv.title ?? ""
                self?.title = t.isEmpty ? (wv.url?.host ?? "New Tab") : t
            },
            webView.observe(\.url) { [weak self] wv, _ in self?.url = wv.url },
            webView.observe(\.isLoading) { [weak self] wv, _ in self?.isLoading = wv.isLoading },
            webView.observe(\.canGoBack) { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
            webView.observe(\.canGoForward) { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
        ]
    }

    // MARK: Actions

    func load(input: String) {
        guard let destination = AppSettings.destination(for: input) else { return }
        load(destination)
    }

    func load(_ url: URL) {
        insecureOffer = nil
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    /// The address to save for this tab, whether or not it has loaded yet.
    var savedURL: URL? { url ?? pendingURL }

    func restore(_ url: URL) {
        pendingURL = url
        title = url.host ?? "Restored Tab"
    }

    func loadPendingIfNeeded() {
        if let pending = pendingURL { load(pending) }
    }

    func setBlocking(_ list: WKContentRuleList?) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let list { controller.add(list) }
    }

    func allowInsecure() {
        guard let offer = insecureOffer, let host = offer.host else { return }
        allowedHTTPHosts.insert(host)
        insecureOffer = nil
        webView.load(URLRequest(url: offer))
    }

    /// Passes the page's own cookies along as a header so the download works on sites
    /// that need a login, without copying those cookies anywhere they would persist.
    func download(_ video: DetectedVideo) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let host = video.url.host ?? ""
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == domain || host.hasSuffix("." + domain)
            }
            var headers = HTTPCookie.requestHeaderFields(with: matching)
            if let page = video.pageURL { headers["Referer"] = page.absoluteString }
            if let agent = BrowserTab.userAgent { headers["User-Agent"] = agent }
            DownloadManager.shared.start(video, headers: headers)
        }
    }

    fileprivate func addVideo(url: URL, page: URL?, title: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !videos.contains(where: { $0.url == url }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        videos.append(DetectedVideo(url: url, pageURL: page, title: clean.isEmpty ? url.lastPathComponent : clean))
    }
}

// MARK: - Navigation

extension BrowserTab: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        // HTTPS Only: upgrade plain http page loads.
        if scheme == "http", AppSettings.httpsOnly,
           action.targetFrame?.isMainFrame ?? true,
           let host = url.host, !allowedHTTPHosts.contains(host),
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // A site that redirects https back to http would loop forever. If the same host
            // comes back as http right after an upgrade, stop and offer the insecure banner.
            if let last = lastUpgrade, last.host == host, Date().timeIntervalSince(last.time) < 5 {
                lastUpgrade = nil
                decisionHandler(.cancel)
                insecureOffer = url
                return
            }
            parts.scheme = "https"
            if parts.port == 80 { parts.port = nil }
            if let secure = parts.url {
                upgradedHosts.insert(host)
                lastUpgrade = (host, Date())
                decisionHandler(.cancel)
                webView.load(URLRequest(url: secure))
                return
            }
        }

        // Hand mailto:, tel: and app links to iOS.
        if !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let mime = response.response.mimeType ?? ""
        if mime.hasPrefix("video/"), let url = response.response.url {
            addVideo(url: url, page: webView.url, title: response.response.suggestedFilename ?? url.lastPathComponent)
            if !response.canShowMIMEType {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        videos = []
        insecureOffer = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled,
              let failing = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
              failing.scheme == "https",
              let host = failing.host, upgradedHosts.contains(host),
              var parts = URLComponents(url: failing, resolvingAgainstBaseURL: false) else { return }
        parts.scheme = "http"
        insecureOffer = parts.url
    }
}

extension BrowserTab: WKUIDelegate {
    /// Links that try to open a new window load in the current tab instead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }
}

extension BrowserTab: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let raw = body["url"] as? String,
              let url = URL(string: raw) else { return }
        let page = (body["page"] as? String).flatMap { URL(string: $0) }
        let title = (body["title"] as? String) ?? ""
        addVideo(url: url, page: page, title: title)
    }
}
