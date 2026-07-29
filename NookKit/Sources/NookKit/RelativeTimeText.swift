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
    }
}

/// A relative timestamp ("5 minutes ago") that keeps itself current.
///
/// `Text(date, format: .relative(…))` computes its string once, at body
/// evaluation, and never refreshes on its own. Reading the shared ticker makes
/// this leaf view re-evaluate on every heartbeat — each minute, and immediately
/// on activation/wake — re-formatting against the then-current time. Font,
/// foreground style, and locale are inherited from the environment, so it reads
/// identically to the plain `Text` it wraps.
public struct RelativeTimeText: View {
    private let date: Date
    private let presentation: Date.RelativeFormatStyle.Presentation

    public init(_ date: Date, presentation: Date.RelativeFormatStyle.Presentation = .named) {
        self.date = date
        self.presentation = presentation
    }

    public var body: some View {
        // The read is the subscription; the format style itself always uses
        // the current time, so the value needs no further threading.
        let _ = RelativeTimeTicker.shared.now
        Text(date, format: .relative(presentation: presentation))
    }
}
