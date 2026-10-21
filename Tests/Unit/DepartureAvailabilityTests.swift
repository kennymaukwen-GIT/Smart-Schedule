import XCTest

/// Where 「該出發了」 is offered (the iPhone's region and time zone; the App Store country is not read, owner decision
/// 2026-10-21), and the user's answer to 「使用 Google 地圖規劃出發時間？」 (docs/SETTINGS.md §7.11,
/// owner decisions 2026-10-20). The server's own list is checked against this one in
/// server/worker/test/config-sync.test.ts.
final class DepartureAvailabilityTests: XCTestCase {
    // MARK: The lists

    func testTheBlockedCountriesAreTheEEASwitzerlandAndTheUK() {
        XCTAssertEqual(DepartureRegion.blockedCountries.count, 43)
        for country in ["GB", "CH", "NO", "IS", "LI", "FR", "DE", "IE", "CY", "GG", "JE", "IM", "GI", "AX", "RE", "MF"] {
            XCTAssertTrue(DepartureRegion.blockedCountries.contains(country), country)
        }
        for country in ["TW", "US", "JP", "TR", "RS", "UA", "MC", "AD", "SM", "VA", "FO", "SJ"] {
            XCTAssertFalse(DepartureRegion.blockedCountries.contains(country), country)
        }
    }

    func testEveryTimeZoneIsABlockedCountryAndEveryCountryHasOne() {
        XCTAssertEqual(Set(DepartureRegion.timeZones.values), DepartureRegion.blockedCountries)
        // Every name is one iOS knows (old aliases such as Eire and GB included), so none is misspelt.
        for identifier in DepartureRegion.timeZones.keys {
            XCTAssertNotNil(TimeZone(identifier: identifier), identifier)
        }
        // Each country's main zone, so deleting one fails even where an alias still covers the country.
        let main = ["AT": "Europe/Vienna", "BE": "Europe/Brussels", "BG": "Europe/Sofia", "HR": "Europe/Zagreb",
                    "CY": "Asia/Nicosia", "CZ": "Europe/Prague", "DK": "Europe/Copenhagen", "EE": "Europe/Tallinn",
                    "FI": "Europe/Helsinki", "FR": "Europe/Paris", "DE": "Europe/Berlin", "GR": "Europe/Athens",
                    "HU": "Europe/Budapest", "IE": "Europe/Dublin", "IT": "Europe/Rome", "LV": "Europe/Riga",
                    "LT": "Europe/Vilnius", "LU": "Europe/Luxembourg", "MT": "Europe/Malta", "NL": "Europe/Amsterdam",
                    "PL": "Europe/Warsaw", "PT": "Europe/Lisbon", "RO": "Europe/Bucharest", "SK": "Europe/Bratislava",
                    "SI": "Europe/Ljubljana", "ES": "Europe/Madrid", "SE": "Europe/Stockholm",
                    "IS": "Atlantic/Reykjavik", "LI": "Europe/Vaduz", "NO": "Europe/Oslo", "CH": "Europe/Zurich",
                    "GB": "Europe/London", "GG": "Europe/Guernsey", "JE": "Europe/Jersey", "IM": "Europe/Isle_of_Man",
                    "GI": "Europe/Gibraltar", "AX": "Europe/Mariehamn", "GF": "America/Cayenne",
                    "GP": "America/Guadeloupe", "MQ": "America/Martinique", "RE": "Indian/Reunion",
                    "YT": "Indian/Mayotte", "MF": "America/Marigot"]
        XCTAssertEqual(Set(main.keys), DepartureRegion.blockedCountries)
        for (country, zone) in main {
            XCTAssertEqual(DepartureRegion.timeZones[zone], country, zone)
        }
        // Spain's and Portugal's islands and Cyprus' north count too.
        for zone in ["Atlantic/Canary", "Africa/Ceuta", "Atlantic/Madeira", "Atlantic/Azores", "Asia/Famagusta"] {
            XCTAssertNotNil(DepartureRegion.timeZones[zone], zone)
        }
    }

    // MARK: Each signal

