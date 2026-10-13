import Foundation

/// "Export my data": writes `SmartSchedule-Export-<yyyy-MM-dd>.json` to the temporary directory for the share
/// sheet. Settings, what the assistant remembers, learned suggestions, accounts and calendar settings (no tokens),
/// the AI consent, every cached event, the pending plan and events, and the chat history.
enum DataExporter {
    static func makeExport(now: Date = Date()) async throws -> URL {
        let preferences = PreferencesStore.shared.current()
        let snapshot = await SharedStore.shared.snapshot()
        let info = Bundle.main.infoDictionary
        let export = DataExport(
            exportedAt: now,
            app: DataExport.AppInfo(version: info?["CFBundleShortVersionString"] as? String ?? "",
                                    build: info?["CFBundleVersion"] as? String ?? ""),
            preferences: preferences,
            assistantMemory: await PreferencesStore.shared.ledger(),
            learnedSuggestions: await PreferencesStore.shared.allSuggestions(),
            // The stored Google accounts, also while demo mode shows the sample ones.
            accounts: await AccountStore.shared.connectedAccounts(),
            aiConsent: AIConsentStore.current,
            cachedEvents: snapshot.events.sorted { $0.start < $1.start },
            pendingPlan: snapshot.pendingPlan,
            pendingEvents: snapshot.pendingEventBatch,
            chatHistory: await ChatHistoryStore.shared.load(retention: preferences.chatRetention, now: now)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(DataExport.fileName(for: now, timeZone: preferences.timeZone))
        try export.encoded().write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
