import Foundation

/// Adding, reconnecting and removing Google accounts, the calendar lists, and the one-time move of the
/// single-account version's sign-in to per-account storage.
///
/// Smart Schedule has no accounts of its own: removing one ("Remove account", `disconnect`) revokes the Google
/// grant, deletes the token and removes that account's cached events from this iPhone; nothing is deleted from
/// Google Calendar.
@MainActor
final class AccountManager {
    static let shared = AccountManager()

    enum AccountError: LocalizedError {
        /// Reconnect signed in to another Google account; nothing was stored.
        case differentAccount(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case let .differentAccount(expected, actual):
                String(localized: "You signed in as \(actual). Choose \(expected) to reconnect.")
            }
        }
    }

    /// Calendar lists older than this are fetched again when the app becomes active or the drawer opens.
    static let calendarListMaxAge: TimeInterval = 6 * 3600
    private static let userInfoEndpoint = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!

    private let accounts: AccountStore = .shared
    private let tokens: GoogleTokenProvider = .shared
    private let store: SharedStore = .shared
    private var isMigrating = false

    // MARK: Migration

    /// The single-account version kept one token under `google.oauth` and cached events without a calendar. Moves it
    /// to `google.oauth.<sub>` with an account record, then lists the account's calendars. Idempotent, and safe to
    /// call often: without a legacy token it only reads the Keychain. Offline, it waits for the next call.
    func migrateLegacyAccountIfNeeded() async {
        guard !isMigrating else { return }
        isMigrating = true
        defer { isMigrating = false }

        let legacyKey = GoogleTokenProvider.legacyKeychainKey
        if !(await accounts.connectedAccounts()).isEmpty {
            KeychainStore.delete(key: legacyKey)
            return
        }
        guard KeychainStore.load(GoogleTokens.self, key: legacyKey) != nil else { return }

        // No account yet, so this refreshes the legacy item if needed (invalid_grant deletes it: Connect is shown).
        guard let accessToken = try? await tokens.accessToken(accountID: nil),
              let identity = await Self.userInfo(accessToken: accessToken),
              var legacy = KeychainStore.load(GoogleTokens.self, key: legacyKey) else { return }

        legacy.email = identity.email
        legacy.scopes = GoogleTokenProvider.legacyScopes
        do {
            try await tokens.store(legacy, accountID: identity.subject)
        } catch {
            return
        }
        let email = identity.email ?? ""
        await accounts.upsert(GoogleAccount(id: identity.subject,
                                            email: email,
                                            connectedAt: Date(),
                                            grantedScopes: GoogleTokenProvider.legacyScopes,
                                            calendars: [Self.placeholderPrimary(accountID: identity.subject, email: email)]))
        // Without the calendar-list scope Google answers 403: the drawer then offers "Show all calendars".
        await refreshCalendarList(accountID: identity.subject)

        KeychainStore.delete(key: legacyKey)
        await store.dropUnscopedGoogleEvents()
        try? await CalendarSync().refreshWindow()
    }

    // MARK: Connect

    /// How the add page's sign-in ended.
    enum AddOutcome {
        /// A new account, stored with its calendars.
        case connected(GoogleAccount)
        /// That Google account was connected already: its tokens, scopes and calendars were refreshed.
        case alreadyConnected(GoogleAccount)
        /// Google signed in `signedIn`, not the `typed` email. Nothing is stored: "Add <signedIn>" passes `pending`
        /// to `addPending(_:)`, "Cancel" to `discardPending(_:)`.
        case mismatch(signedIn: String, typed: String, pending: GoogleSignInResult)
        /// The user closed Google's page.
        case cancelled
    }

    /// The add page: signs in with `email` as Google's login hint (nil: Google's account chooser), then connects the
    /// account unless Google signed in another one than typed. Choosing one that is already connected refreshes
    /// its tokens and scopes (same as reconnecting).
    /// - Throws: `GoogleSignInFailure` (an admin's block, the calendar permission left unticked, no connection) or
    ///   another sign-in error.
    func addAccount(email: String? = nil) async throws -> AddOutcome {
        await migrateLegacyAccountIfNeeded()
        let typed = email.map(AccountEmail.trimmed).flatMap { $0.isEmpty ? nil : $0 }
        let result: GoogleSignInResult
        do {
            result = try await GoogleSignInCoordinator().signIn(loginHint: typed)
        } catch GoogleSignInCoordinator.SignInError.cancelled {
            return .cancelled
        }
        let connectedIDs = await accounts.connectedAccounts().map(\.id)
        switch AddAccountDecision.decide(typed: typed,
                                         signedInEmail: result.email,
                                         signedInAccountID: result.accountID,
                                         grantedScopes: result.grantedScopes,
                                         connectedAccountIDs: Set(connectedIDs)) {
        case .calendarAccessMissing:
            await discardPending(result)
            throw GoogleSignInFailure.calendarAccessMissing
        case let .mismatch(signedIn, typedEmail):
            return .mismatch(signedIn: signedIn, typed: typedEmail, pending: result)
        case .alreadyConnected:
            let account = await connect(result)
            return .alreadyConnected(account)
        case .connect:
            let account = await connect(result)
            return .connected(account)
        }
    }

    /// "Add <signed-in email>" after a mismatch: keeps the sign-in Google returned.
    func addPending(_ result: GoogleSignInResult) async -> AddOutcome {
        let wasConnected = await accounts.connectedAccount(id: result.accountID) != nil
        let account = await connect(result)
        return wasConnected ? .alreadyConnected(account) : .connected(account)
    }

    /// A sign-in that is not kept ("Cancel" after a mismatch, the calendar permission left unticked): the grant
    /// Google just issued is revoked, unless that account is connected here, whose grant it is too.
    func discardPending(_ result: GoogleSignInResult) async {
        guard await accounts.connectedAccount(id: result.accountID) == nil else { return }
        await GoogleTokenProvider.revoke(token: result.tokens.refreshToken)
    }

    /// Signs in again for an account whose refresh token stopped working, or to grant the calendar-list scope
    /// ("Show all calendars"). Signing in as another account stores nothing.
    func reconnect(accountID: String) async throws {
        guard let account = await accounts.connectedAccount(id: accountID) else { throw AuthError.signedOut }
        let result = try await GoogleSignInCoordinator().signIn(loginHint: account.email)
        guard result.accountID == accountID else {
            throw AccountError.differentAccount(expected: account.email, actual: result.email)
        }
        await connect(result)
    }

    @discardableResult
    private func connect(_ result: GoogleSignInResult) async -> GoogleAccount {
        let id = result.accountID
        var account: GoogleAccount
        if let existing = await accounts.connectedAccount(id: id) {
            account = existing
            account.needsReconnect = false
            if !result.email.isEmpty { account.email = result.email }
            account.grantedScopes = Array(Set(existing.grantedScopes).union(result.grantedScopes)).sorted()
        } else {
            account = GoogleAccount(id: id,
                                    email: result.email,
                                    connectedAt: Date(),
                                    grantedScopes: result.grantedScopes,
                                    calendars: [Self.placeholderPrimary(accountID: id, email: result.email)])
        }
        try? await tokens.store(result.tokens, accountID: id)
        await accounts.upsert(account)
        await refreshCalendarList(accountID: id)

        let calendars = await accounts.connectedAccount(id: id)?.calendars.map(\.id) ?? []
        try? await CalendarSync(calendars: calendars).refreshWindow()
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
        return await accounts.connectedAccount(id: id) ?? account
    }

    // MARK: Remove

    /// "Remove account": revokes the grant, deletes the token, this account's cached events, range bookkeeping and
    /// queued changes, and forgets the account (its calendars leave the Focus filter). A default calendar or "Ask me
    /// first" batch in it is cleared. Google Calendar keeps everything.
    func disconnect(accountID: String) async {
        await tokens.revoke(accountID: accountID)
        await tokens.signOut(accountID: accountID)
        await store.purge(accountID: accountID)
        await accounts.remove(accountID: accountID)
        await forgetChoices { $0 == accountID }
        // Its queued changes can never be sent; the status line stops counting them.
        await SyncOutbox.shared.removeAll(accountID: accountID)
        let queued = await SyncOutbox.shared.items()
        SyncStatusStore.update { status in
            status.pendingCount = queued.filter { !$0.isFailed }.count
            status.failed = queued.compactMap(\.failedChange)
            status.lastSuccess[accountID] = nil
        }
        await ReminderScheduler.shared.reschedule()
        await LiveActivityManager.shared.refreshIfRunning()
    }

    /// Every account (erase all data): the steps of `disconnect` for each, then every token item, the legacy one
    /// included, and the accounts file. Reminders and the Live Activity are left to the caller, which removes them.
    func disconnectAll(revoke: Bool) async {
        if revoke { await tokens.revokeAll() }
        let connected = await accounts.connectedAccounts()
        for account in connected {
            await store.purge(accountID: account.id)
        }
        await tokens.signOutAll()
        await accounts.eraseAll()
        let ids = Set(connected.map(\.id))
        await forgetChoices { ids.contains($0) }
    }

    private func forgetChoices(of matches: (String) -> Bool) async {
        if let chosen = PreferencesStore.shared.current().defaultCalendar, matches(chosen.accountID) {
            await PreferencesStore.shared.update(source: .settings) { $0.reset(.defaultCalendar) }
        }
        if let batch = await store.pendingEventBatch(), let target = batch.target, matches(target.accountID) {
            await store.setPendingEventBatch(nil)
        }
    }

    // MARK: Calendar lists

    /// Lists the calendars of every account that may (calendar-list scope granted, sign-in working) and whose list is
    /// older than 6 h, or all of them with `force`. Also finishes a migration that could not run offline.
    func refreshCalendarLists(force: Bool = false) async {
        await migrateLegacyAccountIfNeeded()
        guard !AppConstants.isDemoMode else { return }
        let now = Date()
        for account in await accounts.connectedAccounts() where account.canListCalendars && !account.needsReconnect {
            if !force, let updated = account.calendarsUpdatedAt, now.timeIntervalSince(updated) < Self.calendarListMaxAge {
                continue
            }
            await refreshCalendarList(accountID: account.id)
        }
    }

    /// One account's calendar list: new calendars are synced right away, calendars that are gone leave the cache.
    /// Any failure (no scope, offline) keeps the calendars known so far.
    private func refreshCalendarList(accountID: String) async {
        guard let account = await accounts.connectedAccount(id: accountID),
              let entries = try? await GoogleCalendarClient(accountID: accountID, tokens: tokens).listCalendars() else { return }
        let calendars = entries.compactMap { $0.calendarInfo(accountID: accountID, accountEmail: account.email) }
        guard !calendars.isEmpty else { return }

        if !account.canListCalendars {
            var updated = account
            updated.grantedScopes.append(GoogleAccount.calendarListScope)
            await accounts.upsert(updated)
        }
        let known = Set(account.calendars.map(\.id))
        let removed = await accounts.replaceCalendars(calendars, accountID: accountID)
        for ref in removed { await store.purge(calendar: ref) }
        let added = calendars.map(\.id).filter { !known.contains($0) }
        if !added.isEmpty { try? await CalendarSync(calendars: added).refreshWindow() }
    }

    // MARK: Helpers

    /// Until the calendar list arrives (or when it cannot be read): the primary calendar, whose id is the email.
    private static func placeholderPrimary(accountID: String, email: String) -> CalendarInfo {
        CalendarInfo(accountID: accountID, accountEmail: email, calendarID: email, name: email,
                     isPrimary: true, accessRole: "owner", googleColorHex: CalendarInfo.defaultColorHex)
    }

    /// `sub` and `email` of the token's account (the legacy `openid email` scopes allow it).
    private static func userInfo(accessToken: String) async -> IDToken? {
        var request = URLRequest(url: userInfoEndpoint, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any],
              let subject = json["sub"] as? String, !subject.isEmpty else { return nil }
        return IDToken(subject: subject, email: json["email"] as? String)
    }
}
