import XCTest

/// How the assistant's model names calendars and accounts (`CalendarAliases`): "<name> | Account N", never an email
/// address, and every label maps back to exactly one calendar.
final class CalendarAliasesTests: XCTestCase {
    // Account 1 (personal): primary, Gym, read-only Holidays, a calendar someone shared (named with their address).
    // Account 2 (school): primary and a Gym of its own.
    private let personal = SampleAccounts.calendar("acct-a", "kenny@example.com", email: "kenny@example.com", primary: true)
    private let gym = SampleAccounts.calendar("acct-a", "gym-id", email: "kenny@example.com", name: "Gym", role: "writer")
    private let holidays = SampleAccounts.calendar("acct-a", "holidays-id", email: "kenny@example.com", name: "Holidays",
                                                   role: "reader")
    private let boss = SampleAccounts.calendar("acct-a", "boss-id", email: "kenny@example.com",
                                               name: "example.boss@example.org", role: "writer")
    private let school = SampleAccounts.calendar("acct-b", "example@yourmail.com", email: "example@yourmail.com", primary: true)
    private let schoolGym = SampleAccounts.calendar("acct-b", "school-gym", email: "example@yourmail.com", name: "Gym")
    private var calendars: [CalendarInfo] { [personal, gym, holidays, boss, school, schoolGym] }

    func testLabelsNameTheAccountByNumber() {
        let aliases = CalendarAliases(calendars: calendars)
        XCTAssertTrue(aliases.namesAccounts)
        XCTAssertEqual(calendars.map { aliases.label(of: $0) },
                       ["My calendar | Account 1", "Gym | Account 1", "Holidays | Account 1", "Shared calendar | Account 1",
                        "My calendar | Account 2", "Gym | Account 2"])
        XCTAssertEqual(aliases.flagName(of: school, qualified: true), "My calendar (Account 2)")
        XCTAssertEqual(aliases.flagName(of: school, qualified: false), "My calendar")
        XCTAssertEqual(aliases.name(of: boss), "Shared calendar")
        for calendar in calendars {
            XCTAssertFalse(aliases.label(of: calendar).contains("@"), aliases.label(of: calendar))
        }
    }

    func testOneAccountHasNoNumbers() {
        let aliases = CalendarAliases(calendars: [personal, gym, holidays])
        XCTAssertFalse(aliases.namesAccounts)
        XCTAssertEqual([personal, gym, holidays].map { aliases.label(of: $0) }, ["My calendar", "Gym", "Holidays"])
        XCTAssertEqual(aliases.flagName(of: gym, qualified: true), "Gym")
        XCTAssertEqual(aliases.writableCalendar(matching: "Gym")?.id, gym.id)
        XCTAssertEqual(aliases.writableCalendar(matching: "my calendar")?.id, personal.id)
        XCTAssertEqual(aliases.writableCalendar(matching: "[account email]")?.id, personal.id)
    }

    func testAccountNumbersFollowFirstAppearanceNotIDs() {
        // "acct-z" was added first: it is Account 1 although its id sorts last.
        let first = SampleAccounts.calendar("acct-z", "example.z@example.com", email: "example.z@example.com", primary: true)
        let second = SampleAccounts.calendar("acct-a", "example.a@example.com", email: "example.a@example.com", primary: true)
        let aliases = CalendarAliases(calendars: [first, second])
        XCTAssertEqual(aliases.label(of: first), "My calendar | Account 1")
        XCTAssertEqual(aliases.label(of: second), "My calendar | Account 2")
    }

