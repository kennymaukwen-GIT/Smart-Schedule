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
        XCTAssertEqual(AIConsentDisclosure.items.count, 4)
        XCTAssertTrue(AIConsentDisclosure.items[0].contains("type or say"))
        XCTAssertTrue(AIConsentDisclosure.items[0].contains("spoken requests as text"))
        // iOS 18 only: event titles and times kept on the server for the Dynamic Island; never notes or places.
        let note = try XCTUnwrap(AIConsentDisclosure.serverNote(beforeIOS26: true))
        XCTAssertTrue(note.contains("titles and start times") && note.contains("server") && note.contains("iOS 18"), note)
        XCTAssertTrue(note.contains("Notes and places are not stored"), note)
        XCTAssertNil(AIConsentDisclosure.serverNote(beforeIOS26: false))
        XCTAssertEqual(AIConsent.disclosureVersion, 2, "everyone is asked again for the new disclosure")
        XCTAssertTrue(AIConsentDisclosure.items[1].contains("Titles, times, locations and notes"))
        XCTAssertTrue(AIConsentDisclosure.items[3].contains("time zone and language"))
        XCTAssertTrue(AIConsentDisclosure.lead.contains("Gemini API"))
        XCTAssertTrue(AIConsentDisclosure.recipient.contains("Google"))
        XCTAssertTrue(AIConsentDisclosure.footnote.contains("Nothing is sent until you tap Allow"))
        XCTAssertTrue(AIConsentDisclosure.footnote.contains("Demo mode"))
        // Only Gemini's paid tier keeps prompts out of training: the app must never promise it.
        let all = ([AIConsentDisclosure.title, AIConsentDisclosure.lead, AIConsentDisclosure.recipient,
                    AIConsentDisclosure.footnote, note] + AIConsentDisclosure.items).joined(separator: " ").lowercased()
        XCTAssertFalse(all.contains("train"), all)
    }
}
