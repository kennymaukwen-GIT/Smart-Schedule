import Foundation

// Where 「該出發了」 is offered (docs/SETTINGS.md §7.11, owner decisions 2026-10-20). Google's Maps Platform terms
// (§4.4(c)(ii)) keep it out of the area they call "European": the EEA, Switzerland and the UK. The server refuses
// requests from there by IP address (server/worker/src/departure.ts EUROPEAN_COUNTRIES); the app turns the feature off
// before Gemini is asked when the iPhone's region, its App Store country or its time zone says it is there. The time
// zone stands for where the iPhone is, so no location is read or sent to find the country.
//
// Pure: the app reads the three values and the user's choice and passes them in.

/// The countries, App Store storefronts and time zones where the feature is off.
enum DepartureRegion {
    /// ISO 3166-1 alpha-2 codes: the server's EUROPEAN_COUNTRIES exactly (server/worker/test/config-sync.test.ts keeps
    /// the two lists equal). The 27 EU countries, Iceland, Liechtenstein, Norway, Switzerland and the UK, and the
    /// codes a network may report inside them (Guernsey, Jersey, the Isle of Man, Gibraltar, Åland and the French
    /// overseas regions).
    static let blockedCountries: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU",
        "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
        "IS", "LI", "NO", "CH", "GB",
        "GG", "JE", "IM", "GI", "AX", "GF", "GP", "MQ", "RE", "YT", "MF",
    ]

    /// The same countries as App Store storefront codes (StoreKit's `Storefront.countryCode`, ISO 3166-1 alpha-3).
    static let storefronts: [String: String] = [
        "AUT": "AT", "BEL": "BE", "BGR": "BG", "HRV": "HR", "CYP": "CY", "CZE": "CZ", "DNK": "DK", "EST": "EE",
        "FIN": "FI", "FRA": "FR", "DEU": "DE", "GRC": "GR", "HUN": "HU", "IRL": "IE", "ITA": "IT", "LVA": "LV",
        "LTU": "LT", "LUX": "LU", "MLT": "MT", "NLD": "NL", "POL": "PL", "PRT": "PT", "ROU": "RO", "SVK": "SK",
        "SVN": "SI", "ESP": "ES", "SWE": "SE",
        "ISL": "IS", "LIE": "LI", "NOR": "NO", "CHE": "CH", "GBR": "GB",
        "GGY": "GG", "JEY": "JE", "IMN": "IM", "GIB": "GI", "ALA": "AX", "GUF": "GF", "GLP": "GP", "MTQ": "MQ",
        "REU": "RE", "MYT": "YT", "MAF": "MF",
    ]

    /// UN M.49 codes an iPhone's region can be instead of a country: Europe and its four parts. They cover more than
    /// the area above, but a region set to "Europe" can't tell which country it is.
    static let europeanRegionCodes: Set<String> = ["150", "039", "151", "154", "155"]

    /// The IANA time zones of the countries above (current names and the old aliases iOS still accepts), and the
    /// country each one is in. Zones elsewhere in Europe (Europe/Istanbul, Europe/Belgrade, Europe/Monaco, …) are not
    /// in it: those countries are outside the area.
    static let timeZones: [String: String] = [
        "Europe/Vienna": "AT", "Europe/Brussels": "BE", "Europe/Sofia": "BG", "Europe/Zagreb": "HR",
        "Asia/Nicosia": "CY", "Asia/Famagusta": "CY", "Europe/Nicosia": "CY", "Europe/Prague": "CZ",
        "Europe/Copenhagen": "DK", "Europe/Tallinn": "EE", "Europe/Helsinki": "FI", "Europe/Paris": "FR",
        "Europe/Berlin": "DE", "Europe/Busingen": "DE", "Europe/Athens": "GR", "Europe/Budapest": "HU",
        "Europe/Dublin": "IE", "Eire": "IE", "Europe/Rome": "IT", "Europe/Riga": "LV", "Europe/Vilnius": "LT",
        "Europe/Luxembourg": "LU", "Europe/Malta": "MT", "Europe/Amsterdam": "NL", "Europe/Warsaw": "PL",
        "Poland": "PL", "Europe/Lisbon": "PT", "Atlantic/Madeira": "PT", "Atlantic/Azores": "PT", "Portugal": "PT",
        "Europe/Bucharest": "RO", "Europe/Bratislava": "SK", "Europe/Ljubljana": "SI", "Europe/Madrid": "ES",
        "Africa/Ceuta": "ES", "Atlantic/Canary": "ES", "Europe/Stockholm": "SE",
        "Atlantic/Reykjavik": "IS", "Iceland": "IS", "Europe/Vaduz": "LI", "Europe/Oslo": "NO",
        "Europe/Zurich": "CH", "Europe/London": "GB", "Europe/Belfast": "GB", "GB": "GB", "GB-Eire": "GB",
        "Europe/Guernsey": "GG", "Europe/Jersey": "JE", "Europe/Isle_of_Man": "IM", "Europe/Gibraltar": "GI",
        "Europe/Mariehamn": "AX", "America/Cayenne": "GF", "America/Guadeloupe": "GP", "America/Martinique": "MQ",
        "Indian/Reunion": "RE", "Indian/Mayotte": "YT", "America/Marigot": "MF",
    ]

    /// The iPhone's region (`Locale.Region` identifier: "TW", "GB", or an M.49 code such as "150") is in the area.
    /// nil, unknown codes and other regions are not.
    static func isBlocked(region: String?) -> Bool {
        guard let code = region?.trimmingCharacters(in: .whitespaces).uppercased(), !code.isEmpty else { return false }
        return blockedCountries.contains(code) || europeanRegionCodes.contains(code)
    }

    /// The App Store country (alpha-3: "TWN", "GBR") is in the area. nil (not signed in, or not read yet) is not.
    static func isBlocked(storefront: String?) -> Bool {
        guard let code = storefront?.trimmingCharacters(in: .whitespaces).uppercased() else { return false }
        return storefronts[code] != nil
    }

    /// The iPhone's time zone ("Europe/London") is in the area.
    static func isBlocked(timeZone: String?) -> Bool {
        guard let identifier = timeZone else { return false }
        return timeZones[identifier] != nil
    }
}

