import Foundation
import WebKit

/// Extracts reader-mode content from an article page headlessly, using the same
/// parser and the same media handling as the in-app `WKWebView` reader
/// (`ArticleWebView`) so the native reader shows the same result.
///
/// Both engines need the page loaded first — Readability because it reads a live
/// DOM, legibility because a page whose body is assembled by script has no body
/// until the script has run. So this loads the page in an offscreen `WKWebView`
/// (reusing the warmed process pool) and then either runs Readability inside it or
/// serializes it and hands the string to ``LegibilityEngine``. The native renderer
/// (`HTMLContentView`) turns the resulting HTML into native views.
@MainActor
public final class ReaderModeExtractor {
    public init() {}

    /// What came out of a page.
    public struct Extracted: Sendable {
        /// The reader content HTML.
        public var html: String
        /// Which parser produced it — reported rather than assumed, because it is
        /// not always the one that was asked for.
        public var engine: ReaderParserEngine
        /// True when `engine` is not the parser that was asked for, because that one
        /// could not run at all. Nook's machinery failing is not a fact about the
        /// page, so a fallback body is shown but never written to the synced cache:
        /// a later open should get another go at the parser the reader chose.
        public var fellBack: Bool
        /// How many allowlisted video/CodePen embeds the page carried that this
        /// parser drops. Always zero for Readability, which keeps them. Non-zero
        /// means the reader is missing something the page had, and should say so.
        public var droppedEmbeds: Int

        public init(
            html: String, engine: ReaderParserEngine, fellBack: Bool = false,
            droppedEmbeds: Int = 0
        ) {
            self.html = html
            self.engine = engine
            self.fellBack = fellBack
            self.droppedEmbeds = droppedEmbeds
        }
    }

    /// The result of an extraction attempt.
    public enum Outcome: Sendable {
        /// Reader content was extracted.
        case success(Extracted)
        /// The original page is gone (HTTP 404/410) — the article can be deleted.
        case gone
        /// The parser looked at the page and found no article in it. A verdict, and
        /// worth caching.
        case failed
        /// Nook ran out of time — the page never loaded, or the parse never came
        /// back. Deliberately not `.failed`: a cached `.failed` is synced and treated
        /// as authoritative for that parser on every device, and a slow network is
        /// not a fact about the page.
        case timedOut
    }

    /// Loads `url`, runs `engine`, and returns the extracted content — or a
    /// `.gone`/`.failed` outcome so the caller can distinguish a removed page
    /// (offer deletion) from a transient failure (offer retry).
    public func extract(
        url: URL,
        engine: ReaderParserEngine = .preferred,
        timeout: TimeInterval = 15
    ) async -> Outcome {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failed
        }
        return await withCheckedContinuation { continuation in
            var session: ExtractionSession!
            session = ExtractionSession(url: url, engine: engine, timeout: timeout) { [weak self] outcome in
                self?.retain.remove(session)
                continuation.resume(returning: outcome)
            }
            retain.insert(session)
            session.start()
        }
    }

    // Sessions are retained for their lifetime (they own an offscreen web view)
    // and released when they finish. Overlapping extractions (rapid navigation)
    // each keep their own session, so a new one never cancels an older one.
    private var retain: Set<ExtractionSession> = []
}

