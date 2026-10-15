import Foundation

/// How the assistant's model sees calendars and Google accounts: never by an account's email address
/// (docs/GEMINI_FUNCTION_CALLING.md §10.6).
///
/// Built per request from `AccountStore.calendars()`: the accounts in the order they were added (the drawer's order),
/// each account's calendars in `CalendarInfo.sorted` order. With several accounts a calendar is
/// "<name> | Account N", with one account just "<name>". A calendar named with an email address (another person's
/// calendar shared with the user, or one without a title, which shows its id) is "Shared calendar" ("Shared calendar 2"
/// when one account has several). Two calendars of one account with the same name are "<name>" and "<name> (2)".
/// Labels are unique, so `writableCalendar(matching:)` maps a default_calendar value back to exactly one calendar.
/// Nothing here is stored: removing an account renumbers the accounts after it from the next request on, so removing
/// one also clears the assistant's conversation (`AccountManager.disconnect(accountID:)`), and no function call or
/// result from before the renumbering reaches the model.
///
/// The same aliases stand in for the accounts' addresses wherever the app writes text for the model: "[Account 2 email]"
/// ("[account email]" with one account) in the user's requests, in event titles, notes and places, and in error
/// messages, where any other address becomes "[email address]". `restoringAccountEmails(_:)` turns them back into the
/// addresses in what the model writes, before the app saves it to Google Calendar or shows it.
struct CalendarAliases: Sendable {
    private struct Entry: Sendable {
        var calendar: CalendarInfo
        /// Unique within its account (folded); no "|", "," or line breaks.
        var name: String
        /// 1-based, in the order the accounts first appear.
        var account: Int
    }

    /// An account's address as stored (trimmed) and the account's number.
    private struct Address: Sendable {
        var text: String
        var account: Int
    }

    /// The name of a calendar named with an email address.
    static let sharedCalendarName = PromptRedaction.sharedCalendarName
    /// Other names the model may use for a primary calendar (its name is the localized "My calendar").
    private static let primaryNames = ["My calendar", "Primary calendar", "我的行事曆"]
    /// default_calendar's own value: a calendar with this name is listed as "automatic (2)".
    private static let reservedNames: Set<String> = ["automatic"]

    private let entries: [Entry]
    private let indexByRef: [CalendarRef: Int]
    private let accountCount: Int
    /// `AccountEmail.normalized` address → account number.
    private let accountByEmail: [String: Int]
    /// Every account's address as stored, longest first: replaced wherever it appears, also run together with the text
    /// around it ("see...example@yourmail.com", "example@yourmail.com.Thanks"), which the address pattern takes in.
    private let addresses: [Address]
    /// Account number → its address as stored: `restoringAccountEmails(_:)`.
    private let emailByNumber: [Int: String]

    /// Several accounts: labels, flags and placeholders say which one ("Account 2").
    var namesAccounts: Bool { accountCount > 1 }

