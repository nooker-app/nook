#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Testing
@testable import NookKit

@Suite("Native streaming title presentation", .serialized)
@MainActor
struct MacListTitleTranslationTextTests {
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test("Partial text does not invalidate the block's presence or presentation")
    func separatesTextFromChrome() {
        let translator = ListTitleTranslator()
        let box = translator.box(for: "row", title: "source")
        translator._deliverForTesting(.translating("번", provider: .gemini), for: "row")
        let changes = Changes()
        withObservationTracking {
            _ = box.hasPresentedState
            _ = translator.presentation(for: box, title: "source")
        } onChange: { changes.increment() }
        for text in ["번역", "번역 제목", "번역 제목이 이어집니다"] {
            translator._deliverForTesting(.translating(text, provider: .gemini), for: "row")
        }
        #expect(changes.count == 0)
        translator._deliverForTesting(.translated("번역 제목", provider: .gemini), for: "row")
        #expect(changes.count == 1)
    }

    private final class Heights {
        var values: [CGFloat] = []
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func nativeText(in view: NSView) -> ListTitleNativeTextView? {
        if let native = view as? ListTitleNativeTextView { return native }
        return view.subviews.lazy.compactMap { nativeText(in: $0) }.first
    }

    @Test("Native streaming text grows the SwiftUI row once and remains capped at two lines")
    func streamingHeightFollowsLineCount() async throws {
        let translator = ListTitleTranslator()
        let box = translator.box(for: "row", title: "source")
        translator._deliverForTesting(.translating("짧은 제목", provider: .gemini), for: "row")
        let heights = Heights()
        let host = NSHostingView(rootView:
            ListTitleTranslationBlock(title: "source", box: box, translator: translator)
                .transaction { $0.disablesAnimations = true }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.values.append($0) }
                .frame(width: 220)
        )
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        host.layoutSubtreeIfNeeded()
        try await settle(host)
        let one = try #require(heights.values.last)
        let native = try #require(nativeText(in: host))
        let bindings = native.bindingUpdates

        translator._deliverForTesting(.translating("짧은 제목입니다", provider: .gemini), for: "row")
        try await settle(host)
        #expect(abs((heights.values.last ?? 0) - one) < 0.5)
        #expect(native.bindingUpdates == bindings, "partial text must not re-enter SwiftUI's native-view update")

        let long = String(repeating: "번역하는 동안 스크롤이 부드러워야 합니다. ", count: 5)
        translator._deliverForTesting(.translating(long, provider: .gemini), for: "row")
        try await settle(host)
        let two = try #require(heights.values.last)
        #expect(two > one + 5, "one line=\(one), wrapped=\(two)")
        #expect(two < one + 25, "two-line limit: one=\(one), wrapped=\(two)")
        translator._deliverForTesting(.translated(long + long, provider: .gemini), for: "row")
        try await settle(host)
        #expect(abs((heights.values.last ?? 0) - two) < 0.5)
    }

    @Test("A reused native label ignores updates from its previous title")
    func reusedLabelFollowsCurrentBox() async throws {
        let translator = ListTitleTranslator()
        let first = translator.box(for: "first", title: "first")
        let second = translator.box(for: "second", title: "second")
        let label = ListTitleNativeTextView()
        label.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        label.bind(title: "first", box: first, translator: translator)
        translator._deliverForTesting(.translating("old", provider: .gemini), for: "first")
        translator._deliverForTesting(.translating("current", provider: .gemini), for: "second")
        label.bind(title: "second", box: second, translator: translator)
        translator._deliverForTesting(.translating("stale", provider: .gemini), for: "first")
        try await settle(label)
        let field = try #require(label.subviews.first as? NSTextField)
        #expect(field.stringValue == "current")
        translator._deliverForTesting(.translating("current grows", provider: .gemini), for: "second")
        try await settle(label)
        #expect(field.stringValue == "current grows")
        #expect(label.hitTest(.zero) == nil, "the table must retain selection and swipe input")
    }
}
#endif
