import Foundation

/// Single events the assistant prepared while "Adding events" is set to "Ask me first": nothing is in the calendar
/// until the user taps Add (or approves in chat). Stored in the App Group as one slot
/// (`SharedStore.pendingEventBatch()`), so the app, Siri and the notification extension share it; a new batch
/// replaces the old one.
///
/// Compiled into every target, so it depends on Foundation and the model types only.
struct PendingEventBatch: Codable, Hashable, Identifiable, Sendable {
    static let idPrefix = "batch-"
    /// Preview ids start with `PlanDraft.eventIDPrefix` too, so `ScheduleEvent.isDraft` holds and they draw as ghosts.
    static let previewIDPrefix = PlanDraft.eventIDPrefix + "ev-"

    var id: String                  // "batch-" + 8 random base32hex chars
    var createdAt: Date
    var utterance: String           // provenance line on commit
    var seed: String                // mapping seed: commit produces the same Google event ids (idempotent Add)
    var argsJSON: Data              // the create_events args (Gemini's, or the demo's encoding)
    var target: CalendarRef?        // nil in demo mode
    var targetLabel: String?        // "My calendar · example@gmail.com"
    /// Mapped previews with ids "draft-ev-<batch>-<n>" (`isDraft` is true), drawn as ghosts like plan previews.
    var previewEvents: [ScheduleEvent]

    init(id: String = PendingEventBatch.newID(),
         createdAt: Date,
         utterance: String,
         seed: String,
         argsJSON: Data,
         target: CalendarRef? = nil,
         targetLabel: String? = nil,
         previewEvents: [ScheduleEvent] = []) {
        self.id = id
        self.createdAt = createdAt
        self.utterance = utterance
        self.seed = seed
        self.argsJSON = argsJSON
        self.target = target
        self.targetLabel = targetLabel
        self.previewEvents = previewEvents
    }

    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuv")

    static func newID() -> String {
        idPrefix + String((0..<8).map { _ in alphabet.randomElement()! })
    }

    /// "draft-ev-k3p9a0bc-0" for the first preview of "batch-k3p9a0bc".
    static func previewID(batchID: String, index: Int) -> String {
        let suffix = batchID.hasPrefix(idPrefix) ? String(batchID.dropFirst(idPrefix.count)) : batchID
        return "\(previewIDPrefix)\(suffix)-\(index)"
    }

    /// The days the previews cover, for jumping the calendar to them.
    var previewRange: DateInterval? {
        guard let first = previewEvents.map(\.start).min(),
              let last = previewEvents.map(\.end).max() else { return nil }
        return DateInterval(start: first, end: max(last, first))
    }
}

extension PendingEventBatch {
    /// Tolerant: the batch lives in the App Group and in chat history, read by older and newer builds.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        argsJSON = try c.decode(Data.self, forKey: .argsJSON)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        utterance = (try? c.decodeIfPresent(String.self, forKey: .utterance)) ?? ""
        seed = (try? c.decodeIfPresent(String.self, forKey: .seed)) ?? id
        target = try? c.decodeIfPresent(CalendarRef.self, forKey: .target)
        targetLabel = try? c.decodeIfPresent(String.self, forKey: .targetLabel)
        previewEvents = (try? c.decodeIfPresent([ScheduleEvent].self, forKey: .previewEvents)) ?? []
    }
}
