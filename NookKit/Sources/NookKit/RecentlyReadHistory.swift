import CryptoKit
import Foundation
import Observation

/// Actual opens, independent of read flags and recommendation opt-in. Stored on
/// this device per library; opening an old story moves it to the top immediately.
@MainActor @Observable
public final class RecentlyReadHistory {
    public private(set) var opened: [Article.ID: Date] = [:]
    @ObservationIgnored private var scope = ""
    @ObservationIgnored private let defaults: UserDefaults
    private var key: String { "recentlyRead.v1." + scope }
    static let capacity = 500

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func selectLibrary(_ identifier: String) {
        let next = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        guard next != scope else { return }
        scope = next
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([Article.ID: Date].self, from: data) {
            opened = saved
        } else {
            // Older versions recorded foreground reading time. Preserve those
            // known visits; never manufacture visits from bulk read flags.
            let legacy = defaults.data(forKey: "magazineReadingHistory.v1." + scope)
                .flatMap { try? JSONDecoder().decode(MagazineReadingHistory.self, from: $0) }
            opened = legacy?.entries.mapValues(\.lastRead) ?? [:]
            save()
        }
    }

    public func record(_ id: Article.ID, now: Date = .now) {
        guard !scope.isEmpty else { return }
        // A reader and its in-app browser can appear together for the same open.
        if let previous = opened[id], now.timeIntervalSince(previous) < 1,
           !opened.values.contains(where: { $0 > previous }) { return }
        var next = opened
        next[id] = now
        if next.count > Self.capacity {
            next = Dictionary(uniqueKeysWithValues: next.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(Self.capacity).map { ($0.key, $0.value) })
        }
        opened = next
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(opened) { defaults.set(data, forKey: key) }
    }
}
