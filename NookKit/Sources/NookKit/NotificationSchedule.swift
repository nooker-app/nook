import Foundation

/// Nook's own quiet hours: an opt-in window outside which new-article alerts are
/// not delivered, so an overnight refresh can't wake the user.
///
/// Off by default — with `isEnabled == false` every hour is allowed, which is
/// exactly the behavior every existing install already has.
///
/// The window is stored as minutes from local midnight rather than as a `Date`,
/// so it means the same wall-clock time after a time-zone change or a DST shift.
public struct NotificationSchedule: Equatable, Sendable {
    /// `@AppStorage`/`UserDefaults` keys. Shared so every reader of the window
    /// agrees — the settings UI, and the background refresher that enforces it.
    public static let enabledKey = "newArticleNotificationScheduleEnabled"
    public static let startKey = "newArticleNotificationStartMinute"
    public static let endKey = "newArticleNotificationEndMinute"

    public static let minutesPerDay = 24 * 60
    /// 08:00 — a first-enable default that already does the thing users want
    /// (no alerts overnight) without anyone having to touch the pickers.
    public static let defaultStartMinute = 8 * 60
    /// 22:00.
    public static let defaultEndMinute = 22 * 60

    /// Whether the window is enforced at all. When false the other two fields are
    /// still remembered, so toggling back on restores the user's hours.
    public var isEnabled: Bool
    /// Inclusive start, in minutes from local midnight (0..<1440).
    public var startMinute: Int
    /// Exclusive end, in minutes from local midnight (0..<1440). A value below
    /// `startMinute` means the window runs overnight (e.g. 22:00 → 06:00).
    public var endMinute: Int

    public init(isEnabled: Bool, startMinute: Int, endMinute: Int) {
        self.isEnabled = isEnabled
        self.startMinute = Self.wrapped(startMinute)
        self.endMinute = Self.wrapped(endMinute)
    }

    /// The window the user configured, or the defaults on a fresh install.
    public static func current(_ defaults: UserDefaults = .standard) -> NotificationSchedule {
        NotificationSchedule(
            isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? false,
            startMinute: defaults.object(forKey: startKey) as? Int ?? defaultStartMinute,
            endMinute: defaults.object(forKey: endKey) as? Int ?? defaultEndMinute
        )
    }

    /// Whether an alert may be delivered at `date`.
    ///
    /// Equal bounds are treated as "all day", not as a zero-width window: a
    /// mis-dragged pair of pickers must never silence Nook completely with no
    /// visible cause.
    public func allows(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled, startMinute != endMinute else { return true }
        let minute = Self.minuteOfDay(date, calendar: calendar)
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        // Overnight window: open from the start until midnight, and again from
        // midnight until the end.
        return minute >= startMinute || minute < endMinute
    }

    /// The next instant the window opens, strictly after `date` — or nil when it
    /// is already open (or not enforced). Used to park the background wake-up at
    /// the edge of quiet hours instead of letting it fire inside them.
    public func nextOpening(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled, !allows(date, calendar: calendar) else { return nil }
        var components = DateComponents()
        components.hour = startMinute / 60
        components.minute = startMinute % 60
        // `nextDate` walks the real calendar, so a DST transition on the boundary
        // resolves to an instant that actually exists.
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime
        )
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func wrapped(_ minute: Int) -> Int {
        let remainder = minute % minutesPerDay
        return remainder < 0 ? remainder + minutesPerDay : remainder
    }
}
