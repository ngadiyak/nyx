import AppKit
import UserNotifications

/// Posting "your build finished" to Notification Centre.
///
/// Two things make this more than a two-line wrapper. `UNUserNotificationCenter.current()` traps in
/// a process that has no bundle identifier -- which is exactly what `swift run` produces -- so it
/// is reached through a guard rather than called directly. And authorisation is asked for once,
/// lazily, without waiting for the answer: a terminal must not stall on a permission sheet, and a
/// user who says no should simply get no notifications rather than an error every time a command
/// ends.
final class CommandNotifier {
    static let shared = CommandNotifier()

    private var authorizationRequested = false

    private init() {}

    /// nil when this process cannot post notifications at all -- an unbundled build, typically.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    var isAvailable: Bool { center != nil }

    func post(title: String, body: String) {
        guard let center else { return }
        requestAuthorizationIfNeeded(center)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // A denial arrives here as an error. There is nothing useful to do about it and nowhere
        // worth reporting it: the user said no, which is an answer, not a fault.
        center.add(request, withCompletionHandler: nil)
    }

    private func requestAuthorizationIfNeeded(_ center: UNUserNotificationCenter) {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }
}
