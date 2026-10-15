import Foundation
import UserNotifications

/// "Erase all data on this device". Smart Schedule has no accounts of its own, so this (with "Remove account" for one
/// Google account) is how a user removes their data. Events in Google Calendar stay; subscriptions (none in version
/// 1.0, AppConstants.subscriptionsEnabled) belong to the Apple Account and survive. The caller resets its view models
/// to the signed-out welcome state.
enum DataEraser {
    @MainActor
    static func eraseAll() async {
        // No Live Activity is planned again from the cache while it is erased (the consent change below, a sync or
        // a return to the front would otherwise start a pass); resumed once the data is gone.
        ActivityScheduler.shared.suspend()
        await LiveActivityManager.shared.dismiss()
        // Consent goes first: a Live Activity pass that starts from here on can only clear the server, not upload.
        AIConsentStore.reset()
        // iOS 18: the server forgets the events it was to start Live Activities for (titles), after any upload
        // already under way; then this install's App Attest key and the notification extension's session go.
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
        // Which events' note suggestions were hidden with "×" (event ids, App Group).
        NoteSuggestionDismissals.reset()
        AppConstants.setDemoMode(false)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        await ScheduleAssistant.shared.resetConversation()
        ActivityScheduler.shared.resume()
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
