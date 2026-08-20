import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The app-wide heartbeat for relative timestamps ("5 minutes ago").
///
/// Every `RelativeTimeText` reads `now` in its body, so one observable mutation
/// per minute re-renders exactly the on-screen timestamp texts — one shared
/// timer for the whole app instead of a per-row schedule.
///
/// This replaces per-row `TimelineView(.everyMinute)`, which macOS can stall
/// permanently while a window sits idle for hours (system sleep / App Nap):
/// rows then keep showing the time computed at their last render — "1 minute
/// ago" forever — until scrolling recreates their cells. A plain timer has the
/// same blind spot while the process is suspended, so the clock also resnaps
/// the moment the app is used again (activation, wake from sleep) and on
/// calendar/clock jumps ("yesterday" rollovers, time-zone or clock changes),
/// which is precisely when a stale label would otherwise be visible.
@Observable
@MainActor
public final class RelativeTimeTicker {
    public static let shared = RelativeTimeTicker()

    /// The instant relative timestamps are current with. Reading this from a
    /// view body subscribes that view to the heartbeat.
    public private(set) var now = Date()

    @ObservationIgnored private var timer: Timer?

    private init() {
        // Tolerance lets the system coalesce the wakeup; exact minute
        // boundaries don't matter for "n minutes ago" copy.
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { RelativeTimeTicker.shared.resnap() }
        }
        timer.tolerance = 10
        // `.common` keeps ticks flowing during scroll/event tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let resnapNow: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { RelativeTimeTicker.shared.resnap() }
        }
        let center = NotificationCenter.default
        var names: [Notification.Name] = [.NSCalendarDayChanged, .NSSystemClockDidChange]
        #if canImport(AppKit)
        names.append(NSApplication.didBecomeActiveNotification)
        #elseif canImport(UIKit)
        names.append(UIApplication.didBecomeActiveNotification)
        names.append(UIApplication.significantTimeChangeNotification)
        #endif
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main, using: resnapNow)
        }
        #if canImport(AppKit)
        // Wake from system sleep posts on the workspace center, not the default one.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: resnapNow
        )
        #endif
    }

    /// Advances the heartbeat to the present, re-rendering every visible
    /// relative timestamp. Internal so tests can drive it without a timer.
    func resnap() {
        now = Date()
        #if DEBUG && os(macOS)
        GeometryLog.note("ticker.resnap")
        #endif
    }
}

/// A relative timestamp ("5 minutes ago") that keeps itself current.
///
/// The string is computed *from* `RelativeTimeTicker.shared.now`, so this leaf
/// view re-evaluates on every heartbeat — each minute, and immediately on
/// activation/wake — and the label can never freeze. The heartbeat must flow
/// into the output as a value: an earlier version subscribed with a discarded
/// read (`let _ = ticker.now`) above a self-formatting `Text`, and the
/// optimizer eliminated the read in release builds, silently unsubscribing the
/// view — rows then showed the age computed at their last render until the
/// cell happened to be recreated. Font, foreground style, and locale are
/// inherited from the environment, so it reads like the plain `Text` it
/// replaces.
public struct RelativeTimeText: View {
    private let date: Date
    private let presentation: Date.RelativeFormatStyle.Presentation

    @Environment(\.locale) private var locale

    public init(_ date: Date, presentation: Date.RelativeFormatStyle.Presentation = .named) {
        self.date = date
        self.presentation = presentation
    }

    public var body: some View {
        Text(
            Self.string(
                for: date,
                relativeTo: RelativeTimeTicker.shared.now,
                presentation: presentation,
                locale: locale
            )
        )
    }

    /// `RelativeDateTimeFormatter` rather than `Date.RelativeFormatStyle`
    /// because only the formatter accepts an explicit reference date — the
    /// format style always formats against its own "now", which cannot carry
    /// the ticker dependency. Output matches the style's for all presentations
    /// (formatter truncates partial units where the style rounds; both read
    /// naturally). Formatters are expensive to create, so they are cached per
    /// (presentation, locale).
    @MainActor
    static func string(
        for date: Date,
        relativeTo now: Date,
        presentation: Date.RelativeFormatStyle.Presentation,
        locale: Locale
    ) -> String {
        let key = FormatterKey(named: presentation == .named, localeID: locale.identifier)
        let formatter: RelativeDateTimeFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            let fresh = RelativeDateTimeFormatter()
            fresh.dateTimeStyle = key.named ? .named : .numeric
            fresh.locale = locale
            formatters[key] = fresh
            formatter = fresh
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private struct FormatterKey: Hashable {
        let named: Bool
        let localeID: String
    }

    @MainActor
    private static var formatters: [FormatterKey: RelativeDateTimeFormatter] = [:]
}
