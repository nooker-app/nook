import Foundation
import Testing
import WebKit

@testable import NookKit

/// The preference itself, and the script contract the two parsers share.
@MainActor
@Suite("Reader parser engine")
struct ReaderParserEngineTests {
    /// legibility is the default, and the default is what a device with no stored
    /// preference gets — including one upgrading from a build that had no setting.
    @Test("legibility is the default")
    func defaultsToLegibility() {
        #expect(ReaderParserEngine.fallback == .legibility)

        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: ReaderParserEngine.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: ReaderParserEngine.storageKey)
            } else {
                defaults.removeObject(forKey: ReaderParserEngine.storageKey)
            }
        }

        defaults.removeObject(forKey: ReaderParserEngine.storageKey)
        #expect(ReaderParserEngine.preferred == .legibility)

        // The Settings picker writes the raw value; the extractor reads it back.
        // Storing an enum on one side and a string on the other is a setting that
        // appears to reset itself, so the round trip is worth pinning.
        defaults.set(ReaderParserEngine.readability.rawValue, forKey: ReaderParserEngine.storageKey)
        #expect(ReaderParserEngine.preferred == .readability)

        defaults.set("something else entirely", forKey: ReaderParserEngine.storageKey)
        #expect(ReaderParserEngine.preferred == .legibility, "an unreadable value falls back, it does not crash")
    }

    @Test("the switch flips between exactly two parsers")
    func otherFlips() {
        #expect(ReaderParserEngine.legibility.other == .readability)
        #expect(ReaderParserEngine.readability.other == .legibility)
        #expect(ReaderParserEngine.allCases.count == 2, "the reader's switch assumes there are two")
    }

    /// The names are proper nouns and stay in Latin script in every language: a
    /// reader who wants to know which extractor produced a page is not helped by a
    /// translated euphemism.
    @Test("each parser has a name and a description")
    func labelsAndSummaries() {
        for engine in ReaderParserEngine.allCases {
            #expect(!engine.label.isEmpty)
            #expect(!engine.summary.isEmpty)
            #expect(!engine.symbolName.isEmpty)
        }
        #expect(ReaderParserEngine.legibility.label == "Legibility")
        #expect(ReaderParserEngine.readability.label == "Readability")
    }

    // MARK: - The page-side contract

    /// Both drivers are built on one shared helper script, which is the only reason
    /// the native reader and the browser's reader mode agree about what the article
    /// is. They held two copies of it and it drifted twice.
    @Test("both drivers carry the shared helpers")
    func driversShareOneImplementation() {
        for engine in ReaderParserEngine.allCases {
            let script = ExtractionSession.script(for: engine)
            #expect(script.contains("window.__nook = {"), "\(engine.label)'s driver is missing the shared helpers")
        }
    }

    /// legibility takes a string and has no base URL to resolve against, so the
    /// snapshot has to carry absolute URLs or every image and link in the extracted
    /// body is broken.
    @Test("the page snapshot makes URLs absolute")
    func snapshotAbsolutizesURLs() async throws {
        let source = try await snapshot(
            of: """
                <!doctype html>
                <html><head><meta charset="utf-8"><title>Relative</title></head>
                <body><article>
                <p><a href="/about">About</a></p>
                <img src="images/a.png" alt="A">
                <img data-src="images/lazy.png" alt="B">
                </article></body></html>
                """,
            baseURL: URL(string: "https://example.com/posts/one")!)

        #expect(source.contains("https://example.com/about"))
        #expect(source.contains("https://example.com/posts/images/a.png"))
        #expect(source.contains("https://example.com/posts/images/lazy.png"), "a lazy-loaded image is still an image")
        #expect(source.contains("<title>Relative</title>"), "the head travels too — it is where the metadata is")
    }

    /// A same-page fragment must stay a fragment: rewritten to an absolute URL it
    /// would navigate away instead of scrolling, which is how a table of contents
    /// turns into an exit.
    @Test("in-page fragments are left alone")
    func fragmentsAreNotAbsolutized() async throws {
        let source = try await snapshot(
            of: """
                <!doctype html>
                <html><head><meta charset="utf-8"></head>
                <body><article><p><a href="#section">Jump</a></p></article></body></html>
                """,
            baseURL: URL(string: "https://example.com/posts/one")!)
        #expect(source.contains("href=\"#section\""))
    }

    /// Serializing must not disturb the live page: on the browser's reader path the
    /// document being snapshotted is the one the reader is looking at.
    @Test("the live document is not modified by snapshotting it")
    func snapshotDoesNotMutateThePage() async throws {
        let webView = try await loaded(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head>
            <body><article><p><a href="/about" id="link">About</a></p></article></body></html>
            """,
            baseURL: URL(string: "https://example.com/posts/one")!)
        _ = try await webView.evaluateJavaScript("window.__nook.source()")
        let href = try await webView.evaluateJavaScript(
            "document.getElementById('link').getAttribute('href')") as? String
        #expect(href == "/about", "the clone is what gets rewritten, not the page")
    }

    /// The renderer's readiness latch has to reset per render. It is declared in an
    /// IIFE that runs once per document, so a latch left set after the first render
    /// meant a re-render for a parser switch posted no readiness at all — and
    /// in-place translation waited forever for a signal that would never come. Only
    /// visible from the script text, hence a string assertion.
    @Test("the browser reader re-announces readiness on every render")
    func readinessResetsPerRender() {
        let script = ArticleWebView.readerRenderScript(style: ReaderStyle())
        let body = try? #require(script.range(of: "window.__nookRenderReader = function"))
        #expect(body != nil)
        if let body {
            #expect(
                script[body.upperBound...].contains("signaledReady = false"),
                "the latch must be cleared inside the render function, not only at load")
        }
    }

    /// The one difference between the parsers a reader can see. Counting it on the
    /// page is what lets the reader say an embed was removed instead of showing a
    /// blank space.
    @Test("only embeds Readability would have kept are counted")
    func embedCounting() async throws {
        let webView = try await loaded(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head>
            <body><article>
            <iframe src="https://www.youtube.com/embed/abc"></iframe>
            <iframe src="https://codepen.io/x/embed/y"></iframe>
            <iframe src="https://ads.example.com/banner"></iframe>
            <video src="https://example.com/a.mp4"></video>
            </article></body></html>
            """,
            baseURL: URL(string: "https://example.com/posts/one")!)
        let count = try await webView.evaluateJavaScript("window.__nook.embedCount()") as? Int
        #expect(count == 3, "two allowlisted iframes and the video; the ad frame is not content")
    }

    /// The stash is what makes a parser switch free. Once the reader's DOM has been
    /// replaced, the page is no longer the page — so the second engine must be given
    /// the copy, or it reads the first engine's output.
    @Test("a stashed page survives the reader replacing the DOM")
    func stashSurvivesARewrite() async throws {
        let webView = try await loaded(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>Original</title></head>
            <body><article><p>The original body of the article.</p></article></body></html>
            """,
            baseURL: URL(string: "https://example.com/posts/one")!)

        _ = try await webView.evaluateJavaScript("window.__nook.stash()")
        _ = try await webView.evaluateJavaScript(
            "document.body.innerHTML = '<div id=\\\"nook-reader\\\"><p>Rewritten.</p></div>'")

        let source = try await webView.evaluateJavaScript("window.__nook.source()") as? String
        let unwrapped = try #require(source)
        #expect(unwrapped.contains("The original body of the article."))
        #expect(!unwrapped.contains("Rewritten."))

        let json = try await webView.evaluateJavaScript(
            "JSON.stringify(window.__nook.readability())") as? String
        #expect(json?.contains("The original body of the article.") == true)
    }

    // MARK: - Harness

    private func loaded(_ html: String, baseURL: URL) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let readability = ArticleWebView.readabilitySource {
            configuration.userContentController.addUserScript(
                WKUserScript(source: readability, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ReaderParserScripts.shared, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(html, baseURL: baseURL)

        for _ in 0..<100 {
            if let ready = try? await webView.evaluateJavaScript("!!window.__nook") as? Bool, ready {
                return webView
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the shared parser script never became available")
        return webView
    }

    private func snapshot(of html: String, baseURL: URL) async throws -> String {
        let webView = try await loaded(html, baseURL: baseURL)
        let source = try await webView.evaluateJavaScript("window.__nook.source()") as? String
        return try #require(source)
    }
}
