// `@preconcurrency` so the non-`Sendable` `BGAppRefreshTask` can cross into the
// async handler without a Swift 6 strict-concurrency error.
@preconcurrency import BackgroundTasks
import NookKit
import UserNotifications

/// Periodic background refresh: iOS wakes the app on its own schedule (no sooner
/// than the user's interval), Nook fetches feeds, and if new articles arrived it
/// posts a local notification. Gated on the "New article notifications" setting.
enum BackgroundRefresh {
    static let taskIdentifier = "com.tim.nook.ios.refresh"

    static let enabledKey = NewArticleNotifier.enabledKey
    private static let intervalKey = "refreshIntervalMinutes"
    static let lastScheduleKey = "backgroundRefresh.lastSchedule"
    static let lastScheduleResultKey = "backgroundRefresh.lastScheduleResult"
    static let lastRunKey = "backgroundRefresh.lastRun"
    static let lastFetchResultKey = "backgroundRefresh.lastFetchResult"
    static let lastNotificationResultKey = "backgroundRefresh.lastNotificationResult"

    static var isEnabled: Bool { NewArticleNotifier.isEnabled }

    /// Asks iOS to wake the app for a refresh. The system decides the actual
    /// time; `earliestBeginDate` is only a lower bound.
    ///
    /// The interval is deliberately independent of the user's notification hours:
    /// a feed can drop an old item at any time of day, so Nook keeps collecting
    /// through quiet hours and only holds the alert back.
    static func schedule() {
        guard isEnabled else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        let minutes = UserDefaults.standard.object(forKey: intervalKey) as? Int ?? 30
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(15, minutes) * 60))
        do {
            try BGTaskScheduler.shared.submit(request)
            UserDefaults.standard.set(Date(), forKey: lastScheduleKey)
            UserDefaults.standard.set("scheduled", forKey: lastScheduleResultKey)
        } catch {
            let nsError = error as NSError
            UserDefaults.standard.set(Date(), forKey: lastScheduleKey)
            UserDefaults.standard.set("\(nsError.domain):\(nsError.code) — \(error.localizedDescription)", forKey: lastScheduleResultKey)
        }
    }

    /// Cancels any pending background refresh (e.g. when the feature is turned
    /// off).
    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    /// Drives one `BGAppRefreshTask` from the UIKit launch handler: wires the
    /// system expiration handler to cancel the work, runs the refresh, and marks
    /// the task complete so iOS keeps granting future runs.
    @MainActor
    static func handle(_ task: BGAppRefreshTask) async {
        let work = Task { await run() }
        task.expirationHandler = { work.cancel() }
        _ = await work.value
        task.setTaskCompleted(success: true)
    }

    /// Runs one background refresh and notifies about new articles. Always
    /// reschedules first so refreshes continue.
    @MainActor
    static func run() async {
        schedule()
        guard isEnabled else { return }
        UserDefaults.standard.set(Date(), forKey: lastRunKey)
        await withTaskCancellationHandler {
            // `includingHeldAlerts`: fold in anything an earlier run collected
            // during quiet hours but deliberately didn't announce.
            let result = await ReaderStore.shared.refreshForBackground(includingHeldAlerts: true)
            guard !Task.isCancelled else {
                UserDefaults.standard.set("cancelled", forKey: lastFetchResultKey)
                return
            }
            // Counts this run's arrivals plus anything still held from quiet hours.
            UserDefaults.standard.set("\(result.newArticleCount) to announce", forKey: lastFetchResultKey)
            guard result.newArticleCount > 0 else { return }
            // The fetch above always runs — a feed can drop an old item at any
            // hour, so collection never pauses. Only the alert waits: leaving the
            // receipts undelivered keeps these articles queued, and the first run
            // inside the window announces them together with whatever arrived by
            // then.
            guard NotificationSchedule.current().allows(Date()) else {
                UserDefaults.standard.set(
                    "held \(result.newArticleCount) until notification hours",
                    forKey: lastNotificationResultKey
                )
                return
            }
            await postNotification(for: result)
            ReaderStore.shared.markNotificationsDelivered(result.articleIDs)
            UserDefaults.standard.set("submitted \(result.newArticleCount)", forKey: lastNotificationResultKey)
        } onCancel: {
            UserDefaults.standard.set("cancelled", forKey: lastFetchResultKey)
        }
    }

    @MainActor
    private static func postNotification(for result: ReaderStore.BackgroundRefreshResult) async {
        let body = await NewArticleSummarizer.notificationBody(
            titles: result.sampleTitles,
            count: result.newArticleCount
        )
        await NewArticleNotifier.post(
            title: String(localized: "New in Nook"),
            body: body,
            badge: result.badgeCount
        )
    }
}