    func testAddressNamedAndSameNamedCalendars() {
        let other = SampleAccounts.calendar("acct-a", "peer-id", email: "kenny@example.com", name: "example.peer@example.org",
                                            role: "reader")
        let team = SampleAccounts.calendar("acct-a", "team-1", email: "kenny@example.com", name: "Team")
        let team2 = SampleAccounts.calendar("acct-a", "team-2", email: "kenny@example.com", name: "team")
        let untitled = SampleAccounts.calendar("acct-a", "abc123@group.calendar.google.com", email: "kenny@example.com")
        let named = SampleAccounts.calendar("acct-a", "auto-id", email: "kenny@example.com", name: "Automatic")
        let hostile = SampleAccounts.calendar("acct-a", "w-id", email: "kenny@example.com", name: "Work, x | y\nnext")
        let aliases = CalendarAliases(calendars: [personal, boss, other, team, team2, untitled, named, hostile])
        XCTAssertFalse(aliases.namesAccounts)
        XCTAssertEqual(aliases.name(of: boss), "Shared calendar 1")
        XCTAssertEqual(aliases.name(of: other), "Shared calendar 2")
        XCTAssertEqual(aliases.name(of: untitled), "Shared calendar 3")
        XCTAssertEqual(aliases.name(of: team), "Team")
        XCTAssertEqual(aliases.name(of: team2), "team (2)")
        // "automatic" is default_calendar's own value.
        XCTAssertEqual(aliases.name(of: named), "Automatic (2)")
        XCTAssertEqual(aliases.name(of: hostile), "Work x y next")
    }

    func testTwoBuildsFromTheSameCalendarsAgree() {
        let first = CalendarAliases(calendars: calendars)
        let second = CalendarAliases(calendars: calendars)
        XCTAssertEqual(calendars.map { first.label(of: $0) }, calendars.map { second.label(of: $0) })
    }

    // MARK: Back from the model

    func testEveryWritableLabelMapsBackToItsCalendar() {
        let aliases = CalendarAliases(calendars: calendars)
        for calendar in calendars where calendar.isWritable {
            let label = aliases.label(of: calendar)
            XCTAssertEqual(aliases.writableCalendar(matching: label)?.id, calendar.id, label)
            XCTAssertEqual(aliases.writableCalendar(matching: "- \(label) (default)")?.id, calendar.id, label)
            XCTAssertEqual(aliases.writableCalendar(matching: label.uppercased())?.id, calendar.id, label)
            XCTAssertEqual(aliases.writableCalendar(matching: aliases.flagName(of: calendar, qualified: true))?.id,
                           calendar.id, label)
        }
    }

    func testAccountsAndPrimaryCalendarsByOtherNames() {
        let aliases = CalendarAliases(calendars: calendars)
        XCTAssertEqual(aliases.writableCalendar(matching: "Account 2")?.id, school.id)
        XCTAssertEqual(aliases.writableCalendar(matching: "account2")?.id, school.id)
        XCTAssertEqual(aliases.writableCalendar(matching: "Primary calendar | Account 1")?.id, personal.id)
        XCTAssertEqual(aliases.writableCalendar(matching: "我的行事曆 | Account 2")?.id, school.id)
        XCTAssertEqual(aliases.writableCalendar(matching: "\"My calendar (Account 2)\"")?.id, school.id)
        XCTAssertEqual(aliases.writableCalendar(matching: "Shared calendar")?.id, boss.id, "only one calendar has that name")
        // An address the user typed reaches the model as its placeholder: that account's primary calendar.
        XCTAssertEqual(aliases.writableCalendar(matching: "[Account 2 email]")?.id, school.id)
        XCTAssertEqual(aliases.writableCalendar(matching: "'[account 1 EMAIL]'")?.id, personal.id)
    }

    func testAmbiguousStaleAndReadOnlyValuesMatchNothing() {
        let aliases = CalendarAliases(calendars: calendars)
        XCTAssertNil(aliases.writableCalendar(matching: "My calendar"), "two accounts have one")
        XCTAssertNil(aliases.writableCalendar(matching: "Gym"), "two accounts have one")
        XCTAssertNil(aliases.writableCalendar(matching: "Account 9"))
        XCTAssertNil(aliases.writableCalendar(matching: "Gym | Account 3"))
        XCTAssertNil(aliases.writableCalendar(matching: "Holidays | Account 1"), "read-only")
        XCTAssertNil(aliases.writableCalendar(matching: "  "))
        XCTAssertNil(aliases.writableCalendar(matching: "[account email]"), "two accounts")
        XCTAssertNil(aliases.writableCalendar(matching: "[Account 3 email]"))
        XCTAssertNil(aliases.writableCalendar(matching: "[email address]"))
        // The user's own words are left to AccountStore.resolveWritableCalendar; aliases are refused instead.
        XCTAssertTrue(aliases.refersToAlias("My calendar"))
        XCTAssertTrue(aliases.refersToAlias("Gym"))
        XCTAssertTrue(aliases.refersToAlias("Account 9"))
        XCTAssertTrue(aliases.refersToAlias("[Account 2 email]"))
        XCTAssertFalse(aliases.refersToAlias("my school account"))
        XCTAssertFalse(aliases.refersToAlias("example@yourmail.com"))
    }

