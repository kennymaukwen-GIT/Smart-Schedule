import Foundation
import UserNotifications

/// "Erase all data on this device". Smart Schedule has no accounts of its own, so this (with "Remove account" for one
/// Google account) is how a user removes their data. Events in Google Calendar stay; subscriptions belong to the Apple
/// Account and survive (restoring them later works). The caller resets its view models to the signed-out welcome state.
enum DataEraser {
    @MainActor
    static func eraseAll() async {
        await LiveActivityManager.shared.dismiss()
        // iOS 18: the server forgets the events it was to start Live Activities for (titles), then this install's
        // App Attest key and the notification extension's session go.
        await PushToStartRegistrar.eraseAll()
        await AppAttestClient.shared.forgetAll()
        await ReminderScheduler.shared.removeAll()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        // Revokes every token at Google, deletes them (legacy item included) and the accounts file.
        await AccountManager.shared.disconnectAll(revoke: true)
        await SharedStore.shared.eraseAll()
        // Queued changes hold event details and must never go out after a later sign-in.
        await SyncOutbox.shared.eraseAll()
        SyncStatusStore.reset()
        await PreferencesStore.shared.eraseAll()
        await ChatHistoryStore.shared.eraseAll()
        removeExportCopies()
        AIConsentStore.reset()
        // Which events' note suggestions were hidden with "×" (event ids, App Group).
        NoteSuggestionDismissals.reset()
        AppConstants.setDemoMode(false)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        await ScheduleAssistant.shared.resetConversation()
        SharedChangeNotifier.post(.preferences)
        SharedChangeNotifier.post(.accounts)
        SharedChangeNotifier.post(.consent)
    }

    /// "Export my data" files left in the temporary directory hold the same personal data.
    private static func removeExportCopies() {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("SmartSchedule-Export-") {
            try? manager.removeItem(at: file)
        }
    }
}
