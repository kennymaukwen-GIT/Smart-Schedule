import Foundation

/// `create_long_term_plan` args → a reviewable `PlanDraft`. Pure value logic shared by `ScheduleAssistant` and
/// `DemoAssistant`.
///
/// The args go through the real `CalendarEventMapper` first, so a plan that could not be written fails here,
/// before the user is asked to approve it, and the preview shows exactly the series Add will write.
struct PlanDraftBuilder: Sendable {
    /// The preview covers the whole plan or this many weeks, whichever is shorter.
    static let previewWeeks = 26

    let mapper: CalendarEventMapper

    init(mapper: CalendarEventMapper) {
        self.mapper = mapper
    }

    private var clock: WallClock { mapper.clock }

    func draft(from args: LongTermPlanArgs,
               argsJSON: Data,
               id: String,
               revision: Int,
               utterance: String) throws -> PlanDraft {
        let mapped = try mapper.events(fromPlan: args, planID: id, utterance: utterance)
        guard let start = clock.date(args.startDate) else { throw MappingError.invalidDate(args.startDate) }
        guard let parsedEnd = clock.date(args.endDate) else { throw MappingError.invalidDate(args.endDate) }
        let end = max(parsedEnd, start)

        // Only sessions the mapper turned into a series (it skips ones with bad dates, times or weekdays).
        let writtenIDs = Set(mapped.compactMap(\.body.id))
        let sessions = args.sessions.enumerated().compactMap { (index, session) -> PlanDraft.Session? in
            guard writtenIDs.contains(GoogleEventID.make(seed: "\(id)|session|\(index)")) else { return nil }
            return PlanDraft.Session(phaseIndex: session.phaseIndex,
                                     title: session.title,
                                     weekdays: RecurrenceRule.normalizedWeekdays(session.weekdays),
                                     startTime: session.startTime,
                                     durationMinutes: min(max(session.durationMinutes, 10), 240),
                                     notes: session.notes)
        }
        // Phases keep their positions because sessions point at them by index.
        let phases = args.phases.map { phase in
            PlanDraft.Phase(name: phase.name,
                            start: clock.date(phase.startDate) ?? start,
                            end: clock.date(phase.endDate) ?? end,
                            focus: phase.focus)
        }
        let milestones = (args.milestones ?? []).compactMap { milestone in
            clock.date(milestone.date).map { PlanDraft.Milestone(date: $0, title: milestone.title) }
        }
        let nudge = args.dailyNudge.flatMap { draft in
            clock.timeOfDay(draft.time).map {
                PlanDraft.Nudge(hour: $0.hour, minute: $0.minute, message: String(draft.message.prefix(120)))
            }
        }

        return PlanDraft(
            id: id,
            revision: revision,
            utterance: utterance,
            goal: args.goal,
            title: args.planTitle,
            startDate: start,
            endDate: end,
            summary: args.summaryForUser,
            phases: phases,
            sessions: sessions,
            milestones: milestones,
            nudge: nudge,
            assumptions: args.assumptions ?? [],
            previewEvents: occurrences(of: mapped, through: previewHorizon(start: start, end: end),
                                       idPrefix: PlanDraft.eventIDPrefix),
            writeCount: mapped.count,
            argsJSON: argsJSON
        )
    }

    /// Exclusive end of the preview: midnight after the plan's last day, or `previewWeeks` after its first day.
    func previewHorizon(start: Date, end: Date) -> Date {
        let calendar = clock.calendar
        let afterLastDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        let cap = calendar.date(byAdding: .day, value: 7 * Self.previewWeeks, to: calendar.startOfDay(for: start)) ?? afterLastDay
        return min(afterLastDay, cap)
    }

    func previewHorizon(for draft: PlanDraft) -> Date {
        previewHorizon(start: draft.startDate, end: draft.endDate)
    }

    /// Every series expanded up to `horizon`, plus every milestone as an all-day event, sorted by start.
    /// `idPrefix` is `PlanDraft.eventIDPrefix` for previews and `DemoData.idPrefix` when demo mode commits.
    func occurrences(of mapped: [MappedEvent], through horizon: Date, idPrefix: String) -> [ScheduleEvent] {
        var events: [ScheduleEvent] = []
        for item in mapped {
            if item.body.recurrence != nil {
                events += RecurrenceExpander.instances(of: item.body, through: horizon, idPrefix: idPrefix, mapper: mapper)
            } else if var milestone = mapper.scheduleEvent(from: item.body) {
                milestone.id = idPrefix + milestone.id
                events.append(milestone)
            }
        }
        return events.sorted { $0.start < $1.start }
    }

    // MARK: - Args JSON

    /// The same snake_case shape Gemini sends, so a draft built offline commits through the same decoder.
    static func encode(_ args: LongTermPlanArgs) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(args)
    }

    static func decodeArgs(_ data: Data) throws -> LongTermPlanArgs {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LongTermPlanArgs.self, from: data)
    }
}