    init(calendars: [CalendarInfo]) {
        var numbers: [String: Int] = [:]
        for calendar in calendars {
            guard numbers[calendar.accountID] == nil else { continue }
            numbers[calendar.accountID] = numbers.count + 1
        }
        var byEmail: [String: Int] = [:]
        var byNumber: [Int: String] = [:]
        var stored: [String: Address] = [:]
        for calendar in calendars {
            guard let number = numbers[calendar.accountID] else { continue }
            let email = AccountEmail.normalized(calendar.accountEmail)
            if !email.isEmpty, byEmail[email] == nil { byEmail[email] = number }
            // Only text that is an address: a blank or odd value must never be replaced inside other words.
            let raw = AccountEmail.trimmed(calendar.accountEmail)
            guard PromptRedaction.containsEmail(raw) else { continue }
            if byNumber[number] == nil { byNumber[number] = raw }
            if stored[raw.lowercased()] == nil { stored[raw.lowercased()] = Address(text: raw, account: number) }
        }
        var addressNamed: [String: Int] = [:]
        for calendar in calendars where PromptRedaction.containsEmail(calendar.displayName) {
            addressNamed[calendar.accountID, default: 0] += 1
        }

        var entries: [Entry] = []
        var indexByRef: [CalendarRef: Int] = [:]
        var sharedSoFar: [String: Int] = [:]
        var taken: [String: Set<String>] = [:]
        for calendar in calendars {
            guard indexByRef[calendar.id] == nil else { continue }
            let account = calendar.accountID
            let base: String
            if PromptRedaction.containsEmail(calendar.displayName) {
                let number = (sharedSoFar[account] ?? 0) + 1
                sharedSoFar[account] = number
                base = (addressNamed[account] ?? 0) > 1 ? "\(Self.sharedCalendarName) \(number)" : Self.sharedCalendarName
            } else {
                let cleaned = Self.cleanName(calendar.displayName)
                base = cleaned.isEmpty ? "Calendar" : cleaned
            }
            var used = taken[account] ?? Self.reservedNames
            var name = base
            var suffix = 2
            while used.contains(Self.fold(name)) {
                name = "\(base) (\(suffix))"
                suffix += 1
            }
            used.insert(Self.fold(name))
            taken[account] = used
            indexByRef[calendar.id] = entries.count
            entries.append(Entry(calendar: calendar, name: name, account: numbers[account] ?? 1))
        }
        self.entries = entries
        self.indexByRef = indexByRef
        self.accountCount = numbers.count
        self.accountByEmail = byEmail
        self.addresses = stored.values.sorted { lhs, rhs in
            lhs.text.count != rhs.text.count ? lhs.text.count > rhs.text.count : lhs.text < rhs.text
        }
        self.emailByNumber = byNumber
    }

    // MARK: Names

    /// The CALENDARS line and default_calendar value: "Gym | Account 2", or "Gym" with one account.
    func label(of calendar: CalendarInfo) -> String {
        guard let entry = self.entry(of: calendar) else { return Self.fallbackName(of: calendar) }
        return namesAccounts ? "\(entry.name) | Account \(entry.account)" : entry.name
    }

    /// UPCOMING's `cal=` flag: "<name> (Account N)" when `qualified` (another visible calendar has the same name) and
    /// there are several accounts, else "<name>". Never holds "|" or ",".
    func flagName(of calendar: CalendarInfo, qualified: Bool) -> String {
        guard let entry = self.entry(of: calendar) else { return Self.fallbackName(of: calendar) }
        return qualified && namesAccounts ? "\(entry.name) (Account \(entry.account))" : entry.name
    }

    /// The calendar's name without the account.
    func name(of calendar: CalendarInfo) -> String {
        entry(of: calendar)?.name ?? Self.fallbackName(of: calendar)
    }

    /// PREFERENCES' default_calendar: the calendar's label while it is listed and writable, else "automatic" (new
    /// events then go to the first account's primary calendar, as `AccountStore.defaultWriteTarget()` does).
    func defaultCalendarValue(_ ref: CalendarRef?) -> String {
        guard let ref, let index = indexByRef[ref], entries[index].calendar.isWritable else { return "automatic" }
        return label(of: entries[index].calendar)
    }

    /// The model-facing form of a canonical preference value (the update_preferences function response).
    /// default_calendar is its label as above; other keys are `AppPreferences.promptValue(canonical:for:)`.
    func promptValue(canonical: String, for key: PreferenceKey) -> String {
        guard key == .defaultCalendar else { return AppPreferences.promptValue(canonical: canonical, for: key) }
        var preferences = AppPreferences()
        guard (try? preferences.apply(canonical: canonical, for: key)) != nil else { return "automatic" }
        return defaultCalendarValue(preferences.defaultCalendar)
    }

    // MARK: Back from the model

