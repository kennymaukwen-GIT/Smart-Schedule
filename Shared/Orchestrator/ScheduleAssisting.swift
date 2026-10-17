import Foundation

/// What the chat panel, Quick Capture, Siri and the notification extension need from an assistant.
/// `ScheduleAssistant` (Gemini + Google Calendar) is the real one. Demo mode uses `DemoModeAssistant`: the real one
/// on the sample calendars, with `DemoAssistant` (offline rules) as its fallback.
///
/// Callers pass every argument. A protocol-extension `handle` overload with defaults would be ambiguous
/// with `ScheduleAssistant.handle`'s own defaulted parameters.
protocol ScheduleAssisting: Sendable {
    func handle(_ utterance: String, focusEventID: String?, now: Date) async throws -> ScheduleAssistant.Reply
    func confirm(_ pending: ScheduleAssistant.PendingDeletion) async throws -> ScheduleAssistant.Reply
    /// "Add" on a draft plan card: writes the reviewed draft (`Reply.planDraft`) and clears the pending plan.
    func commitPlan(_ draft: PlanDraft) async throws -> ScheduleAssistant.Reply
    /// Drops a draft plan without writing anything.
    func discardPlan(_ draft: PlanDraft) async -> ScheduleAssistant.Reply
    /// "Add" on a pending events card ("Ask me first"): writes the batch to its target and clears the slot.
    func commitPendingEvents(_ batch: PendingEventBatch) async throws -> ScheduleAssistant.Reply
    /// Drops a pending batch without writing anything.
    func discardPendingEvents(_ batch: PendingEventBatch) async -> ScheduleAssistant.Reply
    /// "✨ AI suggestions" on the event page: things `event` may need, for its notes. Pass the event as the page
    /// shows it (`notes` = the text being edited). Returns Smart Schedule's rule suggestions first (`.rules`, the
    /// ones the page already shows), then what the AI adds (`.ai`), without duplicates or anything the notes hold.
    /// No `.ai` item means only the rules answered ("Suggestions from Smart Schedules"). Nothing is written.
    /// - Throws: `GeminiError.consentRequired` without AI consent (nothing sent); `URLError` when offline.
    func suggestNotes(for event: ScheduleEvent) async throws -> [NoteSuggestion]
}

extension ScheduleAssisting {
    /// Smart Schedule's own rules, for an assistant without AI.
    func suggestNotes(for event: ScheduleEvent) async throws -> [NoteSuggestion] {
        NoteSuggester.ruleSuggestions(for: event, existingNotes: event.notes, limit: NoteSuggester.requestLimit)
    }
}

extension ScheduleAssistant: ScheduleAssisting {}
