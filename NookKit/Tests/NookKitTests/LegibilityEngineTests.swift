import Foundation
import Testing
import WebKit

@testable import NookKit

/// Runs the engine that actually ships.
///
/// `Legibility.html` is a generated asset — a Rust extractor compiled to
/// WebAssembly and inlined as base64 — so the only thing worth testing is the file
/// in the bundle, loaded the way the app loads it. A hand-written stand-in would
/// prove that the stand-in works.
///
/// Every case builds its own `LegibilityEngine` rather than using `.shared`: that
/// one tears its page down after ninety idle seconds and recycles it every fifty
/// extractions, and a test that inherits either would be a test whose result
/// depends on which tests ran before it.
@MainActor
@Suite("Legibility engine")
struct LegibilityEngineTests {
    @Test("the generated engine is in the bundle")
    func assetIsPresent() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Legibility", withExtension: "html"),
            "Legibility.html is missing from NookKit's resources — run: make legibility")
        let page = try String(contentsOf: url, encoding: .utf8)
        #expect(page.contains("window.legibility"))
        #expect(page.contains("wasm-unsafe-eval"), "without this directive the CSP refuses to compile the module")
        #expect(page.contains("default-src 'none'"), "the page that parses hostile markup must have no network")
    }

    /// The module compiles and answers, and says which build it is. A stale module
    /// looks exactly like a fix that did not work, so this is worth asserting.
    @Test("the engine loads and reports its build")
    func reportsBuild() async throws {
        let engine = LegibilityEngine()
        _ = await engine.extract(document: "<html><body><p>x</p></body></html>")
        let build = try #require(engine.build, "the engine never became ready")
        #expect(build.contains("wasm "), "the stamp names the commit and the module digest")
    }

    /// A real page, captured from a live publication — the same fixture the
    /// Readability path is held to.
    @Test("a real published page yields the body and nothing else")
    func realPublishedPage() async throws {
        let outcome = await LegibilityEngine().extract(
            document: ReaderExtractionFixture.publishedArticle)
        guard case .article(let article) = outcome else {
            Issue.record("expected an article, got \(outcome)")
            return
        }
        #expect(article.html.contains("반가워요"), "the article text should be there")
        #expect(!article.html.contains("<h1"), "the title belongs to the reader's chrome")
        #expect(article.title?.isEmpty == false, "the page states a title")
    }

    /// The reason legibility is the default: Readability's absolute length floor
    /// rejects a short post outright, and a note is still a note.
    @Test("a very short declared article is extracted")
    func shortArticle() async throws {
        let page = """
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><title>A post — Somebody</title></head>
            <body><article><h1>A post</h1><p>Hi.</p></article></body>
            </html>
            """
        guard case .article(let article) = await LegibilityEngine().extract(document: page) else {
            Issue.record("a short post should extract")
            return
        }
        #expect(article.text.contains("Hi."))
    }

    /// An index page is not a failure to extract; it is the answer. The reader shows
    /// a different notice for it than for a page that is gone.
    @Test("a navigation-only page reports no article")
    func navigationOnlyPage() async throws {
        let page = """
            <!doctype html>
            <html><head><title>Index</title></head>
            <body><main><nav><a href="/a">A</a> <a href="/b">B</a></nav></main></body>
            </html>
            """
        let outcome = await LegibilityEngine().extract(document: page)
        guard case .noArticle = outcome else {
            Issue.record("a navigation-only page must not read as an article, got \(outcome)")
            return
        }
    }

    @Test("an empty document is not sent to the engine at all")
    func emptyDocument() async {
        guard case .noArticle = await LegibilityEngine().extract(document: "") else {
            Issue.record("an empty document has no article in it")
            return
        }
    }

    /// The difference from Readability that a reader can actually see, pinned so it
    /// is a documented trade and not a surprise: legibility's sanitizer drops the
    /// whole `<iframe>` subtree, and Nook's Readability configuration deliberately
    /// keeps allowlisted video and CodePen embeds. This is why both parsers ship and
    /// why the reader can switch between them.
    @Test("embedded media is dropped, and prose structure is not")
    func embedsAreDropped() async throws {
        let page = """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>With a video</title></head>
            <body><article>
            <p>\(String(repeating: "Words enough to clear any floor. ", count: 20))</p>
            <figure><img src="https://example.com/a.png" alt="A picture"><figcaption>A caption</figcaption></figure>
            <iframe src="https://www.youtube.com/embed/abc"></iframe>
            <pre><code>let x = 1</code></pre>
            </article></body></html>
            """
        guard case .article(let article) = await LegibilityEngine().extract(document: page) else {
            Issue.record("a long article should extract")
            return
        }
        #expect(!article.html.contains("<iframe"), "legibility drops embeds; Readability is the parser that keeps them")
        #expect(article.html.contains("<figure"))
        #expect(article.html.contains("A caption"))
        #expect(article.html.contains("<pre"))
        #expect(article.html.contains("https://example.com/a.png"))
    }

    /// legibility never synthesizes metadata, so a page that declares nothing gets
    /// nothing rather than a guess.
    @Test("a title is reported only when the page states one")
    func titlesAreNotInvented() async throws {
        let page = """
            <!doctype html>
            <html><head><meta charset="utf-8"></head>
            <body><article><p>\(String(repeating: "Body text that is plainly an article. ", count: 12))</p></article></body>
            </html>
            """
        guard case .article(let article) = await LegibilityEngine().extract(document: page) else {
            Issue.record("expected an article")
            return
        }
        #expect(article.title == nil || article.title?.isEmpty == true)
    }

    /// Calls queue rather than piling two documents into the module's linear memory
    /// at once, and all of them still get an answer.
    @Test("overlapping extractions all return")
    func overlappingCalls() async throws {
        let engine = LegibilityEngine()
        let page = """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>A post</title></head>
            <body><article><p>\(String(repeating: "Enough words to be an article. ", count: 12))</p></article></body>
            </html>
            """
        // `async let` rather than a task group: four calls in flight at once is what
        // is being tested, and the group's child closures cannot carry this actor's
        // isolation without confusing the isolation checker.
        async let first = engine.extract(document: page)
        async let second = engine.extract(document: page)
        async let third = engine.extract(document: page)
        async let fourth = engine.extract(document: page)
        let outcomes = await [first, second, third, fourth]

        #expect(outcomes.count == 4)
        for outcome in outcomes {
            guard case .article = outcome else {
                Issue.record("a queued extraction came back with \(outcome)")
                continue
            }
        }
    }
}
