import Foundation
import Testing
@testable import NookKit

@Suite("Notification quiet hours")
struct NotificationScheduleTests {
    /// A fixed zone so the wall-clock assertions don't depend on where the tests run.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int, day: Int = 12) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute)
        )!
    }

    @Test("A disabled window never suppresses anything")
    func disabledAllowsEveryHour() {
        let schedule = NotificationSchedule(isEnabled: false, startMinute: 8 * 60, endMinute: 22 * 60)

        #expect(schedule.allows(date(3, 0), calendar: calendar))
        #expect(schedule.allows(date(14, 0), calendar: calendar))
    }

    @Test("A daytime window includes its start and excludes its end")
    func daytimeWindowBoundaries() {
        let schedule = NotificationSchedule(isEnabled: true, startMinute: 8 * 60, endMinute: 22 * 60)

        #expect(!schedule.allows(date(7, 59), calendar: calendar))
        #expect(schedule.allows(date(8, 0), calendar: calendar))
        #expect(schedule.allows(date(21, 59), calendar: calendar))
        #expect(!schedule.allows(date(22, 0), calendar: calendar))
        #expect(!schedule.allows(date(3, 0), calendar: calendar))
    }

    @Test("A window that runs past midnight stays open across the date change")
    func overnightWindowWraps() {
        // 22:00 → 06:00, the shape a night-shift reader would set.
        let schedule = NotificationSchedule(isEnabled: true, startMinute: 22 * 60, endMinute: 6 * 60)

        #expect(schedule.allows(date(23, 30), calendar: calendar))
        #expect(schedule.allows(date(0, 15), calendar: calendar))
        #expect(schedule.allows(date(5, 59), calendar: calendar))
        #expect(!schedule.allows(date(6, 0), calendar: calendar))
        #expect(!schedule.allows(date(13, 0), calendar: calendar))
    }

    @Test("Equal bounds mean all day, never total silence")
    func equalBoundsAllowEveryHour() {
        let schedule = NotificationSchedule(isEnabled: true, startMinute: 9 * 60, endMinute: 9 * 60)

        #expect(schedule.allows(date(9, 0), calendar: calendar))
        #expect(schedule.allows(date(4, 0), calendar: calendar))
    }

    @Test("Out-of-hours minutes are normalized instead of trapping")
    func outOfRangeMinutesWrap() {
        let schedule = NotificationSchedule(isEnabled: true, startMinute: 25 * 60, endMinute: -60)

        #expect(schedule.startMinute == 60)        // 25:00 → 01:00
        #expect(schedule.endMinute == 23 * 60)     // -01:00 → 23:00
    }

    @Test("Defaults are off, so an upgrade keeps notifying exactly as before")
    func defaultsAreOptIn() {
        let defaults = UserDefaults(suiteName: "NotificationScheduleTests.optIn")!
        defaults.removePersistentDomain(forName: "NotificationScheduleTests.optIn")

        let schedule = NotificationSchedule.current(defaults)

        #expect(!schedule.isEnabled)
        #expect(schedule.startMinute == NotificationSchedule.defaultStartMinute)
        #expect(schedule.endMinute == NotificationSchedule.defaultEndMinute)
        #expect(schedule.allows(date(3, 0), calendar: calendar))
    }

    @Test("A stored window round-trips through UserDefaults")
    func readsStoredWindow() {
        let suite = "NotificationScheduleTests.stored"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: NotificationSchedule.enabledKey)
        defaults.set(9 * 60 + 30, forKey: NotificationSchedule.startKey)
        defaults.set(21 * 60, forKey: NotificationSchedule.endKey)

        let schedule = NotificationSchedule.current(defaults)

        #expect(schedule == NotificationSchedule(isEnabled: true, startMinute: 570, endMinute: 1260))
        #expect(!schedule.allows(date(9, 0), calendar: calendar))
        #expect(schedule.allows(date(9, 30), calendar: calendar))

        defaults.removePersistentDomain(forName: suite)
    }
}
