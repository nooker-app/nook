import Testing

@testable import NookKit

/// Comments translate through the same machinery as the article body, so what is
/// worth pinning is the seam: that a comment's markup survives the marker round
/// trip, and that the translator hands back nothing while it is not running.
///
/// The model itself is not exercised here for the same reason no other test
/// exercises it — a result that depends on whether Apple Intelligence is available
/// on the machine is not a test. What is deterministic is the markup contract, and
/// that is where a comment would actually get corrupted.
@Suite("Reader comment translation")
struct ReaderCommentTranslationTests {
    private typealias Engine = InlineMarkupTranslator

    /// A sanitized comment body carries the `rel` legibility forces onto every link.
    /// Losing it would strip a safety attribute from user-authored content in the act
    /// of translating it.
    @Test("a comment's link keeps its href and its forced rel")
    func linkAttributesSurvive() {
        let body = #"<div><p>See <a href="https://example.com/x" rel="nofollow noopener noreferrer">this</a>.</p></div>"#
        let (template, entries) = Engine.markify(body)

        // The words are marked; the tags are not in the text the model sees.
        #expect(!template.contains("href"))
        #expect(template.contains("See "))

        // A translation that moved the words but kept the markers around them.
        let translated = template
            .replacingOccurrences(of: "See ", with: "이 ")
            .replacingOccurrences(of: "this", with: "링크를")
            .replacingOccurrences(of: ".", with: " 보세요.")
        let rebuilt = try? #require(Engine.rebuild(translated, entries: entries))
        #expect(rebuilt?.contains(#"href="https://example.com/x""#) == true)
        #expect(rebuilt?.contains(#"rel="nofollow noopener noreferrer""#) == true)
        #expect(rebuilt?.contains("링크를") == true)
    }

    @Test("a comment's inline code and emphasis survive translation")
    func inlineMarkupSurvives() {
        let body = "<div><p>Use <code>--flag</code> and <em>read the notes</em>.</p></div>"
        let (template, entries) = Engine.markify(body)
        let translated = template.replacingOccurrences(of: "read the notes", with: "메모를 읽으세요")
        let rebuilt = try? #require(Engine.rebuild(translated, entries: entries))
        #expect(rebuilt?.contains("<code>--flag</code>") == true)
        #expect(rebuilt?.contains("<em>메모를 읽으세요</em>") == true)
    }

    /// The guarantee that keeps a broken marker set from producing corrupt markup in
    /// a comment: the fragment falls back to plain translated text instead.
    @Test("a mangled marker set falls back to plain text rather than broken markup")
    func brokenMarkersFallBack() {
        let body = "<div><p>See <a href=\"/x\">this</a>.</p></div>"
        let (_, entries) = Engine.markify(body)
        // A closing marker the model dropped entirely.
        let mangled = "\u{27E6}0\u{27E7}\u{27E6}1\u{27E7}\u{27E6}2\u{27E7}이것"
        #expect(Engine.rebuild(mangled, entries: entries) == nil)
        let fallback = Engine.plainFallback(mangled)
        #expect(!fallback.contains("\u{27E6}"))
        #expect(fallback.contains("이것"))
    }

    // MARK: - What the reader is handed

    @Test("nothing is translated while no run is active")
    func inactiveTranslatorHandsBackNothing() async {
        let translator = await NativeArticleTranslator()
        let comment = ReaderComment(id: 0, text: "Words.", html: "<p>Words.</p>")

        await translator.requestCommentTranslation(comment, into: "Korean")
        #expect(await translator.translatedComment(id: 0) == nil)
        #expect(await translator.translatedComments.isEmpty)
        #expect(await translator.isActive == false)
    }

    /// A comment with nothing renderable in it — a deletion with no surviving text —
    /// must not be queued, or the worker spends a model call on an empty string.
    @Test("a comment with no body is never queued")
    func emptyCommentIsNotQueued() async {
        let translator = await NativeArticleTranslator()
        await translator.requestCommentTranslation(ReaderComment(id: 0), into: "Korean")
        #expect(await translator.translatedComments.isEmpty)
    }

    /// The section keys its requests on this, so it can tell one run from the next and
    /// ask again after the reader switched articles or toggled translation off and on.
    @Test("a fresh translator has not run yet")
    func runStartsAtZero() async {
        #expect(await NativeArticleTranslator().run == 0)
    }
}
