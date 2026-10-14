import XCTest

/// Connected accounts and this device's settings for each calendar, in a temporary `accounts.json`.
final class AccountStoreTests: XCTestCase {
    private let files = TemporaryStoreFiles()

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private let kenny = SampleAccounts.account("111", email: "kenny@example.com", extra: [
        SampleAccounts.calendar("111", "gym@group.calendar.google.com", email: "kenny@example.com", name: "Gym"),
        SampleAccounts.calendar("111", "holidays@group.v.calendar.google.com", email: "kenny@example.com",
                                name: "Holidays", role: "reader")
    ])
    private let student = SampleAccounts.account("222", email: "example@yourmail.com")

    private func makeStore(demo: Bool = false, defaultCalendar: CalendarRef? = nil,
                           url: URL? = nil) -> AccountStore {
        AccountStore(fileURL: url ?? files.url("AccountStoreTests"),
                     isDemoMode: { demo },
                     defaultCalendar: { defaultCalendar })
    }

    private func connected(_ store: AccountStore) async {
        await store.upsert(kenny)
        await store.upsert(student)
    }

    // MARK: Lifecycle

    func testAccountsKeepConnectionOrderAndUpsertReplacesInPlace() async {
        let store = makeStore()
        await connected(store)
        var renamed = kenny
        renamed.email = "kenny.new@example.com"
        await store.upsert(renamed)

        let accounts = await store.accounts()
        XCTAssertEqual(accounts.map(\.id), ["111", "222"])
        XCTAssertEqual(accounts.first?.email, "kenny.new@example.com")
        let primary = await store.primaryAccount()
        XCTAssertEqual(primary?.id, "111")
        let calendars = await store.calendars()
        XCTAssertEqual(calendars.count, 4)

        await store.setNeedsReconnect(true, accountID: "222")
        let synced = await store.syncedCalendars()
        XCTAssertEqual(Set(synced.map(\.accountID)), ["111"], "an account that must reconnect is not listed")

        await store.remove(accountID: "111")
        let left = await store.accounts()
        XCTAssertEqual(left.map(\.id), ["222"])
        XCTAssertEqual(left.first?.needsReconnect, true)

        await store.eraseAll()
        let erased = await store.accounts()
        XCTAssertTrue(erased.isEmpty)
    }

    func testLocalSettingsSurviveACalendarListRefresh() async {
        let store = makeStore()
        await connected(store)
        let gym = CalendarRef(accountID: "111", calendarID: "gym@group.calendar.google.com")
        await store.setVisible(false, calendar: gym)
        await store.setColorOverride("#D50000", calendar: gym)
        await store.setNotificationsEnabled(false, calendar: gym)

        // Google renamed Gym, dropped Holidays and added Running (not shown in Google's own list).
        let fresh = [
            SampleAccounts.calendar("111", "kenny@example.com", name: "kenny@example.com", primary: true, hex: "#9FE1E7"),
            SampleAccounts.calendar("111", "gym@group.calendar.google.com", name: "Gym & Pool", visible: true),
            SampleAccounts.calendar("111", "running@group.calendar.google.com", name: "Running", role: "writer", visible: false)
        ]
        let removed = await store.replaceCalendars(fresh, accountID: "111")
        XCTAssertEqual(removed, [CalendarRef(accountID: "111", calendarID: "holidays@group.v.calendar.google.com")])

        let account = await store.account(id: "111")
        XCTAssertEqual(account?.calendars.map(\.name), ["kenny@example.com", "Gym & Pool", "Running"])
        XCTAssertNotNil(account?.calendarsUpdatedAt)
        let updatedGym = await store.calendar(gym)
        XCTAssertEqual(updatedGym?.isVisible, false)
        XCTAssertEqual(updatedGym?.colorOverrideHex, "#D50000")
        XCTAssertEqual(updatedGym?.displayColorHex, "#D50000")
        XCTAssertEqual(updatedGym?.notificationsEnabled, false)
        let running = await store.calendar(CalendarRef(accountID: "111", calendarID: "running@group.calendar.google.com"))
        XCTAssertEqual(running?.isVisible, false)
        XCTAssertEqual(running?.accountEmail, "kenny@example.com")
        XCTAssertEqual(account?.primaryCalendar?.googleColorHex, "#9FE1E7")
    }

    func testCalendarsSortPrimaryThenRoleThenName() {
        let sorted = CalendarInfo.sorted([
            SampleAccounts.calendar("1", "c", name: "Zoo", role: "reader"),
            SampleAccounts.calendar("1", "b", name: "beta", role: "writer"),
            SampleAccounts.calendar("1", "a", name: "Alpha", role: "writer"),
            SampleAccounts.calendar("1", "p", name: "me", primary: true),
            SampleAccounts.calendar("1", "o", name: "Owned")
        ])
        XCTAssertEqual(sorted.map(\.calendarID), ["p", "o", "a", "b", "c"])
    }

    // MARK: Where new events go

