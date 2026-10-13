import Foundation

/// What the chat panel, Quick Capture, Siri and the notification extension need from an assistant.
/// `ScheduleAssistant` (Gemini + Google Calendar) is the real one; `DemoAssistant` is the offline stand-in.
///
/// Callers pass every argument. A protocol-extension `handle` overload with defaults would be ambiguous
/// with `ScheduleAssistant.handle`'s own defaulted parameters.
protocol ScheduleAssisting: Sendable {
    func handle(_ utterance: String, focusEventID: String?, now: Date) async throws -> ScheduleAssistant.Reply
    func confirm(_ pending: ScheduleAssistant.PendingDeletion) async throws -> ScheduleAssistant.Reply
}

extension ScheduleAssistant: ScheduleAssisting {}