/// Whether the iPhone may plan departures, decided once per request before Gemini is asked (owner decision 3A: when
/// it is off, Gemini gets neither prompt rule 13 nor `plan_departure`).
enum DepartureAvailability: Equatable, Sendable {
    /// Not offered: the assistant behaves exactly as without the feature.
    case off
    case on
    /// Debug builds installed from Xcode only, where the feature would otherwise be off: the owner's switch
    /// 「測試用：允許在英國使用」 lets a starting point said in the sentence be used, never the current location.
    case typedStartOnly

    /// - Parameters:
    ///   - region: the iPhone's region (`Locale.current.region?.identifier`).
    ///   - storefront: the App Store country (`Storefront.current?.countryCode`), nil when not read.
    ///   - timeZone: the iPhone's time zone identifier (`TimeZone.current.identifier`).
    ///   - consent: the user's answer to 「使用 Google 地圖規劃出發時間？」; Not now turns the feature off.
    ///   - debugBuild: true only in Debug builds (`#if DEBUG`); `debugAllowsBlocked` is ignored otherwise.
    static func resolve(region: String?, storefront: String?, timeZone: String?, consent: DepartureConsent,
                        debugBuild: Bool, debugAllowsBlocked: Bool) -> DepartureAvailability {
        guard consent != .declined else { return .off }
        let blocked = DepartureRegion.isBlocked(region: region) || DepartureRegion.isBlocked(storefront: storefront)
            || DepartureRegion.isBlocked(timeZone: timeZone)
        guard blocked else { return .on }
        return debugBuild && debugAllowsBlocked ? .typedStartOnly : .off
    }
}
