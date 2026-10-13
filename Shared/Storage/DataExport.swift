import Foundation

/// "Export my data": everything Smart Schedule keeps about the user on this device, as one JSON file. Sign-in tokens
/// are never part of it (they live only in the Keychain and nothing here reads them). Built by
/// `App/Privacy/DataExporter.swift`; the model lives here so it can be unit-tested.
struct DataExport: Encodable, Sendable {
    static let format = "smart-schedule-export"
    static let currentVersion = 1

    struct AppInfo: Encodable, Sendable {
        var version: String
        var build: String
    }

    struct Account: Encodable, Sendable {
        var email: String
        var calendars: [CalendarEntry]
    }

    struct CalendarEntry: Encodable, Sendable {
        var id: String
        var name: String
        var visible: Bool
        var colorOverride: String?
        var notifications: Bool

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(visible, forKey: .visible)
            try c.encode(colorOverride, forKey: .colorOverride) // explicit null
            try c.encode(notifications, forKey: .notifications)
        }

        private enum CodingKeys: String, CodingKey { case id, name, visible, colorOverride, notifications }
    }

    var exportedAt: Date
    var app: AppInfo
    var preferences: AppPreferences
    var assistantMemory: [LedgerEntry]
    var learnedSuggestions: [LearnedSuggestion]
    var accounts: [Account]
    var aiConsent: AIConsent
    var cachedEvents: [ScheduleEvent]
    var pendingPlan: PlanDraft?
    var pendingEvents: PendingEventBatch?
    var chatHistory: [ChatRecord]

    init(exportedAt: Date,
         app: AppInfo,
         preferences: AppPreferences,
         assistantMemory: [LedgerEntry],
         learnedSuggestions: [LearnedSuggestion],
         accounts: [GoogleAccount],
         aiConsent: AIConsent,
         cachedEvents: [ScheduleEvent],
         pendingPlan: PlanDraft?,
         pendingEvents: PendingEventBatch?,
         chatHistory: [ChatRecord]) {
        self.exportedAt = exportedAt
        self.app = app
        self.preferences = preferences
        self.assistantMemory = assistantMemory
        self.learnedSuggestions = learnedSuggestions
        // Email and calendar settings only: scopes, ids and sign-in state stay out.
        self.accounts = accounts.map { account in
            Account(email: account.email, calendars: account.calendars.map { calendar in
                CalendarEntry(id: calendar.calendarID, name: calendar.name, visible: calendar.isVisible,
                              colorOverride: calendar.colorOverrideHex, notifications: calendar.notificationsEnabled)
            })
        }
        self.aiConsent = aiConsent
        self.cachedEvents = cachedEvents
        self.pendingPlan = pendingPlan
        self.pendingEvents = pendingEvents
        self.chatHistory = chatHistory
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.format, forKey: .format)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(exportedAt, forKey: .exportedAt)
        try c.encode(app, forKey: .app)
        try c.encode(preferences, forKey: .preferences)
        try c.encode(assistantMemory, forKey: .assistantMemory)
        try c.encode(learnedSuggestions, forKey: .learnedSuggestions)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(aiConsent, forKey: .aiConsent)
        try c.encode(cachedEvents, forKey: .cachedEvents)
        try c.encode(pendingPlan, forKey: .pendingPlan)       // explicit null
        try c.encode(pendingEvents, forKey: .pendingEvents)   // explicit null
        try c.encode(chatHistory, forKey: .chatHistory)
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, app, preferences, assistantMemory, learnedSuggestions, accounts, aiConsent
        case cachedEvents, pendingPlan, pendingEvents, chatHistory
    }

    /// Pretty-printed JSON with ISO 8601 dates.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// "SmartSchedule-Export-2026-10-14.json", dated in `timeZone`.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "SmartSchedule-Export-%04d-%02d-%02d.json", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}
