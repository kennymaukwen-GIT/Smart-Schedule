import Foundation

/// One calendar of one connected Google account.
struct CalendarRef: Codable, Hashable, Sendable {
    var accountID: String
    var calendarID: String

    /// "accountID/calendarID": the dictionary key in JSON files and the AppEntity id.
    var key: String { "\(accountID)/\(calendarID)" }

    init(accountID: String, calendarID: String) {
        self.accountID = accountID
        self.calendarID = calendarID
    }

    /// Splits at the first "/" (Google calendar ids contain no "/").
    init?(key: String) {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let accountID = String(key[..<slash])
        let calendarID = String(key[key.index(after: slash)...])
        guard !accountID.isEmpty, !calendarID.isEmpty else { return nil }
        self.init(accountID: accountID, calendarID: calendarID)
    }
}

/// Cache identity of one event copy: the same Google event id may live in several calendars.
struct EventRef: Codable, Hashable, Sendable {
    var accountID: String?          // nil: demo, draft or pre-migration events
    var calendarID: String?
    var eventID: String             // Google event id (instance id for expanded recurrences)
}

enum EventAudience: Sendable {
    case display      // hidden calendars and Focus-filtered calendars excluded
    case reminders    // display, minus calendars whose notifications are off
}

struct CalendarInfo: Codable, Hashable, Identifiable, Sendable {
    var accountID: String
    var accountEmail: String        // copied from the account so labels need no lookup
    var calendarID: String          // Google calendar id; the primary calendar's id is the account email
    var name: String                // calendarList summaryOverride ?? summary
    var isPrimary: Bool = false
    var accessRole: String = "owner" // owner | writer | reader | freeBusyReader
    var googleColorHex: String = CalendarInfo.defaultColorHex
    var timeZone: String? = nil
    // Local, per device (kept when the calendar list refreshes)
    var isVisible: Bool = true
    var colorOverrideHex: String? = nil
    var notificationsEnabled: Bool = true

    /// Google Calendar's "Peacock", what the calendar list reports when a calendar has no colour of its own.
    static let defaultColorHex = "#039BE5"

    var id: CalendarRef { CalendarRef(accountID: accountID, calendarID: calendarID) }
    var isWritable: Bool { accessRole == "owner" || accessRole == "writer" }
    var displayColorHex: String { colorOverrideHex ?? googleColorHex }

    var displayName: String {
        isPrimary ? String(localized: "My calendar") : name
    }

    /// "<displayName> | <accountEmail>": the CALENDARS prompt line, the default_calendar value and
    /// `AppPreferences.defaultCalendarLabel`. The name loses "|" and line breaks so the line splits unambiguously.
    var promptLabel: String {
        let name = displayName
            .components(separatedBy: CharacterSet(charactersIn: "|\r\n"))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return "\(name) | \(accountEmail)"
    }
}

struct GoogleAccount: Codable, Hashable, Identifiable, Sendable {
    static let calendarListScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"

    var id: String                  // OpenID `sub`; demo accounts start with "demo-"
    var email: String
    var connectedAt: Date
    var grantedScopes: [String] = []
    var needsReconnect: Bool = false // refresh failed with invalid_grant; cached events kept
    var calendars: [CalendarInfo] = [] // primary, owner, writer, reader, then by name
    var calendarsUpdatedAt: Date? = nil

    var canListCalendars: Bool { grantedScopes.contains(Self.calendarListScope) }
    var primaryCalendar: CalendarInfo? { calendars.first(where: \.isPrimary) }

    /// Uppercased first letter of the email: the header avatar.
    var initial: String {
        guard let first = email.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }

    var isDemo: Bool { id.hasPrefix(DemoData.idPrefix) }
}

/// Set by the Focus filter: while non-nil, only these calendars show and alert.
struct FocusFilterState: Codable, Hashable, Sendable {
    var calendars: [CalendarRef]
    var updatedAt: Date
}

extension CalendarInfo {
    /// The order the drawer, the CALENDARS prompt block and de-duplication ranks use: primary first, then calendars
    /// the user owns, can edit, can only read, then by name.
    static func sorted(_ calendars: [CalendarInfo]) -> [CalendarInfo] {
        calendars.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            let lhsRole = roleOrder(lhs.accessRole), rhsRole = roleOrder(rhs.accessRole)
            if lhsRole != rhsRole { return lhsRole < rhsRole }
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.calendarID < rhs.calendarID
        }
    }

    private static func roleOrder(_ role: String) -> Int {
        switch role {
        case "owner": 0
        case "writer": 1
        case "reader": 2
        case "freeBusyReader": 3
        default: 4
        }
    }
}

// MARK: - Tolerant decoding (accounts.json is read by every process and by older and newer builds)

/// One array element that is skipped when it cannot be decoded, instead of failing the whole array.
struct AccountsFileElement<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

extension CalendarInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(String.self, forKey: .accountID)
        calendarID = try c.decode(String.self, forKey: .calendarID)
        accountEmail = (try? c.decodeIfPresent(String.self, forKey: .accountEmail)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? calendarID
        isPrimary = (try? c.decodeIfPresent(Bool.self, forKey: .isPrimary)) ?? false
        accessRole = (try? c.decodeIfPresent(String.self, forKey: .accessRole)) ?? "reader"
        googleColorHex = (try? c.decodeIfPresent(String.self, forKey: .googleColorHex)) ?? Self.defaultColorHex
        timeZone = try? c.decodeIfPresent(String.self, forKey: .timeZone)
        isVisible = (try? c.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? true
        colorOverrideHex = try? c.decodeIfPresent(String.self, forKey: .colorOverrideHex)
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? true
    }
}

extension GoogleAccount {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        connectedAt = (try? c.decodeIfPresent(Date.self, forKey: .connectedAt)) ?? Date(timeIntervalSince1970: 0)
        grantedScopes = (try? c.decodeIfPresent([String].self, forKey: .grantedScopes)) ?? []
        needsReconnect = (try? c.decodeIfPresent(Bool.self, forKey: .needsReconnect)) ?? false
        calendars = ((try? c.decodeIfPresent([AccountsFileElement<CalendarInfo>].self, forKey: .calendars)) ?? [])
            .compactMap(\.value)
        calendarsUpdatedAt = try? c.decodeIfPresent(Date.self, forKey: .calendarsUpdatedAt)
    }
}

extension FocusFilterState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calendars = ((try? c.decodeIfPresent([AccountsFileElement<CalendarRef>].self, forKey: .calendars)) ?? [])
            .compactMap(\.value)
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date(timeIntervalSince1970: 0)
    }
}
