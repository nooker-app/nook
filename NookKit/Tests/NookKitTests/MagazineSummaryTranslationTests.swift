#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import NookKit

@Suite("Magazine preview translation")
@MainActor
struct MagazineSummaryTranslationTests {
    @Test("A preview stays readable until completion and restores its source when disabled")
    func completedReplacement() {
        let translator = ListTitleTranslator()
        let original = "The article explains how to follow technology news."
        let box = translator.box(for: "preview", title: original)
        func displayed(_ enabled: Bool = true) -> String {
            MagazineTranslatedSummary.displayText(original: original, translation: box.completedText, enabled: enabled)
        }
        #expect(displayed() == original)
        translator._deliverForTesting(.translating("기술", provider: .gemini), for: "preview")
        #expect(displayed() == original)
        translator._deliverForTesting(.translated("기술 소식을 읽는 방법을 설명합니다.", provider: .gemini), for: "preview")
        #expect(displayed() == "기술 소식을 읽는 방법을 설명합니다.")
        #expect(displayed(false) == original)
        translator._deliverForTesting(nil, for: "preview")
        #expect(displayed() == original)
        translator._deliverForTesting(.translated(" \n", provider: .gemini), for: "preview")
        #expect(displayed() == original)
    }

    @Test("Provider partials do not invalidate a completion-only card")
    func partialsDoNotRebuildPreview() {
        let translator = ListTitleTranslator()
        let box = translator.box(for: "preview")
        let changed = Mutex(false)
        withObservationTracking { _ = box.completedText } onChange: {
            changed.withLock { $0 = true }
        }
        for partial in ["", "번", "번역", "번역 문장"] {
            translator._deliverForTesting(.translating(partial, provider: .gemini), for: "preview")
        }
        #expect(!changed.withLock { $0 })
        translator._deliverForTesting(.translated("번역 문장", provider: .gemini), for: "preview")
        #expect(changed.withLock { $0 })
    }

    @Test("Cached previews are independent of headlines and refreshed source content")
    func sourceIdentityAndCache() {
        let translator = ListTitleTranslator()
        let first = "First preview."
        let second = "Updated preview."
        translator._enableForTesting(targetLanguageCode: "ko", cached: [first: "첫 미리보기", second: "갱신된 미리보기"])
        let headline = translator.box(for: "magazine|article|A title", title: "A title")
        let original = translator.box(for: MagazineTranslatedSummary.translationID(articleID: "article", summary: first), title: first)
        let updated = translator.box(for: MagazineTranslatedSummary.translationID(articleID: "article", summary: second), title: second)
        #expect(headline !== original)
        #expect(original !== updated)
        #expect(headline.completedText == nil)
        #expect(original.completedText == "첫 미리보기")
        #expect(updated.completedText == "갱신된 미리보기")
    }

    @Test("Disabling or retargeting translation clears completed preview state")
    func settingsClearCompletedText() {
        let translator = ListTitleTranslator()
        translator._enableForTesting(targetLanguageCode: "ko", cached: ["Preview": "미리보기"])
        let box = translator.box(for: "preview", title: "Preview")
        #expect(box.completedText == "미리보기")
        translator.configure(enabled: false, targetLanguageName: "Japanese", targetLanguageCode: "ja")
        #expect(box.state == nil)
        #expect(box.completedText == nil)
    }

    @Test("Short and long translations keep the same three-line preview slot", arguments: [220.0, 360.0, 900.0])
    func fixedPreviewHeight(width: CGFloat) {
        for size in [13.0, 15.0] {
            func height(_ text: String) -> CGFloat {
                NSHostingView(rootView: MagazineHeadlineTransition(title: text, size: size, lines: 3,
                    animated: false, style: .summary).frame(width: width)).fittingSize.height
            }
            let short = height("A short preview.")
            let long = height(String(repeating: "화면에 보이는 글의 미리보기가 자연스럽게 번역됩니다. ", count: 8))
            #expect(short > size * 3)
            #expect(abs(short - long) < 0.5, "Preview/footer must not jump: \(short) → \(long)")
        }
    }
}
#endif
