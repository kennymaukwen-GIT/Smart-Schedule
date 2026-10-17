import Foundation

/// Demo mode's assistant: the real one (`ScheduleAssistant`, Gemini through Smart Schedule's server, behind the same
/// AI consent) on the sample calendars, with the offline rules (`DemoAssistant`) as its fallback.
///
/// - The AI side is its own `ScheduleAssistant`, never `.shared`, on a router whose accounts are pinned to the samples
///   (`AccountStore.sampleCalendarsOnly()`): its writes stay in the cache on this iPhone (`CalendarRouter+Sample.swift`)
///   and its prompt says the calendars are fictional (`AssistantPrompt.demoModeBlock`).
/// - The offline rules answer when AI data sharing is not allowed, or when the AI fails. The AI fails only before it
///   writes anything (`ScheduleAssistant.handle` throws only from Gemini), so a fallback never repeats a write. App
///   Attest that this device or build can't do (or a server this build doesn't know) is not tried again until
///   `resetConversation`. Each reason is said once ("…so demo mode answered with its offline rules."), until the AI
///   answers again.
/// - A question carries over: when the offline rules asked back ("what time?"), the answer goes to them as well; when
///   the AI asked back and the offline rules answer next (the AI failed, or consent was withdrawn), they get the
///   request and the answer together.
/// - Only sample data reaches either side: a `focusEventID` that is not a `demo-` id (a hidden copy of a real event,
///   which `SharedStore.event(id:)` still finds) is dropped, and once demo mode has ended nothing is sent or written.
actor DemoModeAssistant: ScheduleAssisting {
    typealias Reply = ScheduleAssistant.Reply

    /// Why the offline rules answered.
    enum Fallback {
        /// AI data sharing is not allowed.
        case consentOff
        /// No connection, App Attest unavailable, a limit reached or a server error.
        case unavailable

        /// Added below the offline rules' reply.
        var note: String {
            switch self {
            case .consentOff:
                String(localized: "AI data sharing is off, so demo mode answered with its offline rules. You can allow it in Settings › AI & privacy.")
            case .unavailable:
                String(localized: "The AI isn't available right now, so demo mode answered with its offline rules.")
            }
        }
    }

    private let ai: ScheduleAssistant
    private let offline: DemoAssistant
    private let consent: @Sendable () -> AIConsent
    private let isDemoMode: @Sendable () -> Bool
    /// The AI can't work in this build or on this device (`AttestationError.unsupported`, `.notConfigured`,
    /// `.sessionMissing`): not tried again until `resetConversation`.
    private var aiUnavailable = false
    /// The reason said last: each is said once, until the AI answers again.
    private var lastNote: Fallback?
    /// The offline rules asked back ("what time?"): the answer goes to them too.
    private var offlineAsked = false
    /// What the user asked before the AI asked back, for the offline rules if they answer next.
    private var aiQuestion: String?

    /// - Parameters:
    ///   - ai: demo mode's own real assistant, on the sample calendars. Unit tests pass one with a stubbed Gemini.
    ///   - offline: the offline rules, on the same cache.
    ///   - consent: the answer to "Use the AI assistant?", read per request.
    ///   - isDemoMode: the live demo flag, read per request.
    init(ai: ScheduleAssistant = ScheduleAssistant(router: CalendarRouter(accounts: .sampleCalendarsOnly())),
         offline: DemoAssistant = DemoAssistant(),
         consent: @escaping @Sendable () -> AIConsent = { AIConsentStore.current },
         isDemoMode: @escaping @Sendable () -> Bool = { AppConstants.isDemoMode }) {
        self.ai = ai
        self.offline = offline
        self.consent = consent
        self.isDemoMode = isDemoMode
    }

    /// Whether the chat asks "Use the AI assistant?" before sending in demo mode: not asked yet, or answered for an
    /// older disclosure. After "Not now" for the current one it is not asked again; the offline rules answer instead.
    static func shouldAskConsent(_ consent: AIConsent) -> Bool {
        !consent.isGranted && (consent.status == .notAsked || consent.version < AIConsent.disclosureVersion)
    }

    /// The event a reminder reply is about, when it is a sample one.
    static func sampleFocus(_ eventID: String?) -> String? {
        guard let eventID, DemoData.isDemoID(eventID) else { return nil }
        return eventID
    }

    func handle(_ utterance: String, focusEventID: String? = nil, now: Date = Date()) async throws -> Reply {
        // A request made after demo mode ended (Siri, a notification reply): nothing is sent or written.
        guard isDemoMode() else { return Reply(text: DemoCalendarError.demoEnded.localizedDescription) }
        let focus = Self.sampleFocus(focusEventID)
        if offlineAsked { return try await offlineAnswer(utterance, focus: focus, now: now, reason: nil) }

        let reason: Fallback
        if !consent().isGranted {
            reason = .consentOff
        } else if aiUnavailable {
            reason = .unavailable
        } else {
            do {
                var reply = try await ai.handle(utterance, focusEventID: focus, now: now)
                lastNote = nil
                aiQuestion = reply.needsClarification ? (aiQuestion ?? utterance) : nil
                if reply.changed { reply.append(DemoAssistant.demoNote) }
                return reply
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                reason = fallback(after: error)
            }
        }
        // What the AI asked about goes along with the answer ("明天開會" + "14:00").
        let text = aiQuestion.map { "\($0) \(utterance)" } ?? utterance
        aiQuestion = nil
        return try await offlineAnswer(text, focus: focus, now: now, reason: reason)
    }

    /// The offline rules' answer, with the reason they answered unless it was just said.
    private func offlineAnswer(_ text: String, focus: String?, now: Date, reason: Fallback?) async throws -> Reply {
        var reply = try await offline.handle(text, focusEventID: focus, now: now)
        offlineAsked = reply.needsClarification
        if let reason, lastNote != reason {
            reply.append(reason.note)
            lastNote = reason
        }
        return reply
    }

    /// Why the offline rules answer after `error`. App Attest that can't work here is not tried again.
    private func fallback(after error: Error) -> Fallback {
        if let attestation = error as? AttestationError {
            switch attestation {
            case .unsupported, .notConfigured, .sessionMissing: aiUnavailable = true
            default: break
            }
        }
        if let gemini = error as? GeminiError, case .consentRequired = gemini { return .consentOff }
        return .unavailable
    }

    /// The offline rules' deletions carry no refs (their events are only in the cache); the AI's carry where each
    /// event lives, and its router deletes sample events from the cache only.
    func confirm(_ pending: ScheduleAssistant.PendingDeletion) async throws -> Reply {
        guard !pending.refs.isEmpty else { return try await offline.confirm(pending) }
        var reply = try await ai.confirm(pending)
        reply.append(DemoAssistant.demoNote)
        return reply
    }

    /// A draft the offline rules made has a `demo-` id; the AI's has a Google-style one.
    func commitPlan(_ draft: PlanDraft) async throws -> Reply {
        if DemoData.isDemoID(draft.id) { return try await offline.commitPlan(draft) }
        var reply = try await ai.commitPlan(draft)
        reply.append(DemoAssistant.demoNote)
        return reply
    }

    func discardPlan(_ draft: PlanDraft) async -> Reply {
        if DemoData.isDemoID(draft.id) { return await offline.discardPlan(draft) }
        return await ai.discardPlan(draft)
    }

    /// Always the AI's writer, whichever side proposed the batch: on the sample calendars it needs no network, and it
    /// keeps everything the batch holds (place, notes, repeat, reminders).
    func commitPendingEvents(_ batch: PendingEventBatch) async throws -> Reply {
        var reply = try await ai.commitPendingEvents(batch)
        reply.append(DemoAssistant.demoNote)
        return reply
    }

    func discardPendingEvents(_ batch: PendingEventBatch) async -> Reply {
        await ai.discardPendingEvents(batch)
    }

    /// The AI's suggestions for a sample event, behind the same consent. Not asked yet (or asked for an older
    /// disclosure): `GeminiError.consentRequired`, nothing sent, so the event page shows its sheet. "Not now", an AI
    /// that can't be reached, any other event (a hidden copy of a real one) or demo mode over: the offline rules.
    func suggestNotes(for event: ScheduleEvent) async throws -> [NoteSuggestion] {
        guard DemoData.isDemoID(event.id), isDemoMode() else { return try await offline.suggestNotes(for: event) }
        let current = consent()
        if Self.shouldAskConsent(current) { throw GeminiError.consentRequired }
        guard current.isGranted, !aiUnavailable else { return try await offline.suggestNotes(for: event) }
        do {
            return try await ai.suggestNotes(for: event)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            _ = fallback(after: error)
            return try await offline.suggestNotes(for: event)
        }
    }

    /// A new conversation: the AI's history goes, and so does everything kept here (a question waiting for its answer,
    /// the reason said last, an AI that could not work).
    func resetConversation() async {
        await ai.resetConversation()
        aiUnavailable = false
        lastNote = nil
        offlineAsked = false
        aiQuestion = nil
    }
}
