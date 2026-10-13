import AppIntents

/// Focus filter: Settings › Focus › (a Focus) › Add Filter › Smart Schedule. While that Focus is on, only the chosen
/// calendars show and send reminders. iOS runs `perform()` when the Focus turns on, and again with the parameter's
/// default (nil) when it turns off, which clears the filter. Apps cannot open Focus settings themselves (no public
/// URL), so Settings › Notifications explains the path.
struct CalendarFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Calendars"
    static let description = IntentDescription("Choose which calendars show and send reminders while this Focus is on.")

    @Parameter(title: "Calendars")
    var calendars: [CalendarEntity]?

    var displayRepresentation: DisplayRepresentation {
        let names = (calendars ?? []).map(\.name)
        guard !names.isEmpty else { return DisplayRepresentation(title: "Calendars", subtitle: "All calendars") }
        return DisplayRepresentation(title: "Calendars", subtitle: CalendarEntity.verbatim(names.joined(separator: ", ")))
    }

    init() {}

    func perform() async throws -> some IntentResult {
        let refs = (calendars ?? []).compactMap { CalendarRef(key: $0.id) }
        await AccountStore.shared.setFocusFilter(refs.isEmpty ? nil : refs)
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
        return .result()
    }
}

/// One calendar of a connected account (or a sample calendar in demo mode), identified by `CalendarRef.key`.
struct CalendarEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Calendar"
    static let defaultQuery = CalendarEntityQuery()

    let id: String
    let name: String
    let accountEmail: String

    init(id: String, name: String, accountEmail: String) {
        self.id = id
        self.name = name
        self.accountEmail = accountEmail
    }

    init(_ calendar: CalendarInfo) {
        self.init(id: calendar.id.key, name: calendar.displayName, accountEmail: calendar.accountEmail)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: Self.verbatim(name), subtitle: Self.verbatim(accountEmail))
    }

    /// User data shown as is. Unlike "\(name)", it adds no "%@" key to the String Catalog.
    static func verbatim(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource(stringLiteral: text)
    }
}

struct CalendarEntityQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [CalendarEntity] {
        let calendars = await AccountStore.shared.calendars()
        return identifiers.compactMap { id in
            calendars.first { $0.id.key == id }.map { CalendarEntity($0) }
        }
    }

    func suggestedEntities() async throws -> [CalendarEntity] {
        await AccountStore.shared.calendars().map { CalendarEntity($0) }
    }
}
