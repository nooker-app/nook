import Foundation
import Testing
@testable import NookKit

@MainActor
@Suite("Relative time ticker")
struct RelativeTimeTickerTests {
    @Test("A resnap advances the heartbeat to the present")
    func resnapAdvances() async throws {
        let ticker = RelativeTimeTicker.shared
        let before = ticker.now
        try await Task.sleep(for: .milliseconds(5))

        ticker.resnap()

        #expect(ticker.now > before)
    }

    @Test("The label string is a pure function of the heartbeat")
    func stringFollowsTheHeartbeat() {
        let published = Date(timeIntervalSince1970: 1_000_000)
        let locale = Locale(identifier: "ko_KR")

        // Three minutes after publication…
        let early = RelativeTimeText.string(
            for: published, relativeTo: published.addingTimeInterval(180),
            presentation: .named, locale: locale
        )
        // …and ten minutes after: the heartbeat value must drive the output,
        // or the optimizer regression this guards against (a discarded read
        // losing the subscription) could return unnoticed.
        let late = RelativeTimeText.string(
            for: published, relativeTo: published.addingTimeInterval(600),
            presentation: .named, locale: locale
        )

        #expect(early == "3분 전")
        #expect(late == "10분 전")
    }

    @Test("A clock-change notification resnaps the heartbeat")
    func clockChangeResnaps() async throws {
        let ticker = RelativeTimeTicker.shared
        let before = ticker.now
        try await Task.sleep(for: .milliseconds(5))

        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        // The observer runs on the main queue; yield the main actor until it has.
        for _ in 0..<50 where ticker.now <= before {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(ticker.now > before)
    }
}
