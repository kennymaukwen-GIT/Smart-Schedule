import Foundation

/// Converts between the *local wall-clock strings* Gemini emits ("2026-10-14T14:00", "2026-10-14", "07:30")
/// and absolute `Date`s in one IANA time zone.
///
/// Why wall-clock instead of RFC3339 offsets: a 6-month plan created on 2026-10-13 in Europe/London crosses
/// BST→GMT (2026-10-25) and GMT→BST (2027-03-28). Pinning "+01:00" would shift a 07:00 workout to 06:00
/// for five months. Google Calendar accepts `dateTime` without offset when `timeZone` is set, and expands
/// recurrences in that zone — so DST stays Google's problem, not ours.
struct WallClock: Sendable {
    let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 1 // Artboards use S M T W T F S
        return calendar
    }

    // MARK: Parsing

    /// Accepts `yyyy-MM-dd'T'HH:mm` or `yyyy-MM-dd'T'HH:mm:ss`. A trailing offset/"Z" is tolerated and ignored
    /// on purpose: the model is instructed to emit wall-clock time, so any offset it adds is noise.
    func dateTime(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "T", maxSplits: 1)
        guard parts.count == 2, let day = dayComponents(String(parts[0])) else { return nil }
        let timeString = String(parts[1].prefix(8)).replacingOccurrences(of: "Z", with: "")
        let hms = timeString.split(separator: ":").compactMap { Int($0.prefix(2)) }
        guard hms.count >= 2, (0...23).contains(hms[0]), (0...59).contains(hms[1]) else { return nil }
        var components = day
        components.hour = hms[0]
        components.minute = hms[1]
        components.second = hms.count > 2 ? hms[2] : 0
        // Calendar resolves a skipped DST time (e.g. 01:30 on 2027-03-28 London) to the next valid instant.
        return calendar.date(from: components)
    }

    /// `yyyy-MM-dd` → start of that day in `timeZone`.
    func date(_ string: String) -> Date? {
        guard let components = dayComponents(string) else { return nil }
        return calendar.date(from: components)
    }

    /// `HH:mm` → (hour, minute).
    func timeOfDay(_ string: String) -> (hour: Int, minute: Int)? {
        let values = string.split(separator: ":").compactMap { Int($0) }
        guard values.count >= 2, (0...23).contains(values[0]), (0...59).contains(values[1]) else { return nil }
        return (values[0], values[1])
    }

    /// `day` at `HH:mm` in `timeZone`.
    func combine(day: Date, time: (hour: Int, minute: Int)) -> Date? {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
    }

    private func dayComponents(_ string: String) -> DateComponents? {
        let values = string.trimmingCharacters(in: .whitespaces).prefix(10).split(separator: "-").compactMap { Int($0) }
        guard values.count == 3, (1...12).contains(values[1]), (1...31).contains(values[2]) else { return nil }
        return DateComponents(calendar: calendar, timeZone: timeZone, year: values[0], month: values[1], day: values[2])
    }

    // MARK: Formatting

    /// `2026-10-14T14:00:00` — wall-clock, no offset (pair with `timeZone.identifier`).
    func wallDateTimeString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// `2026-10-14T14:00` — compact form used inside prompts.
    func promptDateTimeString(_ date: Date) -> String {
        String(wallDateTimeString(date).prefix(16))
    }

    /// `2026-10-14`
    func dateString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// RFC 5545 UTC form for RRULE UNTIL: `20270412T225959Z`.
    static func icsUTCString(_ date: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// RFC3339 with offset, e.g. for `timeMin`/`timeMax` query parameters.
    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Parses Google's `dateTime` (RFC3339, offset or Z, optional fractional seconds).
    static func parseRFC3339(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
