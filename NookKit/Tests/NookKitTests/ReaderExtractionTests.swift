import Testing
import WebKit

@testable import NookKit

/// Runs the real extraction script against real page markup.
///
/// Written because nothing did. A short post published by Nook itself came out as
/// "can't show the original", and the reader offered to delete it: the script
/// required more than eighty characters of text before it would believe a page had
/// an article in it, and a twenty-word note does not have eighty. Nobody noticed
/// because the script had no test at all.
@MainActor
@Suite("Reader extraction")
struct ReaderExtractionTests {
    /// A page shaped like the ones Nook publishes: semantic, an explicit
    /// `<article>`, and no more markup than it needs.
    static func publishedPage(body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>A post — Somebody</title></head>
        <body>
        <header class="site"><a href="/@somebody">Somebody</a></header>
        <article>
        <h1>A post</h1>
        <p><time datetime="2026-07-30T00:00:00Z">30 July 2026</time></p>
        \(body)
        </article>
        <footer class="site"><a href="/@somebody">← Somebody</a></footer>
        </body>
        </html>
        """
    }

    /// The case the user hit: a real post, only short.
    @Test("a short post in a declared article is extracted")
    func shortDeclaredArticle() async throws {
        let page = Self.publishedPage(body: "<p>반가워요</p><p>Two short lines.</p>")
        let outcome = try await extract(page)

        #expect(outcome.ok, "a short post should extract, not report failure")
        #expect(outcome.content.contains("Two short lines"))
    }

    /// Down to a handful of characters. A note is still a note.
    @Test("a very short post is still extracted")
    func verySmallDeclaredArticle() async throws {
        let outcome = try await extract(Self.publishedPage(body: "<p>Hi.</p>"))
        #expect(outcome.ok)
        #expect(outcome.content.contains("Hi."))
    }

    /// A long post was never the problem, and must keep working.
    @Test("a long post is extracted")
    func longArticle() async throws {
        let body = "<p>" + String(repeating: "Words enough to clear any floor. ", count: 20) + "</p>"
        let outcome = try await extract(Self.publishedPage(body: body))
        #expect(outcome.ok)
        #expect(outcome.content.contains("Words enough"))
    }

    /// The floor still applies where the markup declares nothing. Without it the
    /// extractor would show a page's navigation as though it were an article.
    @Test("a page with no declared article and almost no text is not extracted")
    func undeclaredAndEmpty() async throws {
        let page = """
            <!doctype html>
            <html><head><title>Index</title></head>
            <body><main><nav><a href="/a">A</a> <a href="/b">B</a></nav></main></body>
            </html>
            """
        let outcome = try await extract(page)
        #expect(outcome.ok == false, "a navigation-only page must not read as an article")
    }

    /// The fallback path, with no Readability at all: still has to work, because
    /// the script is written to survive the resource failing to load.
    @Test("a short post extracts without Readability too")
    func shortWithoutReadability() async throws {
        let outcome = try await extract(
            Self.publishedPage(body: "<p>Short.</p>"), withReadability: false)
        #expect(outcome.ok)
        #expect(outcome.content.contains("Short."))
    }

    /// The real thing: a page captured from a live publication, extracted with
    /// Readability present, as the app does it.
    ///
    /// Checks what made a post look clumsy in reader mode. The reader draws the
    /// title and the date in its own chrome, so finding them again inside the
    /// extracted body showed each of them twice, with the date left over as a
    /// stray line.
    @Test("a real published page yields the body and nothing else")
    func realPublishedPage() async throws {
        let outcome = try await extract(ReaderExtractionFixture.publishedArticle)

        #expect(outcome.ok)
        #expect(outcome.content.contains("반가워요"), "the article text should be there")
        #expect(!outcome.content.contains("<h1"), "the title belongs to the reader's chrome")
        #expect(!outcome.content.contains("byline"), "the byline belongs to the reader's chrome")
        #expect(!outcome.content.contains("30 July 2026"), "the date belongs to the reader's chrome")
        #expect(!outcome.content.contains("class=\"site\""), "the page's own header and footer are not the article")
    }

    /// itemprop is the other way a page can declare its body, and it is honoured
    /// the same way.
    @Test("an itemprop body is treated as declared")
    func itempropBody() async throws {
        let page = """
            <!doctype html>
            <html><head><title>A post</title></head>
            <body><div itemprop="articleBody"><p>Short.</p></div></body>
            </html>
            """
        let outcome = try await extract(page)
        #expect(outcome.ok)
        #expect(outcome.content.contains("Short."))
    }

    // MARK: - Harness

    struct Extraction {
        let ok: Bool
        let content: String
    }

    /// Loads markup into a real WKWebView with the real extraction script and
    /// returns what it posted back.
    ///
    /// Readability is injected by default, because the app injects it: a harness
    /// without it exercises only the fallback, which is how a failure on the
    /// Readability path went unnoticed.
    private func extract(_ html: String, withReadability: Bool = true) async throws -> Extraction {
        let handler = ExtractionHandler()
        let configuration = WKWebViewConfiguration()
        if withReadability, let readability = ArticleWebView.readabilitySource {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: readability, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ExtractionSession.extractionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))
        configuration.userContentController.add(handler, name: "nookExtract")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/@somebody/a-post"))

        // The script retries a few times before giving up, so a failure takes
        // about a second to arrive.
        for _ in 0..<60 {
            if let result = handler.result { return result }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the extraction script never reported a result")
        return Extraction(ok: false, content: "")
    }

    private final class ExtractionHandler: NSObject, WKScriptMessageHandler {
        private(set) var result: Extraction?

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let payload = message.body as? [String: Any] else { return }
            result = Extraction(
                ok: payload["ok"] as? Bool ?? false,
                content: payload["content"] as? String ?? ""
            )
        }
    }
}