/// One offscreen extraction. Owns its web view + delegates and calls `onFinish`
/// exactly once (success, failure, or timeout), then tears everything down.
@MainActor
/// Internal rather than private so the extraction script can be exercised
/// directly by tests. It decides whether a page has an article in it, and that
/// decision was shipping untested.
final class ExtractionSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let url: URL
    private let engine: ReaderParserEngine
    private let timeout: TimeInterval
    // Optional so it can be released after firing, breaking the session↔closure
    // retain cycle (the completion captures the session to deregister it).
    private var onFinish: ((ReaderModeExtractor.Outcome) -> Void)?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var parseTask: Task<Void, Never>?
    private var finished = false

    init(
        url: URL,
        engine: ReaderParserEngine,
        timeout: TimeInterval,
        onFinish: @escaping (ReaderModeExtractor.Outcome) -> Void
    ) {
        self.url = url
        self.engine = engine
        self.timeout = timeout
        self.onFinish = onFinish
    }

    func start() {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WebViewWarmer.processPool
        // Share the persistent session so extraction sees the same logged-in state
        // as the browser (e.g. subscriber-only articles).
        configuration.websiteDataStore = WebViewWarmer.dataStore
        let controller = configuration.userContentController
        // Readability is injected whichever engine was asked for: it is what the
        // legibility path falls back to when the engine itself cannot run, and by
        // then the page is loaded and there is no second chance to inject.
        if let readability = ArticleWebView.readabilitySource {
            controller.addUserScript(WKUserScript(source: readability, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.addUserScript(WKUserScript(source: Self.script(for: engine), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(self, name: "nookExtract")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // A non-zero frame so pages that gate content on a viewport still lay out
        // and expose their article body to the parser, even though this web view
        // is never shown.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        startDeadline(seconds: timeout)
        webView.load(URLRequest(url: url))
    }

    /// (Re)starts the give-up timer.
    ///
    /// Two budgets, one after the other, rather than one covering both: fetching the
    /// page and parsing it are independent waits, and sharing a single fifteen
    /// seconds meant a slow article page could leave the parser almost none — then
    /// record its own starvation as "this page has no article in it", on every
    /// device.
    private func startDeadline(seconds: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish(.timedOut)
        }
    }

    private func finish(_ outcome: ReaderModeExtractor.Outcome) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        parseTask?.cancel()
        parseTask = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "nookExtract")
            webView.configuration.userContentController.removeAllUserScripts()
        }
        webView = nil
        let callback = onFinish
        onFinish = nil
        callback?(outcome)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nookExtract", let body = message.body as? [String: Any] else { return }

        // The legibility path posts the page, not an article: the engine runs
        // natively, in its own web view, and the answer comes back here.
        if let source = body["source"] as? String {
            // The page is in hand; the parse gets its own clock.
            startDeadline(seconds: Self.parseTimeout)
            embedsOnPage = (body["embeds"] as? NSNumber)?.intValue ?? 0
            startLegibilityParse(firstSource: source)
            return
        }

        if (body["ok"] as? NSNumber)?.boolValue == true,
           let content = body["content"] as? String,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Readability keeps the allowlisted embeds, so nothing was dropped.
            finish(.success(.init(html: content, engine: .readability)))
        } else {
            finish(.failed)
        }
    }

    /// How long the parse itself may take once the page has arrived. Generous
    /// because the first legibility call of a session also compiles a 669 KB
    /// WebAssembly module, and because calls queue behind each other.
    private static let parseTimeout: TimeInterval = 25

    /// Allowlisted video/CodePen embeds the page carried, counted before parsing so
    /// the reader can say what legibility removed.
    private var embedsOnPage = 0

    // MARK: The legibility path

    /// Runs legibility over the serialized page, re-asking the page for a fresh
    /// snapshot if the first one had nothing in it yet.
    ///
    /// The retry is here rather than in the page because only this side knows
    /// whether the engine found an article. A page whose body arrives by script may
    /// genuinely have none at `DOMContentLoaded`, which is the same case the
    /// Readability driver retries for — and re-snapshotting costs nothing, since
    /// the page is already loaded.
    private func startLegibilityParse(firstSource: String) {
        guard parseTask == nil, !finished else { return }
        parseTask = Task { [weak self] in
            guard let self else { return }
            var source = firstSource
            for attempt in 0..<3 {
                if Task.isCancelled || finished { return }
                switch await LegibilityEngine.shared.extract(document: source) {
                case .article(let extraction):
                    if let html = Self.renderable(extraction) {
                        finish(
                            .success(
                                .init(
                                    html: html, engine: .legibility,
                                    droppedEmbeds: embedsOnPage)))
                        return
                    }
                case .noArticle:
                    break
                case .unavailable:
                    // The engine, not the page, is the problem — the resource is
                    // missing, the module trapped, the call timed out. Readability
                    // is already injected and the page is still up, so use it
                    // rather than tell the reader this page has no article.
                    await finishWithReadabilityFallback()
                    return
                }
                if attempt == 2 { break }
                try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
                // Only re-parse a document that actually changed. The retry exists
                // for a page still assembling itself by script; on a static index
                // page — the commonest input that legitimately has no article, and
                // often the largest — re-running the engine over identical bytes
                // three times just re-derives the same verdict at triple the cost.
                guard let refreshed = await currentSource(), !refreshed.isEmpty,
                      refreshed != source
                else { break }
                source = refreshed
            }
            if !finished { finish(.failed) }
        }
    }

    /// The markup to render for an extraction, or nil when there is nothing to show.
    ///
    /// A link submission — a Hacker News or Reddit post that is a headline and an
    /// outbound URL — has an empty body by construction. Returning nothing for it
    /// would report a failure for a page that was read perfectly well, so it
    /// renders as the link it is.
    private static func renderable(_ extraction: LegibilityEngine.Extraction) -> String? {
        let html = extraction.html.trimmingCharacters(in: .whitespacesAndNewlines)
        if !html.isEmpty { return extraction.html }
        guard extraction.isLinkOnly, let link = extraction.linkURL else { return nil }
        let escaped = link.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return "<p><a href=\"\(escaped)\">\(escaped)</a></p>"
    }

    private func currentSource() async -> String? {
        guard let webView else { return nil }
        return try? await webView.evaluateJavaScript("window.__nook ? window.__nook.source() : ''") as? String
    }

    /// Runs Readability because legibility could not run at all.
    ///
    /// If this also finds nothing, the outcome is `.timedOut` and not `.failed`. The
    /// parser the reader chose never actually rendered a verdict about this page, and
    /// `.failed` is written to the synced cache and then believed on every device —
    /// so a cold start on a loaded phone would permanently record "no article here"
    /// for a page legibility reads fine.
    private func finishWithReadabilityFallback() async {
        guard let webView, !finished else {
            if !finished { finish(.timedOut) }
            return
        }
        let json = try? await webView.evaluateJavaScript(
            "JSON.stringify(window.__nook ? (window.__nook.readability() || null) : null)") as? String
        guard let json, let data = json.data(using: .utf8),
              let article = try? JSONDecoder().decode(ReadabilityArticle.self, from: data),
              let content = article.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            finish(.timedOut)
            return
        }
        // `fellBack`: the reader asked for legibility and got Readability because
        // legibility could not run. Shown, but never written to the synced cache —
        // otherwise one cold start pins the article to the parser nobody chose, on
        // every device, permanently.
        finish(.success(.init(html: content, engine: .readability, fellBack: true)))
    }

    private struct ReadabilityArticle: Decodable {
        var title: String?
        var byline: String?
        var content: String?
    }

    // MARK: WKNavigationDelegate

    /// Inspect the main-frame response status: a 404/410 means the original is
    /// gone, so report `.gone` (the reader offers deletion) instead of loading the
    /// server's error page and trying to extract from it.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode == 404 || http.statusCode == 410 {
            decisionHandler(.cancel)
            finish(.gone)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failed)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failed)
    }

    /// The page-side driver: `ReaderParserScripts.shared` plus whichever engine's
    /// driver was asked for.
    ///
    /// `nonisolated` because it is string concatenation: the session is
    /// `@MainActor` for the web view it owns, and its scripts should be readable
    /// from a test that has no reason to be on the main actor.
    nonisolated static func script(for engine: ReaderParserEngine) -> String {
        ReaderParserScripts.shared + "\n" + driver(for: engine)
    }

    /// Kept for the tests that pin the Readability path's behaviour, and because
    /// that path is what every other engine is compared against.
    nonisolated static let extractionScript = script(for: .readability)

    nonisolated private static func driver(for engine: ReaderParserEngine) -> String {
        switch engine {
        case .readability: readabilityDriver
        case .legibility: legibilityDriver
        }
    }

    /// Runs after the page settles: extracts with Readability and posts the cleaned
    /// content HTML back to native. Retries briefly for script-heavy pages.
    nonisolated private static let readabilityDriver = """
    (function () {
      var attempts = 0;

      function done(payload) {
        try { window.webkit.messageHandlers.nookExtract.postMessage(payload); } catch (e) {}
      }

      function run() {
        try {
          var article = window.__nook.readability();
          if (!article) {
            attempts += 1;
            if (attempts < 3) { setTimeout(run, attempts * 300); return; }
            done({ ok: false });
            return;
          }
          done({ ok: true, title: article.title || '', byline: article.byline || '', content: article.content || '' });
        } catch (error) {
          done({ ok: false });
        }
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', run, { once: true });
      } else {
        setTimeout(run, 0);
      }
    })();
    """

    /// Posts the page itself, once. legibility runs natively, in its own web view;
    /// this side's only job is to hand over a snapshot with absolute URLs in it.
    nonisolated private static let legibilityDriver = """
    (function () {
      function run() {
        try {
          window.webkit.messageHandlers.nookExtract.postMessage({
            source: window.__nook.source(),
            embeds: window.__nook.embedCount()
          });
        } catch (e) {
          try { window.webkit.messageHandlers.nookExtract.postMessage({ ok: false }); } catch (_) {}
        }
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', run, { once: true });
      } else {
        setTimeout(run, 0);
      }
    })();
    """
}
