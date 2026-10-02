import Foundation
import UserNotifications

/// Keeps the app's review-date reminders in step with the saved evaluations.
@MainActor
protocol ReviewReminderScheduling: AnyObject {
    /// Asks for permission to show notifications. Returns whether they are allowed.
    func requestPermission() async -> Bool
    /// Replaces every review reminder this app scheduled with exactly `reminders`.
    func replaceAll(with reminders: [PlannedReminder])
}

/// Local notifications only: nothing is sent to a server, and only this app's
/// review reminders (by identifier prefix) are ever removed.
@MainActor
final class NotificationReviewReminders: ReviewReminderScheduling {
    private let center = UNUserNotificationCenter.current()

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func replaceAll(with reminders: [PlannedReminder]) {
        let center = center
        center.getPendingNotificationRequests { pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(PlannedReminder.identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            for reminder in reminders {
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.body = reminder.body
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.fireDate, repeats: false)
                center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
            }
        }
    }
}
