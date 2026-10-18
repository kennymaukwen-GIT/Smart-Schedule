import os
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

extension Logger {
    /// How far the long-press card got (Console.app › the iPhone › search "SmartScheduleNotificationContent"): no
    /// "viewDidLoad" line means iOS never loaded the extension (project.yml links UserNotificationsUI for that).
    static let card = Logger(subsystem: "com.smartschedules.app.notification-content", category: "card")
}

/// "HOLD MESSAGE TO SPAWN" (Artboard 1).
///
/// Long-press (or pull down) one of Smart Schedule's reminders → iOS expands it and loads this extension
/// in place, over the Lock Screen or any app. The user types in the system text-input action, the reply is
/// delivered to `didReceive(_:completionHandler:)` *inside this extension*, we run Gemini + Calendar right
/// here, and `.doNotDismiss` keeps the expanded card on screen to show "The Respond". The app never opens.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let model = NotificationChatModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        Logger.card.notice("viewDidLoad")
        let host = UIHostingController(rootView: NotificationChatView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        model.onPreferredHeightChange = { [weak self] height in
            guard let self else { return }
            self.preferredContentSize = CGSize(width: self.view.bounds.width, height: height)
        }
        preferredContentSize = CGSize(width: view.bounds.width, height: NotificationChatModel.collapsedHeight)
    }

    func didReceive(_ notification: UNNotification) {
        Logger.card.notice("didReceive \(notification.request.content.categoryIdentifier, privacy: .public)")
        model.load(notification.request.content)
        // Again now that the view has its real width (in viewDidLoad it may still be 0).
        if model.turns.isEmpty {
            preferredContentSize = CGSize(width: view.bounds.width, height: NotificationChatModel.collapsedHeight)
        }
    }

    func didReceive(_ response: UNNotificationResponse,
                    completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void) {
        // Replying or snoozing here counts as engaging with the reminder (learned suggestions).
        Task { await ReminderEngagement.record(response) }

        switch response.actionIdentifier {
        case NotificationIDs.Action.reply:
            if let text = (response as? UNTextInputNotificationResponse)?.userText {
                model.send(text)
            }
            completion(.doNotDismiss) // stay expanded; the answer streams into the card

        case NotificationIDs.Action.snooze10:
            let content = response.notification.request.content
            Task {
                await ReminderScheduler.snooze(content, minutes: 10)
                completion(.dismiss)
            }

        default:
            completion(.dismissAndForwardAction) // body tap → open app (deep link handled there)
        }
    }
}
