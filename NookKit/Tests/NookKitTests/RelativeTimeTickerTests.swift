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