    func testDefaultWriteTargetFallsBackToTheFirstAccountsPrimaryCalendar() async {
        let schoolPrimary = CalendarRef(accountID: "222", calendarID: "example@yourmail.com")
        let chosen = makeStore(defaultCalendar: schoolPrimary)
        await connected(chosen)
        let chosenTarget = await chosen.defaultWriteTarget()
        XCTAssertEqual(chosenTarget?.id, schoolPrimary)

        let url = files.url("AccountStoreTests-target")
        let readOnly = makeStore(defaultCalendar: CalendarRef(accountID: "111", calendarID: "holidays@group.v.calendar.google.com"), url: url)
        await connected(readOnly)
        let fallback = await readOnly.defaultWriteTarget()
        XCTAssertEqual(fallback?.id, CalendarRef(accountID: "111", calendarID: "kenny@example.com"))

        let disconnected = makeStore(defaultCalendar: CalendarRef(accountID: "999", calendarID: "gone@example.com"), url: url)
        let stillPrimary = await disconnected.defaultWriteTarget()
        XCTAssertEqual(stillPrimary?.calendarID, "kenny@example.com")

        let empty = makeStore(defaultCalendar: schoolPrimary)
        let none = await empty.defaultWriteTarget()
        XCTAssertNil(none)
    }

    func testResolvingADefaultCalendarValue() async {
        let store = makeStore()
        await connected(store)
        // The CALENDARS line exactly, in either language's "My calendar".
        let english = await store.resolveWritableCalendar(matching: "My calendar | example@yourmail.com")
        XCTAssertEqual(english?.accountID, "222")
        let ownName = await store.resolveWritableCalendar(matching: "gym | KENNY@example.com")
        XCTAssertEqual(ownName?.calendarID, "gym@group.calendar.google.com")
        // An email: that account's primary calendar.
        let email = await store.resolveWritableCalendar(matching: "kenny@example.com")
        XCTAssertEqual(email?.calendarID, "kenny@example.com")
        // Part of an email, a domain or a name.
        let domain = await store.resolveWritableCalendar(matching: "yourmail")
        XCTAssertEqual(domain?.accountID, "222")
        let name = await store.resolveWritableCalendar(matching: "Gym")
        XCTAssertEqual(name?.calendarID, "gym@group.calendar.google.com")
        // Read-only calendars and unknown text match nothing.
        let readOnly = await store.resolveWritableCalendar(matching: "Holidays")
        XCTAssertNil(readOnly)
        let unknown = await store.resolveWritableCalendar(matching: "My calendar | nobody@example.com")
        XCTAssertNil(unknown)
        let blank = await store.resolveWritableCalendar(matching: "  ")
        XCTAssertNil(blank)
    }

    func testPromptLabelIsOneLine() {
        var calendar = SampleAccounts.calendar("1", "x", email: "a@example.com", name: "Team | Ops\nRota")
        XCTAssertEqual(calendar.promptLabel, "Team Ops Rota | a@example.com")
        calendar.isPrimary = true
        XCTAssertEqual(calendar.promptLabel, "My calendar | a@example.com")
        XCTAssertEqual(GoogleAccount(id: "1", email: "example@gmail.com", connectedAt: Date()).initial, "E")
        XCTAssertEqual(GoogleAccount(id: "1", email: "2026@yourmail.com", connectedAt: Date()).initial, "2")
    }

    // MARK: Visibility rules and the Focus filter

    func testVisibilityRulesListEveryCalendar() async {
        let gym = CalendarRef(accountID: "111", calendarID: "gym@group.calendar.google.com")
        let schoolPrimary = CalendarRef(accountID: "222", calendarID: "example@yourmail.com")
        let store = makeStore(defaultCalendar: schoolPrimary)
        await connected(store)
        await store.setVisible(false, calendar: gym)
        await store.setNotificationsEnabled(false, calendar: schoolPrimary)
        await store.setColorOverride("#33B679", calendar: schoolPrimary)

        var rules = await store.visibilityRules()
        XCTAssertFalse(rules.isDemoMode)
        XCTAssertEqual(rules.hidden, [gym.key])
        XCTAssertEqual(rules.muted, [schoolPrimary.key])
        XCTAssertEqual(rules.calendarColors[schoolPrimary.key], "#33B679")
        XCTAssertFalse(rules.writable.contains("111/holidays@group.v.calendar.google.com"))
        XCTAssertEqual(rules.rank["111/kenny@example.com"], 0)
        XCTAssertEqual(rules.rank[schoolPrimary.key], 3)
        XCTAssertEqual(rules.defaultTarget, schoolPrimary.key)
        XCTAssertNil(rules.focusAllowed)

        await store.setFocusFilter([schoolPrimary])
        rules = await store.visibilityRules()
        XCTAssertEqual(rules.focusAllowed, [schoolPrimary.key])
        let focus = await store.focusFilter()
        XCTAssertEqual(focus?.calendars, [schoolPrimary])

        await store.setFocusFilter(nil) // the Focus ended
        rules = await store.visibilityRules()
        XCTAssertNil(rules.focusAllowed)
        await store.setFocusFilter([])
        let cleared = await store.focusFilter()
        XCTAssertNil(cleared)
    }

