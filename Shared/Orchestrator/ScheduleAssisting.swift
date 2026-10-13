import Foundation

/// What the chat panel, Quick Capture, Siri and the notification extension need from an assistant.
/// `ScheduleAssistant` (Gemini + Google Calendar) is the real one; `DemoAssistant` is the offline stand-in.
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
}

extension ScheduleAssistant: ScheduleAssisting {}
