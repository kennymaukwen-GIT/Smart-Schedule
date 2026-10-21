import Foundation

/// What the assistant says about a departure (docs/SETTINGS.md §7.11). The owner's format (2026-10-20):
/// 「根據你 16:30 到台北 101 的需求，建議 15:48 出門。」 Only the time to leave, not the route: the route is seen in
/// Google Maps. English keys in Localizable.xcstrings, zh-Hant translations there (LocalizationCatalogTests checks them).
///
/// Two versions of each answer:
/// - `shown`: what the chat shows now, with Google's times. In memory only.
/// - `kept`: what chat history, the export and the Live Activity keep. No time from Google (its terms allow no
///   storing of it): only the place and the time the user wants to be there.
enum DepartureLines {
    /// Google's attribution, shown with every time from Google (Maps Platform terms §3.2.2(b)): in Latin script, never
    /// translated or changed.
    static let attribution = "Google Maps"

    // MARK: Answers

    /// - Parameters:
    ///   - place: the destination as the user or the event wrote it.
    ///   - target: when the user wants to be there; nil for "how long".
    ///   - mode: the way of travelling the time is for.
    ///   - fellBack: no public-transport route was found, so this is by car.
    static func shown(_ outcome: DepartureTurn.Outcome, place: String, target: Date?, mode: TravelMode,
                      fellBack: Bool, clock: WallClock) -> String {
        let spot = inSentence(place)
        let how = modeName(mode)
        var line: String
        switch outcome {
        case let .leave(at, _, estimate):
            let by = time(target ?? at, clock)
            line = String(localized: "Based on being at \(spot) by \(by), leave at \(time(at, clock)) (\(how)).")
            if estimate { line = joined(line, String(localized: "This is an estimate.")) }
        case let .late(arriveAt, minutes):
            let by = time(target ?? arriveAt, clock)
            line = String(localized: "Based on being at \(spot) by \(by), leave now (\(how)): you'll arrive at \(time(arriveAt, clock)), about \(minutes) min late.")
        case let .trip(minutes, arriveAt, estimate):
            line = String(localized: "Leaving now for \(spot) takes about \(duration(minutes: minutes)) (\(how)): you'll arrive at \(time(arriveAt, clock)).")
            if estimate { line = joined(line, String(localized: "This is an estimate.")) }
        }
        if fellBack { line = joined(line, String(localized: "No public transport route was found, so this is by car.")) }
        return line
    }

    /// The same answer without any time from Google.
    static func kept(_ outcome: DepartureTurn.Outcome, place: String, target: Date?, clock: WallClock) -> String {
        let spot = inSentence(place)
        switch outcome {
        case .leave, .late:
            guard let target else { return String(localized: "Planned when to leave for \(spot).") }
            return String(localized: "Planned when to leave for \(spot) (be there by \(time(target, clock))).")
        case .trip:
            return String(localized: "Checked the travel time to \(spot).")
        }
    }

    /// How many new plans are left this week (two on the free plan).
    static func plansLeft(_ count: Int) -> String {
        count > 0 ? String(localized: "You can plan \(count) more this week.") : String(localized: "That was this week's last plan.")
    }

    // MARK: Added to an answer

    static var whenAdded: String { String(localized: "Departure reminders are set when you tap Add.") }
    static var tooLongForReminders: String { String(localized: "This trip is too long to set departure reminders.") }
    static var notSet: String { String(localized: "No departure reminders were set.") }

    // MARK: When there is no answer

    enum Reason: Equatable, Sendable {
        /// The time to be there has already passed (owner decision 2026-10-21).
        case passed
        case allDay
        /// An event without a place (owner decision 1A).
        case noPlace
        /// Google didn't find the destination; `forEvent` when it is an event's place.
        case destinationNotFound(forEvent: Bool)
        case startNotFound
        case noRoute(TravelMode)
        case noPermission
        case noLocation
        /// Debug builds where the feature is otherwise off, with no starting point in the sentence.
        case needsTypedStart
        case region
        case weeklyLimit
        case dailyCapacity
        case userDailyLimit
        case busy
        case unavailable
    }

