import Testing

@testable import NookKit

/// The composer's caret was landing somewhere unintended while a background sync ran,
/// and the scroll went with it. The cause was the editor treating SwiftUI handing back
/// a value it had just published as text from elsewhere, and replacing the whole
/// document over a live buffer. These pin the rule that tells the two apart — which is
/// about the order of two update paths, and so cannot be reproduced by hand.
@Suite("Editor text arrival")
struct EditorTextArrivalTests {
    @Test("a value the editor published is an echo, not an external change")
    func echoIsNotExternal() {
        // The buffer is a keystroke ahead: SwiftUI is re-running an update with the
        // value from before that keystroke, which is exactly what a sync tick causes.
        let arrival = EditorTextArrival.decide(
            incoming: "hello",
            buffer: "hello w",
            published: ["hello"],
            isComposing: false)
        #expect(arrival == .echo)
        #expect(!arrival.appliesText, "an echo must not replace what the writer has typed")
    }

    /// The reason more than the newest value is remembered: an update can run from a body
    /// SwiftUI evaluated several keystrokes ago, and comparing against only the latest
    /// publish classified those as text from somewhere else.
    @Test("an echo from several keystrokes ago is still an echo")
    func olderEchoIsStillAnEcho() {
        let arrival = EditorTextArrival.decide(
            incoming: "hel",
            buffer: "hello",
            published: ["h", "he", "hel", "hell", "hello"],
            isComposing: false)
        #expect(arrival == .echo)
        #expect(!arrival.appliesText)
    }

    /// The other half. Without this the guard would be a way to make external text never
    /// arrive at all, and loading a draft would show an empty editor.
    @Test("text from somewhere else is applied")
    func externalTextApplies() {
        let arrival = EditorTextArrival.decide(
            incoming: "a draft being opened",
            buffer: "",
            published: [],
            isComposing: false)
        #expect(arrival == .external)
        #expect(arrival.appliesText)
    }

    @Test("an unchanged value is left alone")
    func matchingValueIsUpToDate() {
        let arrival = EditorTextArrival.decide(
            incoming: "same", buffer: "same", published: ["same"], isComposing: false)
        #expect(arrival == .upToDate)
        #expect(!arrival.appliesText)
    }

    /// Marked text belongs to the input method until it commits. Replacing the document
    /// under it throws away the syllable being assembled, which is most of typing in
    /// Korean, Japanese, or Chinese.
    @Test("nothing is applied while an input method is composing")
    func composingIsUntouchable() {
        let arrival = EditorTextArrival.decide(
            incoming: "외부에서 온 텍스트",
            buffer: "쓰는 중",
            published: [],
            isComposing: true)
        #expect(arrival == .composing)
        #expect(!arrival.appliesText)
    }

    /// The ordering that matters, and the one that was wrong first.
    ///
    /// A stale value arriving during a composition is still stale. Classifying it as
    /// "composing" made it a value to apply once the input method committed — which
    /// deleted the syllable just typed. Nothing is lost by dropping it: it is a value the
    /// buffer and the binding already agreed on.
    @Test("a stale echo during a composition is still an echo")
    func echoOutranksComposing() {
        let arrival = EditorTextArrival.decide(
            incoming: "안녕",
            buffer: "안녕하",
            published: ["안녕"],
            isComposing: true)
        #expect(arrival == .echo)
        #expect(!arrival.appliesText)
    }
}
