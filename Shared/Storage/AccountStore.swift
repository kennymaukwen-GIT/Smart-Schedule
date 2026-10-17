import Foundation

/// Connected Google accounts, their calendars and this device's settings for each calendar (visibility, colour,
/// notifications), plus the Focus filter. App Group `accounts.json`, read by every process.
///
/// Demo mode answers with `DemoData.accounts` (and the settings the user gave those sample calendars) instead of
/// the stored accounts, so the drawer, visibility and `default_calendar` work offline. `connectedAccounts()` is
/// always the stored list. Every write posts `SharedChange.accounts`.
actor AccountStore {
    static let shared = AccountStore()
    static let currentVersion = 1

    /// This device's choices for a sample calendar (demo mode).
    struct LocalCalendarSettings: Codable, Hashable, Sendable {
        var isVisible = true
        var colorOverrideHex: String?
        var notificationsEnabled = true
    }

    struct File: Codable, Sendable {
        var version = AccountStore.currentVersion
        var accounts: [GoogleAccount] = []
        var demoCalendarSettings: [String: LocalCalendarSettings] = [:]
        var focusFilter: FocusFilterState?
    }

    private let fileURL: URL
    private let isDemoMode: @Sendable () -> Bool
    private let defaultCalendar: @Sendable () -> CalendarRef?

    init(fileName: String = "accounts.json") {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory
        fileURL = container.appendingPathComponent(fileName)
        isDemoMode = { AppConstants.isDemoMode }
        defaultCalendar = { PreferencesStore.shared.current().defaultCalendar }
    }

    /// Unit tests pass a temporary file and say whether demo mode is on and which calendar the user picked for new
    /// events (normally `AppConstants` and `PreferencesStore`).
    init(fileURL: URL,
         isDemoMode: @escaping @Sendable () -> Bool = { AppConstants.isDemoMode },
         defaultCalendar: @escaping @Sendable () -> CalendarRef? = { PreferencesStore.shared.current().defaultCalendar }) {
        self.fileURL = fileURL
        self.isDemoMode = isDemoMode
        self.defaultCalendar = defaultCalendar
    }

    // MARK: Reads

    /// In connection order. Demo mode: the sample accounts.
    func accounts() -> [GoogleAccount] {
        accounts(in: read())
    }

    func account(id: String) -> GoogleAccount? {
        accounts().first { $0.id == id }
    }

    /// The first connected account: the avatar and the automatic target for new events.
    func primaryAccount() -> GoogleAccount? {
        accounts().first
    }

    /// The stored Google accounts, demo mode or not (tokens, sync, sign-in state).
    func connectedAccounts() -> [GoogleAccount] {
        read().accounts
    }

    func connectedAccount(id: String) -> GoogleAccount? {
        read().accounts.first { $0.id == id }
    }

    func calendars() -> [CalendarInfo] {
        accounts().flatMap(\.calendars)
    }

    func calendar(_ ref: CalendarRef) -> CalendarInfo? {
        calendars().first { $0.id == ref }
    }

    /// Calendars to list from Google: every calendar of every account that can sign in (hidden-in-app ones too, so
    /// showing them again is instant). Empty in demo mode, where nothing is fetched.
    func syncedCalendars() -> [CalendarInfo] {
        guard !isDemoMode() else { return [] }
        return read().accounts.filter { !$0.needsReconnect }.flatMap(\.calendars)
    }

    /// Where new events go: the calendar picked in Settings or by voice while it is connected and writable, else
    /// the primary calendar of the first account. nil when no account is connected.
    func defaultWriteTarget() -> CalendarInfo? {
        defaultWriteTarget(in: accounts(in: read()))
    }

    /// The writable calendar a `default_calendar` value names, matched on this iPhone: an exact `promptLabel`, then an
    /// exact email (that account's primary calendar), then the user's own words: the whole text, or else its words
    /// without filler ("my school account" → "school"), found in the address of exactly one account (its primary
    /// calendar) or else in the name of exactly one writable calendar. Case-insensitive. nil when nothing or more than
    /// one matches, so the assistant asks. The assistant tries `CalendarAliases.writableCalendar(matching:)` (CALENDARS
    /// lines) first and uses this for the user's own words.
    func resolveWritableCalendar(matching text: String) -> CalendarInfo? {
        let query = Self.folded(text)
        guard !query.isEmpty else { return nil }
        let writable = calendars().filter(\.isWritable)

        if let hit = writable.first(where: { Self.folded($0.promptLabel) == query }) { return hit }
        if let bar = query.lastIndex(of: "|") {
            // "<name> | <email>" written with the calendar's own name or the English "My calendar".
            let name = Self.folded(String(query[..<bar]))
            let email = Self.folded(String(query[query.index(after: bar)...]))
            let inAccount = writable.filter { Self.folded($0.accountEmail) == email }
            return inAccount.first { calendar in
                Self.folded(calendar.name) == name || Self.folded(calendar.displayName) == name
                    || (calendar.isPrimary && name == "my calendar")
            }
        }
        if let hit = writable.first(where: { $0.isPrimary && Self.folded($0.accountEmail) == query }) { return hit }
        switch Self.match([query], in: writable) {
        case .one(let calendar): return calendar
        case .ambiguous: return nil
        case .nothing: break
        }
        let words = Self.contentWords(of: query)
        guard !words.isEmpty, words != [query],
              case .one(let calendar) = Self.match(words, in: writable) else { return nil }
        return calendar
    }

    /// What the user's words found among the writable calendars.
    private enum WordMatch {
        case nothing, ambiguous
        case one(CalendarInfo)
    }

    /// Accounts whose address holds every term (that account's primary calendar, unless a calendar of another account
    /// is named by them too), else writable calendars whose name holds every term. Only a single hit counts.
    private static func match(_ terms: [String], in writable: [CalendarInfo]) -> WordMatch {
        guard !terms.isEmpty else { return .nothing }
        func holds(_ text: String) -> Bool {
            let folded = Self.folded(text)
            return terms.allSatisfy { folded.contains($0) }
        }
        let named = writable.filter { holds($0.displayName) || holds($0.name) }
        let accounts = Set(writable.filter { holds($0.accountEmail) }.map(\.accountID))
        if accounts.count > 1 { return .ambiguous }
        if let account = accounts.first {
            guard !named.contains(where: { $0.accountID != account }),
                  let primary = writable.first(where: { $0.accountID == account && $0.isPrimary }) else {
                return .ambiguous
            }
            return .one(primary)
        }
        switch named.count {
        case 0: return .nothing
        case 1: return .one(named[0])
        default: return .ambiguous
        }
    }

    /// Words that say nothing about which account or calendar is meant.
    private static let fillerWords: Set<String> = ["my", "the", "a", "an", "account", "accounts", "calendar", "calendars",
                                                   "email", "e-mail", "address", "google"]
    /// The same in Chinese, removed wherever they appear (no spaces between Chinese words): "我的學校帳號" → "學校".
    private static let fillerPhrases = ["我的", "帳號", "帐号", "帳戶", "行事曆", "日曆", "日历", "信箱", "的"]

    /// The folded text's words without filler and surrounding punctuation: "my school account" → ["school"].
    private static func contentWords(of query: String) -> [String] {
        let punctuation = CharacterSet(charactersIn: "\"'“”‘’「」『』()[]{},.!?;:！？，。；：、")
        return query.split(whereSeparator: \.isWhitespace).compactMap { piece -> String? in
            var word = String(piece).trimmingCharacters(in: punctuation)
            if word.hasSuffix("'s") || word.hasSuffix("’s") { word = String(word.dropLast(2)) }
            guard !fillerWords.contains(word) else { return nil }
            for phrase in fillerPhrases { word = word.replacingOccurrences(of: phrase, with: "") }
            return word.isEmpty ? nil : word
        }
    }

    func visibilityRules() -> VisibilityRules {
        let file = read()
        let listed = accounts(in: file)
        var rules = VisibilityRules()
        rules.isDemoMode = isDemoMode()
        var rank = 0
        for calendar in listed.flatMap(\.calendars) {
            let key = calendar.id.key
            if !calendar.isVisible { rules.hidden.insert(key) }
            if !calendar.notificationsEnabled { rules.muted.insert(key) }
            if calendar.isWritable { rules.writable.insert(key) }
            rules.calendarColors[key] = calendar.displayColorHex
            if rules.rank[key] == nil {
                rules.rank[key] = rank
                rank += 1
            }
        }
        if let focus = file.focusFilter, !focus.calendars.isEmpty {
            rules.focusAllowed = Set(focus.calendars.map(\.key))
        }
        rules.defaultTarget = defaultWriteTarget(in: listed)?.id.key
        return rules
    }

    func focusFilter() -> FocusFilterState? {
        read().focusFilter
    }

    // MARK: Local calendar settings (sample calendars too)

    func setVisible(_ visible: Bool, calendar: CalendarRef) {
        updateLocalSettings(of: calendar) { $0.isVisible = visible }
    }

    /// nil goes back to Google's colour.
    func setColorOverride(_ hex: String?, calendar: CalendarRef) {
        updateLocalSettings(of: calendar) { $0.colorOverrideHex = hex }
    }

    func setNotificationsEnabled(_ enabled: Bool, calendar: CalendarRef) {
        updateLocalSettings(of: calendar) { $0.notificationsEnabled = enabled }
    }

    /// nil or empty clears the filter (the Focus ended). Calendars that are not here any more (a Focus set up before
    /// their account was removed) are left out.
    func setFocusFilter(_ calendars: [CalendarRef]?) {
        mutate { file in
            // The stored accounts and, in demo mode, the sample ones: a Focus naming real calendars survives a demo.
            let known = Set((file.accounts + accounts(in: file)).flatMap(\.calendars).map(\.id))
            let kept = calendars?.filter { known.contains($0) }
            let state = kept.flatMap { $0.isEmpty ? nil : FocusFilterState(calendars: $0, updatedAt: Date()) }
            guard state?.calendars != file.focusFilter?.calendars else { return false }
            file.focusFilter = state
            return true
        }
    }

    // MARK: Account lifecycle

    /// Adds the account at the end, or replaces the stored one with the same id in place.
    func upsert(_ account: GoogleAccount) {
        mutate { file in
            if let index = file.accounts.firstIndex(where: { $0.id == account.id }) {
                guard file.accounts[index] != account else { return false }
                file.accounts[index] = account
            } else {
                file.accounts.append(account)
            }
            return true
        }
    }

    /// A fresh calendar list for the account. Calendars already known keep this device's settings; new ones keep
    /// what the caller set (visible when Google shows them, notifications on). Returns the calendars that are gone,
    /// whose cached events the caller purges.
    @discardableResult
    func replaceCalendars(_ calendars: [CalendarInfo], accountID: String) -> [CalendarRef] {
        var removed: [CalendarRef] = []
        mutate { file in
            guard let index = file.accounts.firstIndex(where: { $0.id == accountID }) else { return false }
            var account = file.accounts[index]
            let known = Dictionary(account.calendars.map { ($0.calendarID, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            let merged = calendars.compactMap { incoming -> CalendarInfo? in
                guard seen.insert(incoming.calendarID).inserted else { return nil }
                var calendar = incoming
                calendar.accountID = accountID
                calendar.accountEmail = account.email
                if let old = known[calendar.calendarID] {
                    calendar.isVisible = old.isVisible
                    calendar.colorOverrideHex = old.colorOverrideHex
                    calendar.notificationsEnabled = old.notificationsEnabled
                }
                return calendar
            }
            removed = account.calendars.filter { !seen.contains($0.calendarID) }.map(\.id)
            account.calendars = CalendarInfo.sorted(merged)
            account.calendarsUpdatedAt = Date()
            file.accounts[index] = account
            if let focus = file.focusFilter {
                let kept = focus.calendars.filter { !removed.contains($0) }
                file.focusFilter = kept.isEmpty ? nil : FocusFilterState(calendars: kept, updatedAt: focus.updatedAt)
            }
            return true
        }
        return removed
    }

    func setNeedsReconnect(_ needs: Bool, accountID: String) {
        mutate { file in
            guard let index = file.accounts.firstIndex(where: { $0.id == accountID }),
                  file.accounts[index].needsReconnect != needs else { return false }
            file.accounts[index].needsReconnect = needs
            return true
        }
    }

    func remove(accountID: String) {
        mutate { file in
            guard file.accounts.contains(where: { $0.id == accountID }) else { return false }
            file.accounts.removeAll { $0.id == accountID }
            if let focus = file.focusFilter {
                let kept = focus.calendars.filter { $0.accountID != accountID }
                file.focusFilter = kept.isEmpty ? nil : FocusFilterState(calendars: kept, updatedAt: focus.updatedAt)
            }
            return true
        }
    }

    /// Deletes the file: no accounts, no demo calendar settings, no Focus filter.
    func eraseAll() {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinationError) { url in
            try? FileManager.default.removeItem(at: url)
        }
        SharedChangeNotifier.post(.accounts)
    }

    // MARK: Helpers

    private func accounts(in file: File) -> [GoogleAccount] {
        guard isDemoMode() else { return file.accounts }
        return DemoData.accounts.map { account in
            var account = account
            account.calendars = account.calendars.map { calendar in
                guard let settings = file.demoCalendarSettings[calendar.id.key] else { return calendar }
                var calendar = calendar
                calendar.isVisible = settings.isVisible
                calendar.colorOverrideHex = settings.colorOverrideHex
                calendar.notificationsEnabled = settings.notificationsEnabled
                return calendar
            }
            return account
        }
    }

    private func defaultWriteTarget(in accounts: [GoogleAccount]) -> CalendarInfo? {
        let calendars = accounts.flatMap(\.calendars)
        if let chosen = defaultCalendar(), let calendar = calendars.first(where: { $0.id == chosen }), calendar.isWritable {
            return calendar
        }
        if isDemoMode(), let demo = calendars.first(where: { $0.id == DemoData.defaultCalendar }) { return demo }
        guard let first = accounts.first else { return nil }
        return first.primaryCalendar ?? first.calendars.first(where: \.isWritable)
    }

    private func updateLocalSettings(of ref: CalendarRef, _ change: @escaping (inout LocalCalendarSettings) -> Void) {
        mutate { file in
            if ref.accountID.hasPrefix(DemoData.idPrefix) {
                guard let sample = DemoData.accounts.flatMap(\.calendars).first(where: { $0.id == ref }) else { return false }
                var settings = file.demoCalendarSettings[ref.key]
                    ?? LocalCalendarSettings(isVisible: sample.isVisible, colorOverrideHex: sample.colorOverrideHex,
                                             notificationsEnabled: sample.notificationsEnabled)
                let before = settings
                change(&settings)
                guard settings != before else { return false }
                file.demoCalendarSettings[ref.key] = settings
                return true
            }
            guard let accountIndex = file.accounts.firstIndex(where: { $0.id == ref.accountID }),
                  let calendarIndex = file.accounts[accountIndex].calendars.firstIndex(where: { $0.calendarID == ref.calendarID })
            else { return false }
            let calendar = file.accounts[accountIndex].calendars[calendarIndex]
            var settings = LocalCalendarSettings(isVisible: calendar.isVisible, colorOverrideHex: calendar.colorOverrideHex,
                                                 notificationsEnabled: calendar.notificationsEnabled)
            let before = settings
            change(&settings)
            guard settings != before else { return false }
            file.accounts[accountIndex].calendars[calendarIndex].isVisible = settings.isVisible
            file.accounts[accountIndex].calendars[calendarIndex].colorOverrideHex = settings.colorOverrideHex
            file.accounts[accountIndex].calendars[calendarIndex].notificationsEnabled = settings.notificationsEnabled
            return true
        }
    }

    /// Case-, width- and accent-insensitive, trimmed.
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: File I/O

    private func read() -> File {
        var result = File()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            result = (try? decoder.decode(File.self, from: data)) ?? File()
        }
        return result
    }

    /// One coordinated read-modify-write; `change` returns false when nothing changed, which skips the write and
    /// the change notification.
    private func mutate(_ change: (inout File) -> Bool) {
        var changed = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            var file = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(File.self, from: $0) } ?? File()
            guard change(&file) else { return }
            file.version = max(file.version, Self.currentVersion)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            changed = (try? encoder.encode(file).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
        }
        if changed { SharedChangeNotifier.post(.accounts) }
    }
}

