import XCTest

/// "Remove account": its calendars leave the Focus filter, where new events go next, and how many of its changes
/// would be lost (the confirmation's count).
final class AccountRemovalTests: XCTestCase {
    private let files = TemporaryStoreFiles()

    override func tearDown() {
        files.removeAll()
        super.tearDown()
    }

    private let personal = SampleAccounts.account("111", email: "example@gmail.com", extra: [
        SampleAccounts.calendar("111", "gym@group.calendar.google.com", email: "example@gmail.com", name: "Gym")
    ])
    private let school = SampleAccounts.account("222", email: "example@yourmail.com")
    private var personalPrimary: CalendarRef { CalendarRef(accountID: "111", calendarID: "example@gmail.com") }
    private var gym: CalendarRef { CalendarRef(accountID: "111", calendarID: "gym@group.calendar.google.com") }
    private var schoolPrimary: CalendarRef { CalendarRef(accountID: "222", calendarID: "example@yourmail.com") }

    private func makeStore(defaultCalendar: CalendarRef? = nil) -> AccountStore {
        AccountStore(fileURL: files.url("AccountRemovalTests"), isDemoMode: { false }, defaultCalendar: { defaultCalendar })
    }

    func testRemovingAnAccountTakesItsCalendarsOutOfTheFocusFilter() async {
        let store = makeStore()
        await store.upsert(personal)
        await store.upsert(school)
        await store.setFocusFilter([gym, schoolPrimary])

        await store.remove(accountID: "111")
        let kept = await store.focusFilter()
        XCTAssertEqual(kept?.calendars, [schoolPrimary])

        // A Focus set up before the removal still names Gym when it turns on later.
        await store.setFocusFilter([gym, schoolPrimary])
        let later = await store.focusFilter()
        XCTAssertEqual(later?.calendars, [schoolPrimary])
        await store.setFocusFilter([gym])
        let onlyRemoved = await store.focusFilter()
        XCTAssertNil(onlyRemoved, "nothing left to filter by: every calendar shows")

        await store.remove(accountID: "222")
        let none = await store.focusFilter()
        XCTAssertNil(none, "no calendar left to focus on")
        let accounts = await store.accounts()
        XCTAssertTrue(accounts.isEmpty, "back to the welcome state")
    }

    func testNewEventsMoveWhenTheirCalendarLeaves() async {
        // Picked in Settings: the school account's calendar. Once the school account is gone (AccountManager also
        // resets the choice), the first account's primary calendar takes over.
        let chosen = makeStore(defaultCalendar: schoolPrimary)
        await chosen.upsert(personal)
        await chosen.upsert(school)
        let before = await chosen.defaultWriteTarget()
        XCTAssertEqual(before?.id, schoolPrimary)
        await chosen.remove(accountID: "222")
        let after = await chosen.defaultWriteTarget()
        let moved = AccountRemovalEffects.newEventsTarget(before: before, after: after, removedAccountID: "222")
        XCTAssertEqual(moved?.id, personalPrimary)
        XCTAssertEqual(moved.map(AccountRemovalEffects.label), "My calendar · example@gmail.com")
    }

    func testTheAutomaticTargetMovesToTheNextAccount() async {
        let store = makeStore()
        await store.upsert(personal)
        await store.upsert(school)
        let before = await store.defaultWriteTarget()
        XCTAssertEqual(before?.id, personalPrimary)
        await store.remove(accountID: "111")
        let after = await store.defaultWriteTarget()
        XCTAssertEqual(AccountRemovalEffects.newEventsTarget(before: before, after: after, removedAccountID: "111")?.id,
                       schoolPrimary)
    }

    func testNothingToSayWhenNewEventsStayOrNoAccountIsLeft() {
        let personalCalendar = SampleAccounts.calendar("111", "example@gmail.com", primary: true)
        let schoolCalendar = SampleAccounts.calendar("222", "example@yourmail.com", primary: true)
        // Another account's calendar was the target and still is.
        XCTAssertNil(AccountRemovalEffects.newEventsTarget(before: personalCalendar, after: personalCalendar,
                                                           removedAccountID: "222"))
        // The last account went: the welcome state says enough.
        XCTAssertNil(AccountRemovalEffects.newEventsTarget(before: schoolCalendar, after: nil, removedAccountID: "222"))
        XCTAssertNil(AccountRemovalEffects.newEventsTarget(before: nil, after: personalCalendar, removedAccountID: "222"))
    }

    // MARK: Changes that would be lost

    func testTheConfirmationCountsWaitingAndRefusedChangesOfThatAccountOnly() async {
        let outbox = SyncOutbox(fileURL: files.url("AccountRemovalTests-outbox"))
        let created = TestClock.utc(2026, 10, 14, 9, 0)
        let lunch = OutboxItem(kind: .insert, calendar: personalPrimary, eventID: "ss1", title: "Lunch", createdAt: created)
        let gymMove = OutboxItem(kind: .patch, calendar: gym, eventID: "ss2", title: "Gym", createdAt: created)
        let schoolDelete = OutboxItem(kind: .delete, calendar: schoolPrimary, eventID: "ss3", title: "Class", createdAt: created)
        for item in [lunch, gymMove, schoolDelete] { await outbox.enqueue(item) }
        await outbox.fail(id: gymMove.id, reason: "You can't change events in “Gym”.", at: created)

        let personalCount = await outbox.unsentCount(accountID: "111")
        let schoolCount = await outbox.unsentCount(accountID: "222")
        let unknownCount = await outbox.unsentCount(accountID: "333")
        XCTAssertEqual(personalCount, 2, "waiting and refused both")
        XCTAssertEqual(schoolCount, 1)
        XCTAssertEqual(unknownCount, 0)

        await outbox.removeAll(accountID: "111")
        let afterRemoval = await outbox.unsentCount(accountID: "111")
        let schoolKept = await outbox.unsentCount(accountID: "222")
        XCTAssertEqual(afterRemoval, 0)
        XCTAssertEqual(schoolKept, 1)
    }
}
