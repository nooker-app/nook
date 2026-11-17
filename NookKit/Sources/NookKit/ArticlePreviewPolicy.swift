import Foundation
import Observation

/// Traffic preferences are local to this device, like automatic feed refresh.
/// They never change the shared library or a peer's network budget.
public struct ArticlePreviewPolicy: Codable, Equatable, Sendable {
    public var enabled = true
    public var interval: Double = 1
    public var requestsPerMinute = 30

    public init() {}

    var normalized: Self {
        var copy = self
        copy.interval = interval.isFinite ? min(120, max(1, interval)) : 1
        copy.requestsPerMinute = min(30, max(1, requestsPerMinute))
        return copy
    }
}

@MainActor @Observable
public final class ArticlePreviewPreferences {
    public static let shared = ArticlePreviewPreferences()
    public static let storageKey = "magazinePreviewPolicies.v1"
    public private(set) var revision = 0
    private var document: Document
    private let defaults: UserDefaults

    private struct Document: Codable {
        var standard = ArticlePreviewPolicy()
        var feeds: [Feed.ID: ArticlePreviewPolicy] = [:]
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        document = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Document.self, from: $0) } ?? Document()
    }

    public var standard: ArticlePreviewPolicy { document.standard.normalized }
    public func override(for id: Feed.ID) -> ArticlePreviewPolicy? { document.feeds[id]?.normalized }
    public func policy(for id: Feed.ID) -> ArticlePreviewPolicy {
        var result = (document.feeds[id] ?? standard).normalized
        result.enabled = standard.enabled && result.enabled
        return result
    }

    public func setStandard(_ value: ArticlePreviewPolicy) {
        document.standard = value.normalized
        persist()
    }

    public func setOverride(_ value: ArticlePreviewPolicy?, for id: Feed.ID) {
        document.feeds[id] = value?.normalized
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(document) { defaults.set(data, forKey: Self.storageKey) }
        revision &+= 1
    }
}

/// The budget is independent of the clock and transport so limits, retries and
/// restart behavior can be tested without sleeping or contacting publishers.
struct ArticlePreviewBudget: Codable, Sendable {
    struct Bucket: Codable, Sendable {
        var starts: [Date] = []
        var blockedUntil: Date = .distantPast
        var failures = 0
        var lastInterval: Double = 0
    }
    var buckets: [String: Bucket] = [:]

    func delay(feed: String, host: String, policy: ArticlePreviewPolicy, now: Date) -> TimeInterval {
        max(delay(key: "feed:" + feed, interval: policy.interval, limit: policy.requestsPerMinute, now: now),
            delay(key: "host:" + host, interval: max(1, policy.interval), limit: min(30, policy.requestsPerMinute), now: now))
    }

    private func delay(key: String, interval: Double, limit: Int, now: Date) -> TimeInterval {
        guard let bucket = buckets[key] else { return 0 }
        var until = bucket.blockedUntil
        if let last = bucket.starts.last {
            until = max(until, last.addingTimeInterval(max(interval, bucket.lastInterval)))
        }
        let recent = bucket.starts.filter { now.timeIntervalSince($0) < 60 }
        if recent.count >= limit {
            until = max(until, recent[recent.count - limit].addingTimeInterval(60))
        }
        return max(0, until.timeIntervalSince(now))
    }

    mutating func started(feed: String, host: String, policy: ArticlePreviewPolicy, now: Date) {
        for key in ["feed:" + feed, "host:" + host] {
            var bucket = buckets[key] ?? Bucket()
            bucket.starts.removeAll { now.timeIntervalSince($0) >= 60 }
            bucket.starts.append(now)
            bucket.lastInterval = key.hasPrefix("host:") ? max(1, policy.interval) : policy.interval
            buckets[key] = bucket
        }
        buckets = buckets.filter { !$0.value.starts.allSatisfy { now.timeIntervalSince($0) > 120 } || $0.value.blockedUntil > now }
    }

    mutating func finished(feed: String, host: String, status: Int, retryAfter: String?, now: Date) {
        for key in ["feed:" + feed, "host:" + host] {
            var bucket = buckets[key] ?? Bucket()
            if status == 429 || status == 503 || status == 403 || status >= 500 || status == 0 {
                bucket.failures = min(8, bucket.failures + 1)
                let base: Double = status == 429 || status == 403 ? 60 : 15
                let backoff = min(3600, base * pow(2, Double(bucket.failures - 1)))
                bucket.blockedUntil = max(bucket.blockedUntil, now.addingTimeInterval(backoff),
                                          Self.retryDate(retryAfter, now: now) ?? now)
            } else if (200..<400).contains(status) {
                bucket.failures = 0
            }
            buckets[key] = bucket
        }
    }

    static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(text), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return max(date, now) }
        }
        return nil
    }
}
