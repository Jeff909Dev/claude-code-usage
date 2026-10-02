import Foundation
import UserNotifications
import UsageCore

protocol NotificationPosting: Sendable {
    func post(_ events: [NotificationEvent])
}

struct NoopNotificationPoster: NotificationPosting {
    func post(_ events: [NotificationEvent]) {}
}

struct UserNotificationPoster: NotificationPosting {
    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ events: [NotificationEvent]) {
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
    }
}

enum NotificationPosterFactory {
    /// UserNotifications crashes outside an app bundle (e.g. `swift run`), so fall back to a no-op there. Read-only
    /// mode never asks for notification permission either.
    static func make(readOnly: Bool) -> any NotificationPosting {
        readOnly || Bundle.main.bundleIdentifier == nil ? NoopNotificationPoster() : UserNotificationPoster()
    }
}