    /// The writable calendar a default_calendar value names: a CALENDARS line (also with a copied "- " or
    /// " (default)", or written "<name> (Account N)" as UPCOMING flags it); a primary calendar as "My calendar" or
    /// "Primary calendar" of its account; "Account N" alone or "[Account N email]" (that account's primary calendar:
    /// the user typed the account's address, which reached the model as the placeholder; "[account email]" with one
    /// account); with several accounts, a bare name only one writable calendar has. Case, accents and full-width forms
    /// are ignored. nil when nothing or more than one calendar matches.
    func writableCalendar(matching text: String) -> CalendarInfo? {
        let query = Self.query(text)
        guard !query.isEmpty else { return nil }
        let writable = entries.filter { $0.calendar.isWritable }

        let exact = writable.filter { forms(of: $0, names: [$0.name]).contains(query) }
        if !exact.isEmpty { return Self.only(exact)?.calendar }
        let primary = writable.filter { $0.calendar.isPrimary && forms(of: $0, names: Self.primaryNames).contains(query) }
        if let hit = Self.only(primary) { return hit.calendar }
        if let placeholder = Self.placeholderAccount(in: query) {
            // "[account email]" (0) names an account only when there is one.
            let number = placeholder == 0 ? (namesAccounts ? 0 : 1) : placeholder
            return Self.only(writable.filter { $0.account == number && $0.calendar.isPrimary })?.calendar
        }
        if let number = Self.accountNumber(in: query) {
            return Self.only(writable.filter { $0.account == number && $0.calendar.isPrimary })?.calendar
        }
        if namesAccounts {
            return Self.only(writable.filter { Self.fold($0.name) == query })?.calendar
        }
        return nil
    }

    /// The text is written the way the prompt names calendars ("Account 3", "[account email]", or a calendar name
    /// several accounts share) but `writableCalendar(matching:)` found no single calendar for it (an account that is
    /// gone, a name several accounts share). Such a value is refused (the model then asks), never matched some other
    /// way. An old number that now names another account cannot be told apart here: removing an account clears the
    /// conversation instead, so the model never sees one.
    func refersToAlias(_ text: String) -> Bool {
        if Self.looksLikeAlias(text) { return true }
        let query = Self.query(text)
        guard !query.isEmpty else { return false }
        let primaryForms = Self.primaryNames.map { Self.fold($0) }
        return entries.contains { entry in
            Self.fold(entry.name) == query || (entry.calendar.isPrimary && primaryForms.contains(query))
        }
    }

