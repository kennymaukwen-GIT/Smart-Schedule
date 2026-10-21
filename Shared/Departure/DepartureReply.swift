import Foundation

/// A departure answer as the assistant's reply carries it (build step G4d), in memory only: deliberately not Codable,
/// so it can't reach chat history, the export, the App Group or Gemini. `Reply.text` holds `kept`; the chat swaps in
/// `shown` while the app runs (`displayText`).
struct DepartureReply: Equatable, Sendable {
    /// What the chat shows now: the answer with Google's times, and its notes (plans left, Ask me first, …).
    var shown: String
    /// What the reply text keeps: the same answer without any time from Google (`DepartureLines.kept`).
    var kept: String
    /// For the Google Maps button (build step G5): the destination as written and how the user travels.
    var destination: String?
    var mode: TravelMode?
    /// The server's token for free rechecks of the same trip. Not Google content; never stored in G4.
    var planToken: String?

    /// The chat's text with the kept answer swapped for the shown one. Unchanged without a departure, or when the text
    /// doesn't hold the kept answer (it was already swapped, or the reply was edited).
    static func displayText(_ text: String, departure: DepartureReply?) -> String {
        guard let departure, !departure.kept.isEmpty, let range = text.range(of: departure.kept) else { return text }
        return text.replacingCharacters(in: range, with: departure.shown)
    }
}
