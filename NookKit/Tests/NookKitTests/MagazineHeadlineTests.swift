#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import NookKit

@Suite("Magazine headline translation")
@MainActor
struct MagazineHeadlineTests {
    @Test func partialTranslationNeverReplacesTheReadableTitle() {
        let original = "A quieter way to read"
        #expect(MagazineTranslatedHeadline.displayTitle(original: original, state: nil, enabled: true) == original)
        #expect(MagazineTranslatedHeadline.displayTitle(original: original,
            state: .translating("조금", provider: .appleIntelligence), enabled: true) == original)
        #expect(MagazineTranslatedHeadline.displayTitle(original: original,
            state: .translated("조금 더 여유롭게 읽는 법", provider: .appleIntelligence), enabled: true) == "조금 더 여유롭게 읽는 법")
        #expect(MagazineTranslatedHeadline.displayTitle(original: original,
            state: .translated(" ", provider: .gemini), enabled: true) == original)
        #expect(MagazineTranslatedHeadline.displayTitle(original: original,
            state: .translated("조금 더 여유롭게 읽는 법", provider: .gemini), enabled: false) == original)
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
