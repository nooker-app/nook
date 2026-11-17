#if os(macOS)
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
}
#endif