    func testLooksLikeAlias() {
        XCTAssertTrue(CalendarAliases.looksLikeAlias("Gym | Account 3"))
        XCTAssertTrue(CalendarAliases.looksLikeAlias("ACCOUNT2"))
        XCTAssertTrue(CalendarAliases.looksLikeAlias("[account email]"))
        XCTAssertFalse(CalendarAliases.looksLikeAlias("school"))
        XCTAssertFalse(CalendarAliases.looksLikeAlias("kenny@example.com"))
        XCTAssertFalse(CalendarAliases.looksLikeAlias("my second account"))
    }

    // MARK: Addresses

    func testScrubbingReplacesOnlyTheAccountsAddresses() {
        let aliases = CalendarAliases(calendars: calendars)
        XCTAssertEqual(aliases.scrubbingAccountEmails("Ask KENNY@example.com or example.friend@example.net"),
                       "Ask [Account 1 email] or example.friend@example.net")
        XCTAssertEqual(aliases.scrubbingAccountEmails("寄給example@yourmail.com謝謝"), "寄給[Account 2 email]謝謝")
        XCTAssertEqual(aliases.redactingEmails("Google sign-in for example@yourmail.com expired; ask example.friend@example.net"),
                       "Google sign-in for [Account 2 email] expired; ask [email address]")
        XCTAssertEqual(aliases.scrubbingAccountEmails("No address here"), "No address here")
    }

    func testAddressesRunTogetherWithOtherTextAreScrubbed() {
        let aliases = CalendarAliases(calendars: calendars)
        // A quote in front, text run into it before or after: the address as stored is replaced wherever it appears.
        XCTAssertEqual(aliases.scrubbingAccountEmails("Send slides to 'example@yourmail.com'"),
                       "Send slides to '[Account 2 email]'")
        XCTAssertEqual(aliases.scrubbingAccountEmails("see...example@yourmail.com"), "see...[Account 2 email]")
        XCTAssertEqual(aliases.scrubbingAccountEmails("Email example@yourmail.com.Thanks"), "Email [Account 2 email].Thanks")
        XCTAssertEqual(aliases.scrubbingAccountEmails("SEE...EXAMPLE@YOURMAIL.COM"), "SEE...[Account 2 email]")
        XCTAssertEqual(aliases.redactingEmails("see...example@yourmail.com, see...example.friend@example.net"),
                       "see...[Account 2 email], [email address]")
        XCTAssertEqual(aliases.scrubbingAccountEmails("CC 'example.friend@example.net'"), "CC 'example.friend@example.net'")
    }

    func testAPunctuationMarkInFrontIsNotPartOfTheAddress() {
        // Only the pattern finds Gmail's other spellings, so a quote, "+" or dot in front must not join the address.
        let gmail = SampleAccounts.calendar("acct-g", "example@gmail.com", email: "example@gmail.com", primary: true)
        let aliases = CalendarAliases(calendars: [gmail])
        XCTAssertEqual(aliases.scrubbingAccountEmails("to 'Ex.Ample+work@googlemail.com'"), "to '[account email]'")
        XCTAssertEqual(aliases.scrubbingAccountEmails("+ex.ample@gmail.com"), "+[account email]")
        XCTAssertEqual(aliases.scrubbingAccountEmails("...ex.ample@gmail.com"), "...[account email]")
        XCTAssertTrue(PromptRedaction.containsEmail("'example@gmail.com'"))
        XCTAssertFalse(PromptRedaction.containsEmail("'@gmail.com"))
    }

