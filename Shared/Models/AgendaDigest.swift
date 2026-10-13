import Foundation

/// What a schedule question ("what do I have tomorrow?") asked about, for the agenda card in chat.
/// The card renders `title` as its header and one aligned row per event ("12:30  Lunch");
/// `ReplyFormatter.agenda(_:clock:)` is the text version for Siri, notifications and VoiceOver.
struct AgendaDigest: Codable, Hashable, Sendable {
    /// The days asked about; `end` is exclusive (the start of the day after the last one).
    var range: DateInterval
    /// Localized label of the range: "Today · Thu, Oct 15", "今天 · 10月15日（週四）", "This week · Oct 11 – Oct 17".
    var title: String
    /// Sorted by start. Empty means "Nothing scheduled".
    var events: [ScheduleEvent]
}