    func testTheIPhonesRegion() {
        XCTAssertTrue(DepartureRegion.isBlocked(region: "GB"))
        XCTAssertTrue(DepartureRegion.isBlocked(region: "gb"))
        XCTAssertTrue(DepartureRegion.isBlocked(region: "DE"))
        XCTAssertTrue(DepartureRegion.isBlocked(region: "150"), "a region set to Europe")
        XCTAssertTrue(DepartureRegion.isBlocked(region: "155"), "Western Europe")
        XCTAssertFalse(DepartureRegion.isBlocked(region: "TW"))
        XCTAssertFalse(DepartureRegion.isBlocked(region: "US"))
        XCTAssertFalse(DepartureRegion.isBlocked(region: "419"), "Latin America")
        XCTAssertFalse(DepartureRegion.isBlocked(region: ""))
        XCTAssertFalse(DepartureRegion.isBlocked(region: nil))
    }

    func testTheTimeZoneStandsForWhereTheIPhoneIs() {
        XCTAssertTrue(DepartureRegion.isBlocked(timeZone: "Europe/London"))
        XCTAssertTrue(DepartureRegion.isBlocked(timeZone: "Atlantic/Canary"))
        XCTAssertFalse(DepartureRegion.isBlocked(timeZone: "Asia/Taipei"))
        XCTAssertFalse(DepartureRegion.isBlocked(timeZone: "Europe/Istanbul"), "Turkey is outside the area")
        XCTAssertFalse(DepartureRegion.isBlocked(timeZone: "Europe/Belgrade"))
        XCTAssertFalse(DepartureRegion.isBlocked(timeZone: "Europe/Monaco"))
        XCTAssertFalse(DepartureRegion.isBlocked(timeZone: nil))
    }

    // MARK: The decision

    private func resolve(region: String? = "TW", timeZone: String? = "Asia/Taipei",
                         consent: DepartureConsent = .notAsked, debugBuild: Bool = false,
                         debugAllowsBlocked: Bool = false) -> DepartureAvailability {
        DepartureAvailability.resolve(region: region, timeZone: timeZone, consent: consent,
                                      debugBuild: debugBuild, debugAllowsBlocked: debugAllowsBlocked)
    }

    func testTaiwanIsOnBeforeAndAfterAllowing() {
        XCTAssertEqual(resolve(), .on, "not asked yet: the app asks before the first request goes out")
        XCTAssertEqual(resolve(consent: .allowed), .on)
        XCTAssertEqual(resolve(region: nil, timeZone: nil), .on, "nothing says it is in the area")
    }

    func testNotNowTurnsItOff() {
        XCTAssertEqual(resolve(consent: .declined), .off)
        XCTAssertEqual(resolve(region: "GB", consent: .declined, debugBuild: true, debugAllowsBlocked: true), .off)
    }

    func testAnyOneSignalInTheAreaTurnsItOff() {
        XCTAssertEqual(resolve(region: "GB"), .off)
        XCTAssertEqual(resolve(timeZone: "Europe/London"), .off, "a Taiwanese iPhone in London")
        XCTAssertEqual(resolve(region: "150"), .off)
    }

    /// Owner decision 2026-10-20: only Debug builds installed from Xcode have 「測試用：允許在英國使用」, and then only
    /// with a starting point said in the sentence.
    func testTheDebugSwitchAllowsATypedStartOnlyInDebugBuilds() {
        XCTAssertEqual(resolve(region: "GB", timeZone: "Europe/London", debugBuild: true, debugAllowsBlocked: true),
                       .typedStartOnly)
        XCTAssertEqual(resolve(region: "GB", debugBuild: false, debugAllowsBlocked: true), .off, "Release ignores it")
        XCTAssertEqual(resolve(region: "GB", debugBuild: true, debugAllowsBlocked: false), .off)
        XCTAssertEqual(resolve(debugBuild: true, debugAllowsBlocked: true), .on, "outside the area it changes nothing")
    }

    // MARK: The answer is kept

    func testTheAnswerIsKeptAndStartsAsNotAsked() throws {
        let suite = "DepartureAvailabilityTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = DepartureConsentStore(suiteName: suite)
        XCTAssertEqual(store.read(), .notAsked)
        store.write(.declined)
        XCTAssertEqual(store.read(), .declined)
        XCTAssertEqual(DepartureConsentStore(suiteName: suite).read(), .declined, "a new store reads the same answer")
        store.write(.allowed)
        XCTAssertEqual(store.read(), .allowed)
        try XCTUnwrap(UserDefaults(suiteName: suite)).set("maybe", forKey: DepartureConsentStore.key)
        XCTAssertEqual(store.read(), .notAsked, "an unknown value asks again")
    }
}