extension AccountStore {
    /// The sample accounts only, whatever the demo flag says, with this device's settings for their calendars (the
    /// same App Group `accounts.json`). A `CalendarRouter` built on it adds new events to a sample calendar, even when
    /// demo mode ends while a request is running.
    static func sampleCalendarsOnly() -> AccountStore {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
            ?? FileManager.default.temporaryDirectory
        return AccountStore(fileURL: container.appendingPathComponent("accounts.json"), isDemoMode: { true })
    }
}

extension AccountStore.File {
    /// Tolerant: a newer build's file still yields the accounts this build understands, and one bad entry is
    /// skipped instead of losing every account.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? AccountStore.currentVersion
        accounts = ((try? c.decodeIfPresent([AccountsFileElement<GoogleAccount>].self, forKey: .accounts)) ?? [])
            .compactMap(\.value)
        demoCalendarSettings = (try? c.decodeIfPresent([String: AccountStore.LocalCalendarSettings].self,
                                                       forKey: .demoCalendarSettings)) ?? [:]
        focusFilter = try? c.decodeIfPresent(FocusFilterState.self, forKey: .focusFilter)
    }
}

extension AccountStore.LocalCalendarSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = (try? c.decodeIfPresent(Bool.self, forKey: .isVisible)) ?? true
        colorOverrideHex = try? c.decodeIfPresent(String.self, forKey: .colorOverrideHex)
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? true
    }
}
