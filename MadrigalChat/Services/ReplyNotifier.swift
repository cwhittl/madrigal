import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// How a reply ended, for the notification text.
enum ReplyOutcome: Equatable {
    case finished(answer: String)
    case failed
    /// Stopped because the app ran out of background time. `reason` says
    /// how, when known.
    case cutOff(reason: String?)
}

/// Where the app is, as far as notifications care.
enum AppPresence {
    /// In front, with the user looking at it.
    case active
    /// Still on screen but covered: Control Center, Notification Center,
    /// the app switcher, or a system alert.
    case inactive
    /// The user has left.
    case background
}

/// Posts a local notification when a reply ends while the app isn't in
/// front, and routes taps back to that chat.
@MainActor
final class ReplyNotifier: NSObject {
    static let shared = ReplyNotifier()

    /// Posted with the conversation's `stableID` (a `UUID`) as `object`
    /// when the user taps a reply notification.
    nonisolated static let openConversation = Notification.Name("dev.whittle.madrigalchat.openConversation")
    nonisolated static let conversationIDKey = "conversationID"
    static let previewLength = 120

    /// Where the app is. Injected so tests can decide.
    var presence: @MainActor () -> AppPresence
    /// Delivers a request. Injected so tests don't touch the real center.
    var deliver: @MainActor (UNNotificationRequest) -> Void
    /// Withdraws delivered notifications by identifier. Injected likewise.
    var withdraw: @MainActor ([String]) -> Void

    /// A tapped chat that no window has opened yet. Covers a tap that
    /// launches the app, which arrives before any view is listening.
    private(set) var pendingConversationID: UUID?

    private var askedForAuthorization = false

    /// Notifications for replies that ended while the app was only
    /// covered. Posted if the user then leaves, dropped if they come back.
    private(set) var held: [UNNotificationRequest] = []

    init(presence: @escaping @MainActor () -> AppPresence = { ReplyNotifier.systemPresence() },
         deliver: (@MainActor (UNNotificationRequest) -> Void)? = nil,
         withdraw: (@MainActor ([String]) -> Void)? = nil) {
        self.presence = presence
        self.deliver = deliver ?? { ReplyNotifier.systemDeliver($0) }
        self.withdraw = withdraw ?? { identifiers in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        super.init()
    }

    /// Adds the request, holding a short background task until it's
    /// handed over: a paused reply's notification is posted just as the
    /// app is suspended, and an app with no other task may be frozen first.
    private static func systemDeliver(_ request: UNNotificationRequest) {
        #if os(iOS)
        var task = UIBackgroundTaskIdentifier.invalid
        let finish: @MainActor () -> Void = {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "Reply notification") {
            MainActor.assumeIsolated { finish() }
        }
        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
        }
        #else
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    /// Asks for permission once per launch, if the user hasn't decided yet.
    /// Call from the foreground; the prompt can't appear from the background.
    func requestAuthorizationIfNeeded() {
        guard !askedForAuthorization, !AppConfig.isHostingTests else { return }
        askedForAuthorization = true
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Posts a notification for a reply that ended while the app wasn't in
    /// front. Returns the request it delivered, if any. If the app is only
    /// covered, the notification is held until the user leaves or returns.
    @discardableResult
    func replyFinished(conversationID: UUID, title: String, outcome: ReplyOutcome) -> UNNotificationRequest? {
        let presence = presence()
        guard presence != .active else { return nil }

        let content = Self.content(conversationID: conversationID, title: title, body: Self.body(for: outcome))
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        if presence == .inactive {
            held.append(request)
            return nil
        }
        deliver(request)
        return request
    }

    /// The user left the app: posts any held notifications.
    func appDidEnterBackground() {
        let requests = held
        held = []
        for request in requests { deliver(request) }
    }

    /// The user is back: held notifications are no longer needed.
    func appDidBecomeActive() {
        held = []
    }

    static let pausedBody = "Reply paused — open Madrigal to continue"

    /// One per chat, so a later pause replaces it and it can be withdrawn.
    static func pausedIdentifier(for conversationID: UUID) -> String {
        "paused." + conversationID.uuidString
    }

    /// Posts a notification for an on-device reply that paused because the
    /// app left without background GPU access. Withdraw it with
    /// `replyResumed` once the app returns or the reply ends.
    @discardableResult
    func replyPaused(conversationID: UUID, title: String) -> UNNotificationRequest? {
        guard presence() == .background else { return nil }

        let request = UNNotificationRequest(
            identifier: Self.pausedIdentifier(for: conversationID),
            content: Self.content(conversationID: conversationID, title: title, body: Self.pausedBody),
            trigger: nil
        )
        deliver(request)
        return request
    }

    /// Withdraws the paused notification, if any. Safe to call any time.
    func replyResumed(conversationID: UUID) {
        withdraw([Self.pausedIdentifier(for: conversationID)])
    }

    /// A notification about one chat: titled with it, grouped with its
    /// other notifications, and opening it when tapped.
    private static func content(conversationID: UUID, title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Madrigal" : title
        content.body = body
        content.threadIdentifier = conversationID.uuidString
        content.userInfo = [conversationIDKey: conversationID.uuidString]
        return content
    }

    static func body(for outcome: ReplyOutcome) -> String {
        switch outcome {
        case .finished(let answer):
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Reply finished" }
            guard trimmed.count > previewLength else { return trimmed }
            return String(trimmed.prefix(previewLength)).trimmingCharacters(in: .whitespaces) + "…"
        case .failed:
            return "Reply failed"
        case .cutOff(let reason):
            let summary = "Reply was cut off — tap to continue"
            guard let reason, !reason.isEmpty else { return summary }
            return summary + "\n" + reason
        }
    }

    static func systemPresence() -> AppPresence {
        #if os(iOS)
        switch UIApplication.shared.applicationState {
        case .active: .active
        case .inactive: .inactive
        default: .background
        }
        #elseif os(macOS)
        NSApp.isActive ? .active : .background
        #else
        .active
        #endif
    }

    /// Whether notifications are turned off for the app, for Settings.
    nonisolated static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// The system settings page for the app's notifications.
    static var systemSettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openNotificationSettingsURLString)
        #elseif os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #else
        nil
        #endif
    }

    /// Returns and clears the chat a tap asked to open.
    func takePendingConversationID() -> UUID? {
        defer { pendingConversationID = nil }
        return pendingConversationID
    }
}

extension ReplyNotifier: UNUserNotificationCenterDelegate {
    /// Becomes the notification center's delegate. Call at launch so taps
    /// that launched the app are delivered.
    func install() {
        UNUserNotificationCenter.current().delegate = self
        #if os(iOS)
        let center = NotificationCenter.default
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidEnterBackground() }
        }
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        }
        #endif
    }

    /// Uses the completion-handler form on purpose. UIKit updates the app's
    /// snapshot when the handler is called and asserts that happens on the
    /// main thread; the `async` form calls it from wherever the function
    /// finished, which crashed the app when a notification was tapped.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info[Self.conversationIDKey] as? String).flatMap(UUID.init(uuidString:))
        nonisolated(unsafe) let completionHandler = completionHandler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id {
                    ReplyNotifier.shared.pendingConversationID = id
                    NotificationCenter.default.post(name: Self.openConversation, object: id)
                }
            }
            completionHandler()
        }
    }

    /// Shows nothing while the app is in front; the reply is on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