    func testRestoringPutsTheAccountsAddressesBack() {
        let aliases = CalendarAliases(calendars: calendars)
        XCTAssertEqual(aliases.restoringAccountEmails("Squash with [Account 1 email] and [account 2 EMAIL]"),
                       "Squash with \(personal.accountEmail) and \(school.accountEmail)")
        XCTAssertEqual(aliases.restoringAccountEmails("[Account 3 email], [account email], [email address]"),
                       "[Account 3 email], [account email], [email address]",
                       "an account that is not connected; which account; not an account's address")
        let text = "1:1 with example@yourmail.com, CC example.friend@example.net"
        XCTAssertEqual(aliases.restoringAccountEmails(aliases.scrubbingAccountEmails(text)), text)

        let one = CalendarAliases(calendars: [personal, gym])
        XCTAssertEqual(one.restoringAccountEmails("Call [account email] back"), "Call \(personal.accountEmail) back")
        XCTAssertEqual(one.restoringAccountEmails("Call [Account 1 email]"), "Call \(personal.accountEmail)")
        XCTAssertEqual(one.restoringAccountEmails("Nothing [here]"), "Nothing [here]")
        XCTAssertEqual(CalendarAliases(calendars: []).restoringAccountEmails("[account email]"), "[account email]")
    }

    func testGmailSpellingsOfTheAccountAreScrubbed() {
        let gmail = SampleAccounts.calendar("acct-g", "example@gmail.com", email: "example@gmail.com", primary: true)
        let aliases = CalendarAliases(calendars: [gmail])
        XCTAssertEqual(aliases.scrubbingAccountEmails("mail Ex.Ample+work@googlemail.com now"), "mail [account email] now")
        XCTAssertEqual(aliases.scrubbingAccountEmails("EXAMPLE@gmail.com"), "[account email]")
    }

    func testScrubbedEventKeepsEverythingElse() {
        let aliases = CalendarAliases(calendars: calendars)
        var event = TestEvents.make(id: "e1", title: "1:1 with kenny@example.com", start: TestClock.local(2026, 10, 14, 9),
                                    end: TestClock.local(2026, 10, 14, 10), calendar: gym.id)
        event.location = "Room of example@yourmail.com"
        event.notes = "Agenda from kenny@example.com\nCC example.friend@example.net"
        let scrubbed = aliases.scrubbed(event)
        XCTAssertEqual(scrubbed.title, "1:1 with [Account 1 email]")
        XCTAssertEqual(scrubbed.location, "Room of [Account 2 email]")
        XCTAssertEqual(scrubbed.notes, "Agenda from [Account 1 email]\nCC example.friend@example.net")
        XCTAssertEqual(scrubbed.id, event.id)
        XCTAssertEqual(scrubbed.start, event.start)
        XCTAssertEqual(scrubbed.calendarRef, event.calendarRef)
    }

    // MARK: Preference values

    func testPromptValueOfADefaultCalendar() {
        let aliases = CalendarAliases(calendars: calendars)
        XCTAssertEqual(aliases.promptValue(canonical: "acct-b/example@yourmail.com|My calendar | example@yourmail.com",
                                           for: .defaultCalendar), "My calendar | Account 2")
        XCTAssertEqual(aliases.promptValue(canonical: "automatic", for: .defaultCalendar), "automatic")
        XCTAssertEqual(aliases.promptValue(canonical: "acct-x/gone|Gone | example.gone@example.com", for: .defaultCalendar),
                       "automatic")
        XCTAssertEqual(aliases.promptValue(canonical: "garbage", for: .defaultCalendar), "automatic")
        XCTAssertEqual(aliases.promptValue(canonical: "on 22:00-08:00", for: .quietHours), "22:00-08:00")
        XCTAssertEqual(aliases.defaultCalendarValue(holidays.id), "automatic", "read-only")
        XCTAssertEqual(aliases.defaultCalendarValue(nil), "automatic")
        XCTAssertEqual(aliases.defaultCalendarValue(boss.id), "Shared calendar | Account 1")
    }
}