    static func reason(_ error: DepartureRouteError) -> Reason {
        switch error {
        case .regionUnavailable: .region
        case .weeklyLimit: .weeklyLimit
        case .dailyCapacity: .dailyCapacity
        case .userDailyLimit: .userDailyLimit
        case .busy: .busy
        case .recheckLimit, .invalidPlan, .unavailable, .notReady, .unverified, .invalidRequest: .unavailable
        }
    }

    static func reason(_ error: TravelTimeError) -> Reason {
        switch error {
        case .noPermission: .noPermission
        case .temporarilyUnavailable: .noLocation
        }
    }

    static func failure(_ reason: Reason) -> String {
        switch reason {
        case .passed: String(localized: "That time has already passed, so there's no departure to plan.")
        case .allDay: String(localized: "An all-day event has no start time to plan a departure for.")
        case .noPlace: String(localized: "This event has no place yet. Add one to the event first.")
        case .destinationNotFound(forEvent: true):
            String(localized: "Couldn't find this event's place. Change it to a name or address in the event.")
        case .destinationNotFound(forEvent: false):
            String(localized: "Couldn't find that place. Try its full name or address.")
        case .startNotFound: String(localized: "Couldn't find where you're leaving from. Try its full name or address.")
        case let .noRoute(mode): String(localized: "No route there \(modeName(mode)).")
        case .noPermission:
            String(localized: "Allow Location for Smart Schedules in Settings, or say where you're leaving from.")
        case .noLocation:
            String(localized: "Couldn't get your location. Try again, or say where you're leaving from.")
        case .needsTypedStart: String(localized: "Test mode: say where you're leaving from.")
        case .region: String(localized: "Departure planning isn't available here.")
        case .weeklyLimit: String(localized: "This week's departure plans are used up. They come back on Monday.")
        case .dailyCapacity: String(localized: "Today's route planning is used up. Try again tomorrow.")
        case .userDailyLimit: String(localized: "You've planned a lot today. Try again tomorrow.")
        case .busy: String(localized: "Departure planning is busy. Try again in a moment.")
        case .unavailable: String(localized: "Can't plan the departure right now. Try again later.")
        }
    }

    // MARK: Pieces

    /// "by public transport" / 「大眾運輸」.
    static func modeName(_ mode: TravelMode) -> String {
        switch mode {
        case .transit: String(localized: "by public transport")
        case .driving: String(localized: "by car")
        case .walking: String(localized: "on foot")
        case .scooter: String(localized: "by scooter")
        }
    }

    /// "25 min", "1 hr", "2 hr 5 min" / 「25 分鐘」「1 小時」「2 小時 5 分鐘」.
    static func duration(minutes: Int) -> String {
        let minutes = max(minutes, 0)
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return String(localized: "\(rest) min") }
        if rest == 0 { return String(localized: "\(hours) hr") }
        return String(localized: "\(hours) hr \(rest) min")
    }

    /// "15:48": 24-hour in the clock's time zone.
    static func time(_ date: Date, _ clock: WallClock) -> String {
        ReplyFormatter.clockTime(date, clock: clock)
    }

    /// A place inside a Chinese sentence gets a space next to Latin letters or digits at its ends (「到台北 101 的需求」,
    /// 「到 Dishoom 的需求」); in English it stays as it is.
    static func inSentence(_ place: String, chinese: Bool = ReplyFormatter.isChinese(ReplyFormatter.displayLocale)) -> String {
        guard chinese, let first = place.unicodeScalars.first, let last = place.unicodeScalars.last else { return place }
        func isLatin(_ scalar: Unicode.Scalar) -> Bool { scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) }
        return (isLatin(first) ? " " : "") + place + (isLatin(last) ? " " : "")
    }

    /// Two sentences: a space between them in English, none in Chinese.
    static func joined(_ first: String, _ second: String,
                       chinese: Bool = ReplyFormatter.isChinese(ReplyFormatter.displayLocale)) -> String {
        first + (chinese ? "" : " ") + second
    }
}
