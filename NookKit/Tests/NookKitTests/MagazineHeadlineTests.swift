#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import NookKit

@Suite("Magazine headline translation")
@MainActor
struct MagazineHeadlineTests {
    @Test func partialTranslationNeverReplacesTheReadableTitle() {
        let original = "A quieter way to read"
        let translator = ListTitleTranslator()
        let box = translator.box(for: "headline")
        func displayed(_ enabled: Bool = true) -> String {
            MagazineTranslatedHeadline.displayTitle(original: original, translation: box.completedText, enabled: enabled)
        }
        let changed = Mutex(false)
        withObservationTracking { _ = displayed() } onChange: { changed.withLock { $0 = true } }
        #expect(displayed() == original)
        translator._deliverForTesting(.translating("조금", provider: .appleIntelligence), for: "headline")
        #expect(displayed() == original)
        #expect(!changed.withLock { $0 }, "Provider partials must not rebuild the original headline")
        translator._deliverForTesting(.translated("조금 더 여유롭게 읽는 법", provider: .appleIntelligence), for: "headline")
        #expect(displayed() == "조금 더 여유롭게 읽는 법")
        #expect(changed.withLock { $0 })
        #expect(displayed(false) == original)
        translator._deliverForTesting(.translated(" ", provider: .gemini), for: "headline")
        #expect(displayed() == original)
    }

    @Test("Ripple endpoints keep the normal headline's wrapping and height", arguments: [220.0, 360.0, 720.0])
    func rippleKeepsHeadlineMetrics(width: CGFloat) {
        let original = "How do you keep up with tech news without getting buried in hype?"
        let translated = "기술 소식을 여유롭게 읽는 법"
        func normal(_ title: String) -> CGFloat {
            NSHostingView(rootView: MagazineHeadline(title, size: 23, lines: 3).frame(width: width)).fittingSize.height
        }
        func replacement(_ progress: Double) -> CGFloat {
            NSHostingView(rootView:
                MagazineHeadlineTransitionLayout(progress: progress) {
                    ForEach([original, translated], id: \.self) { title in
                        MagazineHeadline.text(title, size: 23)
                            .lineSpacing(23 * 0.12).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textRenderer(MagazineTitleRipple(progress: progress, incoming: title == translated))
                    }
                }.frame(width: width)
            ).fittingSize.height
        }
        let start = normal(original)
        let end = normal(translated)
        #expect(abs(replacement(0) - start) < 0.5)
        #expect(abs(replacement(1) - end) < 0.5)
        let middle = replacement(0.5)
        #expect(middle >= min(start, end) - 0.5 && middle <= max(start, end) + 0.5,
                "Transition must not add a line or reserve both text layers: \(start) → \(middle) → \(end)")
    }
}
#endif