    // MARK: Demo mode

    func testDemoModeListsTheSampleAccountsWithTheirOwnSettings() async {
        let url = files.url("AccountStoreTests-demo")
        let demo = makeStore(demo: true, url: url)
        await demo.upsert(kenny) // a real account stays stored but is not listed in demo mode

        let accounts = await demo.accounts()
        XCTAssertEqual(accounts.map(\.email), [DemoData.personalEmail, DemoData.schoolEmail])
        XCTAssertTrue(accounts.allSatisfy(\.isDemo))
        let synced = await demo.syncedCalendars()
        XCTAssertTrue(synced.isEmpty, "nothing is fetched in demo mode")
        let connected = await demo.connectedAccounts()
        XCTAssertEqual(connected.map(\.id), ["111"])
        let target = await demo.defaultWriteTarget()
        XCTAssertEqual(target?.id, DemoData.defaultCalendar)

        await demo.setVisible(false, calendar: DemoData.gymCalendar)
        await demo.setColorOverride("#8E24AA", calendar: DemoData.schoolCalendar)
        let gym = await demo.calendar(DemoData.gymCalendar)
        XCTAssertEqual(gym?.isVisible, false)
        let rules = await demo.visibilityRules()
        XCTAssertTrue(rules.isDemoMode)
        XCTAssertEqual(rules.hidden, [DemoData.gymCalendar.key])
        XCTAssertEqual(rules.calendarColors[DemoData.schoolCalendar.key], "#8E24AA")

        let school = await demo.resolveWritableCalendar(matching: "yourmail")
        XCTAssertEqual(school?.id, DemoData.schoolCalendar)

        // The stored account was not touched, and outside demo mode it is what is listed.
        let real = makeStore(url: url)
        let listed = await real.accounts()
        XCTAssertEqual(listed.map(\.id), ["111"])
        XCTAssertEqual(listed.first?.calendars.allSatisfy(\.isVisible), true, "sample settings never touch real calendars")
    }

    // MARK: File format

    func testToleratesUnknownFieldsMissingFieldsAndBadEntries() async throws {
        let url = files.url("AccountStoreTests-decode")
        let json = """
        {"version": 7, "future": {"x": 1},
         "accounts": [
           {"id": "111", "email": "kenny@example.com", "calendars": [
              {"accountID": "111", "calendarID": "kenny@example.com", "isPrimary": true, "newField": 3},
              {"calendarID": "no-account"}
           ]},
           {"email": "no-id@example.com"},
           {"id": "222", "email": "example@yourmail.com", "needsReconnect": true}
         ],
         "demoCalendarSettings": {"demo-personal/demo-gym": {"isVisible": false}},
         "focusFilter": {"calendars": [{"accountID": "111", "calendarID": "kenny@example.com"}, {"bad": true}]}}
        """
        try Data(json.utf8).write(to: url)
        let store = makeStore(url: url)

        let accounts = await store.accounts()
        XCTAssertEqual(accounts.map(\.id), ["111", "222"])
        let primary = try XCTUnwrap(accounts.first?.calendars.first)
        XCTAssertEqual(accounts.first?.calendars.count, 1)
        XCTAssertTrue(primary.isPrimary)
        XCTAssertEqual(primary.name, "kenny@example.com")
        XCTAssertEqual(primary.googleColorHex, CalendarInfo.defaultColorHex)
        XCTAssertTrue(primary.isVisible)
        XCTAssertTrue(primary.notificationsEnabled)
        XCTAssertEqual(accounts.last?.needsReconnect, true)
        let focus = await store.focusFilter()
        XCTAssertEqual(focus?.calendars, [CalendarRef(accountID: "111", calendarID: "kenny@example.com")])

        let demo = makeStore(demo: true, url: url)
        let gym = await demo.calendar(DemoData.gymCalendar)
        XCTAssertEqual(gym?.isVisible, false)

        // A write keeps what this build understood.
        await store.setVisible(false, calendar: CalendarRef(accountID: "111", calendarID: "kenny@example.com"))
        let reread = await makeStore(url: url).calendars()
        XCTAssertEqual(reread.first?.isVisible, false)
    }

    func testCalendarRefKeyRoundTrip() {
        let ref = CalendarRef(accountID: "111", calendarID: "c_abc123@group.calendar.google.com")
        XCTAssertEqual(ref.key, "111/c_abc123@group.calendar.google.com")
        XCTAssertEqual(CalendarRef(key: ref.key), ref)
        XCTAssertNil(CalendarRef(key: "no-slash"))
        XCTAssertNil(CalendarRef(key: "/calendar"))
        XCTAssertNil(CalendarRef(key: "account/"))
    }
}