    /// "Gym | Account 3", "account2", "[Account 1 email]": text that names an account the way the prompt does.
    static func looksLikeAlias(_ text: String) -> Bool {
        let folded = fold(text)
        return folded.range(of: #"\baccount ?[0-9]+\b"#, options: .regularExpression) != nil
            || folded.contains("[account") || folded.contains("[email address]")
    }

    // MARK: Addresses

    /// `text` with every address of a connected account replaced by "[Account N email]" ("[account email]" with one
    /// account). Gmail's dot, "+tag" and googlemail.com forms count as the account's address. Other addresses stay.
    /// The address as stored is also replaced where it runs into the text around it ("see...example@yourmail.com"),
    /// even inside a longer address: replacing too much is the safe side.
    func scrubbingAccountEmails(_ text: String) -> String {
        PromptRedaction.replacingEmails(in: replacingStoredAddresses(in: text)) { accountPlaceholder(for: $0) }
    }

    /// As `scrubbingAccountEmails`, and every other address becomes "[email address]": for text the app writes
    /// itself (error messages), which has no reason to hold anyone's address.
    func redactingEmails(_ text: String) -> String {
        PromptRedaction.replacingEmails(in: replacingStoredAddresses(in: text)) {
            accountPlaceholder(for: $0) ?? "[email address]"
        }
    }

    /// The other way, for text the model wrote that the app saves to Google Calendar or shows the user: "[Account N
    /// email]" (and "[account email]" with one account) becomes account N's address. Placeholders of accounts that are
    /// not connected, "[account email]" with several accounts, and "[email address]" stay as they are.
    func restoringAccountEmails(_ text: String) -> String {
        guard text.contains("["), !emailByNumber.isEmpty,
              let regex = try? NSRegularExpression(pattern: Self.placeholderPattern, options: [.caseInsensitive]) else {
            return text
        }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let numberRange = match.range(at: 1)
            let number: Int?
            if numberRange.location == NSNotFound {
                number = namesAccounts ? nil : 1
            } else {
                number = Int(source.substring(with: numberRange))
            }
            guard let number, let address = emailByNumber[number] else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + address
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    /// A copy whose title, place and notes hold no account address, for the prompt. Done before any shortening, so a
    /// cut never leaves part of an address.
    func scrubbed(_ event: ScheduleEvent) -> ScheduleEvent {
        var copy = event
        copy.title = scrubbingAccountEmails(event.title)
        copy.location = event.location.map { scrubbingAccountEmails($0) }
        copy.notes = event.notes.map { scrubbingAccountEmails($0) }
        return copy
    }

    // MARK: Helpers

    private func entry(of calendar: CalendarInfo) -> Entry? {
        indexByRef[calendar.id].map { entries[$0] }
    }

    private func accountPlaceholder(for address: String) -> String? {
        accountByEmail[AccountEmail.normalized(address)].map { placeholder(account: $0) }
    }

    private func placeholder(account number: Int) -> String {
        namesAccounts ? "[Account \(number) email]" : "[account email]"
    }

    /// Each account's address as stored, case-insensitively, wherever it appears.
    private func replacingStoredAddresses(in text: String) -> String {
        guard text.contains("@") else { return text }
        var result = text
        for address in addresses {
            result = result.replacingOccurrences(of: address.text, with: placeholder(account: address.account),
                                                 options: .caseInsensitive)
        }
        return result
    }

    /// The folded forms a calendar answers to under each of `names`.
    private func forms(of entry: Entry, names: [String]) -> [String] {
        names.flatMap { name -> [String] in
            var result = [Self.fold("\(name) | Account \(entry.account)"), Self.fold("\(name) (Account \(entry.account))")]
            if !namesAccounts { result.append(Self.fold(name)) }
            return result
        }
    }

    /// A calendar the aliases were not built with (it appeared since).
    private static func fallbackName(of calendar: CalendarInfo) -> String {
        if PromptRedaction.containsEmail(calendar.displayName) { return sharedCalendarName }
        let cleaned = cleanName(calendar.displayName)
        return cleaned.isEmpty ? "Calendar" : cleaned
    }

    /// Calendar names are written by other people too: no delimiters of a CALENDARS line or of the flag list, one
    /// line, at most 80 characters.
    private static func cleanName(_ text: String) -> String {
        let spaced = text.components(separatedBy: CharacterSet(charactersIn: "|,").union(.newlines)).joined(separator: " ")
        return String(spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Case-, accent- and width-insensitive, "|" set off by spaces, runs of whitespace as one space.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "|", with: " | ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// A default_calendar value as written, folded, without quotes, a copied "- " or a trailing " (default)".
    private static func query(_ text: String) -> String {
        let quotes = CharacterSet(charactersIn: "\"'“”‘’「」『』").union(.whitespacesAndNewlines)
        var query = fold(text.trimmingCharacters(in: quotes))
        if query.hasPrefix("- ") { query.removeFirst(2) }
        if query.hasSuffix(" (default)") { query.removeLast(" (default)".count) }
        return query.trimmingCharacters(in: .whitespaces)
    }

    /// "[Account 2 email]", "[account email]" and spellings close to them; group 1 is the number when there is one.
    private static let placeholderPattern = #"\[\s*account\s*([0-9]{1,4})?\s*e-?mail\s*\]"#

    /// A folded query that is only a placeholder: N for "[account N email]", 0 for "[account email]" (numbers start
    /// at 1), nil for anything else.
    private static func placeholderAccount(in query: String) -> Int? {
        guard let range = query.range(of: "^" + placeholderPattern + "$", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let digits = String(query[range].filter { $0.isASCII && $0.isNumber })
        return digits.isEmpty ? 0 : Int(digits)
    }

    /// "account 2" / "account2" → 2.
    private static func accountNumber(in query: String) -> Int? {
        guard let range = query.range(of: #"^account ?[0-9]+$"#, options: .regularExpression) else { return nil }
        return Int(String(query[range].filter { $0.isASCII && $0.isNumber }))
    }

    private static func only(_ entries: [Entry]) -> Entry? {
        entries.count == 1 ? entries.first : nil
    }
}
