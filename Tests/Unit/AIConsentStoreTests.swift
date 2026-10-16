import XCTest

/// AI data-sharing consent: the decision, its versioning, and the disclosure wording.
final class AIConsentStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // A hostless test bundle has no App Group: a throwaway suite stands in for it.
        suiteName = "AIConsentStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testNotAskedUntilTheUserDecides() {
        let consent = AIConsentStore.current(in: defaults)
        XCTAssertEqual(consent.status, .notAsked)
        XCTAssertFalse(consent.isGranted)
        XCTAssertNil(consent.decidedAt)
    }

    func testGrantDeclineRevokeReset() {
        let when = TestClock.utc(2026, 10, 13, 9, 0)
        AIConsentStore.record(.granted, in: defaults, now: when)
        var consent = AIConsentStore.current(in: defaults)
        XCTAssertTrue(consent.isGranted)
        XCTAssertEqual(consent.version, AIConsent.disclosureVersion)
        XCTAssertEqual(consent.decidedAt, when)

        AIConsentStore.record(.revoked, in: defaults)
        consent = AIConsentStore.current(in: defaults)
        XCTAssertEqual(consent.status, .revoked)
        XCTAssertFalse(consent.isGranted)

        AIConsentStore.record(.declined, in: defaults)
        XCTAssertEqual(AIConsentStore.current(in: defaults).status, .declined)
        XCTAssertFalse(AIConsentStore.current(in: defaults).isGranted)

        AIConsentStore.record(.granted, in: defaults)
        AIConsentStore.reset(in: defaults)
        XCTAssertEqual(AIConsentStore.current(in: defaults), AIConsent())
    }

    func testConsentToAnOlderDisclosureAsksAgain() {
        XCTAssertFalse(AIConsent(status: .granted, version: AIConsent.disclosureVersion - 1).isGranted)
        XCTAssertTrue(AIConsent(status: .granted, version: AIConsent.disclosureVersion).isGranted)
        XCTAssertFalse(AIConsent(status: .declined, version: AIConsent.disclosureVersion).isGranted)
    }

    func testUnreadableValuesReadAsNotAsked() {
        defaults.set(Data("not json".utf8), forKey: AIConsentStore.defaultsKey)
        XCTAssertEqual(AIConsentStore.current(in: defaults).status, .notAsked)

        // A status a newer build wrote: asked again rather than trusted.
        defaults.set(Data(#"{"status": "grantedForever", "version": 9}"#.utf8), forKey: AIConsentStore.defaultsKey)
        let consent = AIConsentStore.current(in: defaults)
        XCTAssertEqual(consent.status, .notAsked)
        XCTAssertFalse(consent.isGranted)
    }

    func testMissingStoreIsNotGranted() {
        XCTAssertFalse(AIConsentStore.current(in: nil).isGranted)
    }

    func testDisclosureSaysWhatIsSentAndToWhom() throws {
        XCTAssertEqual(AIConsentDisclosure.title, "Use the AI assistant?")
        XCTAssertEqual(AIConsent.disclosureVersion, 5, "everyone is asked again for the new disclosure")
        let items = AIConsentDisclosure.items
        XCTAssertEqual(items.count, 5)
        // What the user types or says, with whatever names and addresses they mention themselves.
        XCTAssertTrue(items[0].contains("type or say"), items[0])
        XCTAssertTrue(items[0].contains("spoken requests as text"), items[0])
        XCTAssertTrue(items[0].contains("email addresses you mention"), items[0])
        // UPCOMING and FOCUS: the 14-day / 40-event window with Google event IDs, and no places.
        XCTAssertTrue(items[1].contains("Google event IDs"), items[1])
        XCTAssertTrue(items[1].contains("up to 40 events"), items[1])
        XCTAssertTrue(items[1].contains("14 days"), items[1])
        XCTAssertTrue(items[1].contains("reminder you reply to"), items[1])
        XCTAssertFalse(items[1].contains("location"), items[1])
        // Only "AI suggestions" sends a place, for one event.
        XCTAssertTrue(items[2].contains("AI suggestions"), items[2])
        XCTAssertTrue(items[2].contains("location"), items[2])
        // Calendars are "Account 1", "Account 2" (CalendarAliases): no account email.
        XCTAssertTrue(items[3].contains("calendar names and assistant settings"), items[3])
        XCTAssertTrue(items[3].contains("not your Google account email addresses"), items[3])
        XCTAssertTrue(items[4].contains("time zone and language"), items[4])
        XCTAssertTrue(AIConsentDisclosure.lead.contains("Gemini API"))
        XCTAssertTrue(AIConsentDisclosure.recipient.contains("Google"))

        // The iOS 18 server note follows AppConstants.pushToStartEnabled: version 1.0 has no push-to-start, keeps
        // nothing about events on the server and says nothing about it, on any iOS.
        XCTAssertEqual(AIConsentDisclosure.serverNote(beforeIOS26: true) != nil, AppConstants.pushToStartEnabled)
        XCTAssertNil(AIConsentDisclosure.serverNote(beforeIOS26: true, pushToStart: false))
        XCTAssertNil(AIConsentDisclosure.serverNote(beforeIOS26: false))

        // Kept for a later version with push-to-start, iOS 18 only: event titles, times and IDs kept on the server and
        // sent through APNs; never notes or places.
        let note = try XCTUnwrap(AIConsentDisclosure.serverNote(beforeIOS26: true, pushToStart: true))
        for part in ["iOS 18", "next 48 hours", "event IDs", "server", "Apple's push service", "Notes and places are not stored"] {
            XCTAssertTrue(note.contains(part), "\(part) missing from: \(note)")
        }
        XCTAssertNil(AIConsentDisclosure.serverNote(beforeIOS26: false, pushToStart: true), "iOS 26 schedules them itself")

        // 1.0 has no microphone: speech reaches the app only as text, from Siri or the keyboard's dictation (Apple's).
        let speech = AIConsentDisclosure.speechNote
        for part in ["Siri", "keyboard's dictation", "Apple", "only receives the text"] {
            XCTAssertTrue(speech.contains(part), "\(part) missing from: \(speech)")
        }

        XCTAssertTrue(AIConsentDisclosure.footnote.contains("Nothing is sent to the AI until you tap Allow"))
        XCTAssertTrue(AIConsentDisclosure.footnote.contains("Demo mode"))
        // Only Gemini's paid tier keeps prompts out of training: the app must never promise it.
        let all = ([AIConsentDisclosure.title, AIConsentDisclosure.lead, AIConsentDisclosure.recipient,
                    AIConsentDisclosure.footnote, AIConsentDisclosure.speechNote, note] + items)
            .joined(separator: " ").lowercased()
        XCTAssertFalse(all.contains("train"), all)
        // No setting or button of the app's own is named: Settings › Assistant has no On-device recognition any more.
        XCTAssertFalse(all.contains("on-device recognition"), all)
        XCTAssertFalse(all.contains("microphone"), all)
    }
}
