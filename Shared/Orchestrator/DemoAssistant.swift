import Foundation

/// Offline stand-in for `ScheduleAssistant` in demo mode: no Google account, no Gemini key, no network.
/// Keyword heuristics cover the artboard flows (long-term plan, "push it 30 min", delete, agenda, and
/// "title + day + time" capture). Every write goes to the local `SharedStore` only.
actor DemoAssistant: ScheduleAssisting {
    typealias Reply = ScheduleAssistant.Reply

    static let demoNote = "(Demo mode: nothing was written to Google Calendar.)"
    private static let expansionWeeks = 10

    private let store: SharedStore
    private let clock: WallClock
    private let mapper: CalendarEventMapper
    /// Title and day from a "what time?" question, so tapping the "14:00" suggestion completes that event.
    private var pendingDraft: (title: String, day: Date?)?

    init(store: SharedStore = .shared, clock: WallClock = WallClock(), policy: ReminderPolicy = ReminderPolicy()) {
        self.store = store
        self.clock = clock
        self.mapper = CalendarEventMapper(clock: clock, policy: policy)
    }

    func handle(_ utterance: String, focusEventID: String? = nil, now: Date = Date()) async throws -> Reply {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let parser = DemoParser(clock: clock, now: now)
        let pending = pendingDraft
        pendingDraft = nil

        // Shift runs first: it only claims an utterance with a move word plus an amount (or a time and a focus
        // event), so "push the gym routine 30 min" is not mistaken for a new plan.
        let reply: Reply
        if let shifted = await shift(text, lower: lower, focusEventID: focusEventID, parser: parser) {
            reply = shifted
        } else if Self.isGoal(lower) {
            reply = try await plan(text, lower: lower, now: now)
        } else if let deleteReply = await deletion(lower, now: now) {
            reply = deleteReply
        } else if Self.isAgendaQuery(lower), !parser.containsTime(text) {
            reply = await agenda(text, lower: lower, parser: parser)
        } else {
            reply = await capture(text, pending: pending, parser: parser)
        }

        if reply.changed { await ReminderScheduler.shared.reschedule(store: store) }
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    func confirm(_ pending: ScheduleAssistant.PendingDeletion) async throws -> Reply {
        await store.remove(ids: Set(pending.eventIDs), seriesIDs: Set(pending.eventIDs))
        if let planID = pending.planID { await store.removeNudges(planID: planID) }
        await ReminderScheduler.shared.reschedule(store: store)
        var reply = Reply(changed: true)
        reply.append("Deleted \(pending.eventIDs.count) item(s) on this device.")
        reply.append(Self.demoNote)
        return reply
    }

    // MARK: - (a) Long-term goal → plan

    private static func isGoal(_ lower: String) -> Bool {
        let phrases = ["muscular", "muscle", "gym routine", "workout plan", "增肌", "健身", "變壯", "变壮", "肌肉"]
        if phrases.contains(where: { lower.contains($0) }) { return true }
        if DemoParser.match(#"\b(?:get|be|getting|stay|keep)\s+fit\b|\bfitness\b"#, in: lower) != nil { return true }
        // "in 6 months" alone could be a trip; it counts as a goal next to a goal-ish verb.
        return DemoParser.match(#"\bin\s+\d{1,2}\s*months?\b"#, in: lower) != nil
            && DemoParser.match(#"\b(?:want|become|be|get|build|gain|lose|goal|routine|plan)\b"#, in: lower) != nil
    }

    private static func planMonths(_ lower: String) -> Int {
        if lower.contains("half a year") || lower.contains("半年") { return 6 }
        if let match = DemoParser.match(#"(\d{1,2})\s*-?\s*months?\b"#, in: lower),
           let months = Int(match.group(1) ?? "") {
            return min(max(months, 1), 12)
        }
        if let match = DemoParser.match(#"(\#(DemoParser.cnNumber))\s*[個个]月"#, in: lower),
           let months = DemoParser.number(match.group(1) ?? "") {
            return min(max(months, 1), 12)
        }
        if lower.contains("a year") || lower.contains("一年") { return 12 }
        return 6
    }

    /// Builds the same `LongTermPlanArgs` Gemini would send, runs it through the real mapper, then expands the
    /// weekly series locally instead of asking Google to.
    private func plan(_ text: String, lower: String, now: Date) async throws -> Reply {
        let calendar = clock.calendar
        let months = Self.planMonths(lower)
        let startDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let endExclusive = calendar.date(byAdding: .month, value: months, to: startDay)!
        let endDay = calendar.date(byAdding: .day, value: -1, to: endExclusive)!
        let totalDays = max(calendar.dateComponents([.day], from: startDay, to: endExclusive).day ?? months * 30, 3)

        let phaseInfo = [
            ("Foundation", "Technique, full range of motion, build the habit"),
            ("Hypertrophy", "8–12 reps, add weight or reps every week"),
            ("Strength", "Heavier compound lifts, 4–6 reps")
        ]
        var phases: [PhaseDraft] = []
        for (index, info) in phaseInfo.enumerated() {
            let first = calendar.date(byAdding: .day, value: totalDays * index / 3, to: startDay)!
            let next = calendar.date(byAdding: .day, value: totalDays * (index + 1) / 3, to: startDay)!
            let last = calendar.date(byAdding: .day, value: -1, to: next)!
            phases.append(PhaseDraft(name: info.0, startDate: clock.dateString(first),
                                     endDate: clock.dateString(last), focus: info.1))
        }

        var sessions: [SessionDraft] = []
        for index in phases.indices {
            sessions.append(SessionDraft(phaseIndex: index, title: "Upper body", weekdays: ["MO", "TH"],
                                         startTime: "18:30", durationMinutes: 60, notes: "Push + pull, then core"))
            sessions.append(SessionDraft(phaseIndex: index, title: "Lower body", weekdays: ["TU", "FR"],
                                         startTime: "18:30", durationMinutes: 60, notes: "Squat or deadlift, then mobility"))
        }

        var milestones: [MilestoneDraft] = []
        for month in 1...months {
            let monthEnd = calendar.date(byAdding: .month, value: month, to: startDay)!
            let day = calendar.date(byAdding: .day, value: -1, to: monthEnd)!
            let title = month == months
                ? "Final check-in: photos, measurements, strength test"
                : "Month \(month) check-in: weigh-in and photos"
            milestones.append(MilestoneDraft(date: clock.dateString(day), title: title))
        }

        let span = months == 1 ? "1 month" : "\(months) months"
        let summary = "Here is a plan I designed for you: exercise 4 days a week for \(span) — Mon/Thu upper body, "
            + "Tue/Fri lower body at 18:30 — in 3 phases (Foundation → Hypertrophy → Strength), "
            + "with a 07:30 morning nudge and a monthly check-in."
        let args = LongTermPlanArgs(
            goal: text,
            planTitle: "Muscle Plan",
            startDate: clock.dateString(startDay),
            endDate: clock.dateString(endDay),
            summaryForUser: summary,
            phases: phases,
            sessions: sessions,
            dailyNudge: NudgeDraft(time: "07:30", message: "Morning! Protein with breakfast; today's session is at 18:30."),
            milestones: milestones,
            assumptions: ["Workouts at 18:30 after work", "Starts tomorrow", "You have gym access"]
        )

        let planID = DemoData.idPrefix + GoogleEventID.newPlanID()
        let mapped = try mapper.events(fromPlan: args, planID: planID, utterance: text)
        let horizon = calendar.date(byAdding: .day, value: 7 * Self.expansionWeeks, to: calendar.startOfDay(for: now))!
        var events: [ScheduleEvent] = []
        for item in mapped {
            if let rule = item.body.recurrence?.first {
                events += expand(item.body, rule: rule, through: horizon)
            } else if var milestone = mapper.scheduleEvent(from: item.body) {
                milestone.id = DemoData.idPrefix + milestone.id
                events.append(milestone)
            }
        }
        await store.upsert(events)
        if let nudge = mapper.nudge(from: args, planID: planID) { await store.addNudge(nudge) }

        let workouts = events.filter { $0.kind == .routine }.count
        var reply = Reply()
        reply.changed = true
        reply.created = events
        reply.append(summary)
        reply.append("\(workouts) workouts added for the next \(Self.expansionWeeks) weeks, plus \(milestones.count) monthly check-ins.")
        reply.append(Self.demoNote)
        reply.assumptions = args.assumptions ?? []
        reply.showRange = DateInterval(start: startDay, duration: 7 * 86_400)
        return reply
    }

    /// Expands one weekly series from the plan mapper (`RRULE:FREQ=WEEKLY;BYDAY=…;UNTIL=…`) into instances,
    /// shaped like Google's expanded recurrences (`<seriesId>_<date>` ids, `recurringEventId` set).
    private func expand(_ series: GCalEvent, rule: String, through horizon: Date) -> [ScheduleEvent] {
        let calendar = clock.calendar
        guard let startRaw = series.start?.dateTime, let firstStart = clock.dateTime(startRaw),
              let endRaw = series.end?.dateTime, let firstEnd = clock.dateTime(endRaw) else { return [] }
        let fields = Self.ruleFields(rule)
        let weekdays = Set((fields["BYDAY"] ?? "").split(separator: ",").map(String.init))
        let until = fields["UNTIL"].flatMap(Self.parseICSUTC) ?? horizon
        let last = min(until, horizon)
        let duration = firstEnd.timeIntervalSince(firstStart)
        let time = calendar.dateComponents([.hour, .minute], from: firstStart)
        let seriesID = DemoData.idPrefix + (series.id ?? UUID().uuidString)

        var output: [ScheduleEvent] = []
        var day = calendar.startOfDay(for: firstStart)
        while day <= last {
            let code = RecurrenceRule.weekdayCodes[calendar.component(.weekday, from: day) - 1] // weekday 1 = Sunday
            if weekdays.contains(code),
               let start = clock.combine(day: day, time: (hour: time.hour ?? 0, minute: time.minute ?? 0)),
               start >= firstStart, start <= until {
                var instance = series
                instance.id = seriesID + "_" + clock.dateString(day).replacingOccurrences(of: "-", with: "")
                instance.recurringEventId = seriesID
                instance.recurrence = nil
                instance.start = mapper.timed(start)
                instance.end = mapper.timed(start.addingTimeInterval(duration))
                if var event = mapper.scheduleEvent(from: instance) {
                    event.kind = .routine
                    output.append(event)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return output
    }

    private static func ruleFields(_ rule: String) -> [String: String] {
        let body = rule.hasPrefix("RRULE:") ? String(rule.dropFirst("RRULE:".count)) : rule
        var fields: [String: String] = [:]
        for part in body.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0].uppercased()] = pair[1] }
        }
        return fields
    }

    /// `20270412T225959Z` → instant.
    private static func parseICSUTC(_ value: String) -> Date? {
        let digits = Array(value.filter { $0.isASCII && $0.isNumber })
        guard digits.count >= 8 else { return nil }
        func field(_ start: Int, _ length: Int) -> Int? {
            guard digits.count >= start + length else { return nil }
            return Int(String(digits[start..<(start + length)]))
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: field(0, 4), month: field(4, 2), day: field(6, 2),
                                             hour: field(8, 2) ?? 0, minute: field(10, 2) ?? 0, second: field(12, 2) ?? 0))
    }

    // MARK: - (c) "push it 30 min"

    private func shift(_ text: String, lower: String, focusEventID: String?, parser: DemoParser) async -> Reply? {
        let chineseMoveWords = ["延後", "延后", "推遲", "推迟", "晚一點", "晚一点", "晚點", "晚点", "改到", "移到", "延到"]
        guard DemoParser.match(#"\b(?:push|delay|later|postpone|move|reschedule)\b"#, in: lower) != nil
            || chineseMoveWords.contains(where: { lower.contains($0) }) else { return nil }
        let delta = Self.relativeMinutes(lower)
        var leftover = text
        var newTime: DemoParser.TimeOfDay?
        // An absolute "push it to 4pm" only makes sense when a reminder says which event "it" is.
        if delta == nil, focusEventID != nil { newTime = parser.extractTime(from: &leftover) }
        guard delta != nil || newTime != nil else { return nil }

        guard let event = await target(lower: lower, focusEventID: focusEventID, now: parser.now) else {
            var reply = Reply()
            reply.needsClarification = true
            reply.append("Which event should I move? Try “push the team sync 30 min”.")
            return reply
        }
        var updated = event
        if let delta {
            updated.start = event.start.addingTimeInterval(TimeInterval(delta) * 60)
        } else if let newTime {
            let day = parser.extractDay(from: &leftover)?.date ?? clock.calendar.startOfDay(for: event.start)
            updated.start = clock.combine(day: day, time: (hour: newTime.hour, minute: newTime.minute)) ?? event.start
        }
        updated.end = updated.start.addingTimeInterval(event.duration)
        await store.upsert([updated])

        var reply = Reply()
        reply.changed = true
        reply.showRange = DateInterval(start: clock.calendar.startOfDay(for: updated.start), duration: 86_400)
        reply.append(ReplyFormatter.updated(updated, clock: clock))
        return reply
    }

    private static func relativeMinutes(_ lower: String) -> Int? {
        if ["half an hour", "半小時", "半小时", "半個小時", "半个小时"].contains(where: { lower.contains($0) }) { return 30 }
        if let match = DemoParser.match(#"(\d{1,3})\s*(?:mins?|minutes?)\b"#, in: lower), let value = Int(match.group(1) ?? "") {
            return value
        }
        if let match = DemoParser.match(#"([0-9]{1,3}|[零〇一二兩两三四五六七八九十]{1,4})\s*(?:分鐘|分钟)"#, in: lower),
           let value = DemoParser.number(match.group(1) ?? "") {
            return value
        }
        if let match = DemoParser.match(#"(\d{1,2})\s*(?:h|hrs?|hours?)\b"#, in: lower), let value = Int(match.group(1) ?? "") {
            return value * 60
        }
        if let match = DemoParser.match(#"(\#(DemoParser.cnNumber))\s*(?:個|个)?\s*(?:小時|小时|鐘頭|钟头)"#, in: lower),
           let value = DemoParser.number(match.group(1) ?? "") {
            return value * 60
        }
        if lower.contains("an hour") || lower.contains("one hour") { return 60 }
        return nil
    }

    /// The reminder's event, else the soonest upcoming event the utterance names, else simply the next one.
    private func target(lower: String, focusEventID: String?, now: Date) async -> ScheduleEvent? {
        if let focusEventID, let event = await store.event(id: focusEventID) { return event }
        let upcoming = await store.events(in: DateInterval(start: now, duration: 14 * 86_400)).filter { !$0.isAllDay }
        return upcoming.first(where: { Self.mentions(lower, $0.title) }) ?? upcoming.first
    }

    /// True when the utterance names the event: "gym" for "Gym", "sync" for "Weekly team sync".
    private static func mentions(_ lower: String, _ title: String) -> Bool {
        let ignored: Set<String> = ["the", "with", "for", "and", "from", "weekly", "plan", "online"]
        let keywords = title.lowercased()
            .split(whereSeparator: { character in !character.isLetter && !character.isNumber })
            .map(String.init)
            .filter { word in
                !ignored.contains(word) && (word.count >= 3 || word.contains { character in !character.isASCII })
            }
        return keywords.contains { lower.contains($0) }
    }

    // MARK: - Delete (always waits for a Confirm tap)

    private func deletion(_ lower: String, now: Date) async -> Reply? {
        let words = ["delete", "cancel", "remove", "刪除", "删除", "取消"]
        guard words.contains(where: { lower.contains($0) }) else { return nil }
        let snapshot = await store.snapshot()
        let events = snapshot.events.sorted { $0.start < $1.start }
        var reply = Reply()

        let wantsPlan = ["plan", "計畫", "计划", "計劃", "routine"].contains { lower.contains($0) }
        if wantsPlan, let planID = snapshot.nudges.last?.planID ?? events.last(where: { $0.planID != nil })?.planID {
            let ids = events.filter { $0.planID == planID }.map(\.id)
            reply.pendingDeletion = ScheduleAssistant.PendingDeletion(eventIDs: ids, planID: planID,
                                                                      summary: "the plan (\(ids.count) items)")
        } else {
            let named = events.filter { $0.end > now && Self.mentions(lower, $0.title) }
            guard let first = named.first else {
                reply.append("I couldn't find that event. Try naming it, e.g. “cancel the dentist”.")
                return reply
            }
            let everyOccurrence = DemoParser.match(#"\b(?:all|every)\b"#, in: lower) != nil
                || lower.contains("所有") || lower.contains("全部")
            let chosen = everyOccurrence && first.seriesID != nil ? named.filter { $0.seriesID == first.seriesID } : [first]
            let summary = chosen.count == 1
                ? "\(first.title) — \(ReplyFormatter.stamp(first, clock: clock))"
                : "\(first.title) (\(chosen.count) times)"
            reply.pendingDeletion = ScheduleAssistant.PendingDeletion(eventIDs: chosen.map(\.id), planID: nil, summary: summary)
        }
        let summary = reply.pendingDeletion?.summary ?? "it"
        reply.append("Delete \(summary)? Tap Confirm.")
        return reply
    }

    // MARK: - (b) "show me my schedule for tomorrow"

    private static func isAgendaQuery(_ lower: String) -> Bool {
        let phrases = ["show me", "my schedule", "schedule for", "what's on", "what’s on", "whats on", "what do i have",
                       "agenda", "行程", "有什麼", "有什么", "有哪些"]
        if phrases.contains(where: { lower.contains($0) }) { return true }
        let bare = lower.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return ["today", "tomorrow", "this week", "今天", "明天", "後天", "后天", "這週", "这周", "本週", "本周"].contains(bare)
    }

    private func agenda(_ text: String, lower: String, parser: DemoParser) async -> Reply {
        let calendar = clock.calendar
        let interval: DateInterval
        let label: String
        if ["week", "這週", "这周", "本週", "本周"].contains(where: { lower.contains($0) }),
           let week = calendar.dateInterval(of: .weekOfYear, for: parser.now) {
            interval = week
            label = "this week"
        } else {
            var leftover = text
            let day = parser.extractDay(from: &leftover)?.date ?? calendar.startOfDay(for: parser.now)
            interval = DateInterval(start: day, end: calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400))
            label = parser.label(for: day)
        }
        let events = await store.events(in: interval)
        var reply = Reply()
        reply.showRange = interval
        reply.append("Your schedule for \(label):")
        reply.append(ReplyFormatter.agenda(events, clock: clock))
        return reply
    }

    // MARK: - (d) "Lunch with Andrew tomorrow 1pm" · (e) no time → ask

    private func capture(_ text: String, pending: (title: String, day: Date?)?, parser: DemoParser) async -> Reply {
        let calendar = clock.calendar
        let now = parser.now
        var leftover = text
        let time = parser.extractTime(from: &leftover)
        let dayMatch = parser.extractDay(from: &leftover)
        var title = DemoParser.title(from: leftover)
        var day = dayMatch?.date
        if title.isEmpty, let pending {
            title = pending.title
            day = day ?? pending.day
        }
        if title.isEmpty { title = "New event" }

        var reply = Reply()
        guard let time else {
            pendingDraft = (title: title, day: day)
            let dayNote = day.map { " (\(parser.label(for: $0)))" } ?? ""
            reply.needsClarification = true
            reply.suggestions = ["09:00", "14:00", "19:00"]
            reply.append("What time should I schedule “\(title)”\(dayNote)?")
            return reply
        }

        var hour = time.hour
        if dayMatch?.evening == true, !time.hasMeridiem, hour < 12 { hour += 12 }
        guard var start = clock.combine(day: day ?? calendar.startOfDay(for: now), time: (hour: hour, minute: time.minute)) else {
            reply.append("I couldn't work out that time.")
            return reply
        }
        if start < now, day == nil {
            start = calendar.date(byAdding: .day, value: 1, to: start) ?? start // "3pm" said at 5pm means tomorrow
        } else if start < now, dayMatch?.rollsForward == true {
            start = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        }

        let kind = CalendarEventMapper.inferKind(title)
        let event = ScheduleEvent(
            id: DemoData.idPrefix + "chat-" + UUID().uuidString.prefix(8).lowercased(),
            seriesID: nil,
            title: title,
            start: start,
            end: start.addingTimeInterval(3600),
            isAllDay: false,
            kind: kind,
            colorHex: DemoData.colorHex(for: kind),
            location: nil,
            meetURL: nil,
            notes: CalendarEventMapper.provenancePrefix + text,
            reminderMinutes: nil,
            planID: nil,
            htmlLink: nil,
            isCompleted: false
        )
        let dayInterval = DateInterval(start: calendar.startOfDay(for: start), duration: 86_400)
        let sameDay = await store.events(in: dayInterval)
        await store.upsert([event])

        reply.changed = true
        reply.created = [event]
        reply.showRange = dayInterval
        reply.append(ReplyFormatter.confirmation(for: [event], clock: clock))
        reply.append(ReplyFormatter.conflicts([event], against: sameDay))
        reply.append(Self.demoNote)
        return reply
    }
}

// MARK: - Parsing

/// Rule-based parsing for demo mode. Each `extract…` call removes the tokens it understood from `text`,
/// so whatever is left over becomes the event title.
private struct DemoParser {
    struct TimeOfDay {
        var hour: Int
        var minute: Int
        var hasMeridiem: Bool  // am/pm, 下午…, or an unambiguous 24-hour value such as 14:30
    }

    struct DayMatch {
        var date: Date
        var evening = false        // "tonight", 今晚, 明晚: a bare "8" means 20:00
        var rollsForward = false   // bare weekday that is today: an already-past time means next week
    }

    struct RegexMatch {
        let range: Range<String.Index>
        let groups: [String?]      // 0 = whole match

        func group(_ index: Int) -> String? {
            index < groups.count ? groups[index] : nil
        }
    }

    static let cnNumber = "[0-9]{1,2}|[零〇一二兩两三四五六七八九十]{1,3}"
    private static let monthNames =
        #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#

    let clock: WallClock
    let now: Date

    private var calendar: Calendar { clock.calendar }
    private var today: Date { calendar.startOfDay(for: now) }

    // MARK: Time of day

    func containsTime(_ text: String) -> Bool {
        var copy = text
        return extractTime(from: &copy) != nil
    }

    func extractTime(from text: inout String) -> TimeOfDay? {
        // "1pm", "2 pm", "10:30 a.m."
        if let match = Self.match(#"(?<![\d:])(1[0-2]|0?[1-9])(?:[:：]([0-5]\d))?\s*(a\.?m\.?|p\.?m\.?)(?![a-z])"#, in: text),
           let hour = Int(match.group(1) ?? "") {
            text.replaceSubrange(match.range, with: " ")
            let isPM = (match.group(3) ?? "").lowercased().hasPrefix("p")
            return TimeOfDay(hour: hour % 12 + (isPM ? 12 : 0), minute: Int(match.group(2) ?? "") ?? 0, hasMeridiem: true)
        }
        // "13:00", "9:05", "14：30"
        if let match = Self.match(#"(?<!\d)([01]?\d|2[0-3])[:：]([0-5]\d)(?!\d)"#, in: text),
           let raw = match.group(1), let hour = Int(raw), let minute = Int(match.group(2) ?? "") {
            text.replaceSubrange(match.range, with: " ")
            return TimeOfDay(hour: hour, minute: minute, hasMeridiem: hour >= 13 || raw.hasPrefix("0"))
        }
        // 下午兩點, 下午2點, 晚上7點半, 上午10點15分, 九點. The lookbehind keeps 週一十點 from reading "一十" as 10.
        let chinese = #"(凌晨|清晨|早上|上午|中午|下午|傍晚|晚上)?\s*(?<![週周期拜月])(\#(Self.cnNumber))\s*[點点時时](?:鐘|钟)?(?:\s*(半|\#(Self.cnNumber))\s*分?)?"#
        if let match = Self.match(chinese, in: text), var hour = Self.number(match.group(2) ?? "") {
            let period = match.group(1) ?? ""
            var minute = 0
            if let raw = match.group(3) { minute = raw == "半" ? 30 : (Self.number(raw) ?? 0) }
            switch period {
            case "下午", "傍晚", "晚上": if hour < 12 { hour += 12 }
            case "中午": if hour < 6 { hour += 12 }
            case "凌晨", "清晨", "早上", "上午": if hour == 12 { hour = 0 }
            default: break
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            text.replaceSubrange(match.range, with: " ")
            return TimeOfDay(hour: hour, minute: minute, hasMeridiem: !period.isEmpty)
        }
        // "noon", 中午
        if let match = Self.match(#"\bnoon\b|中午"#, in: text) {
            text.replaceSubrange(match.range, with: " ")
            return TimeOfDay(hour: 12, minute: 0, hasMeridiem: true)
        }
        // "at 3": 1–7 without am/pm reads as afternoon
        if let match = Self.match(#"\bat\s+(\d{1,2})(?![\d:])"#, in: text),
           let hour = Int(match.group(1) ?? ""), (0...23).contains(hour) {
            text.replaceSubrange(match.range, with: " ")
            return TimeOfDay(hour: (1...7).contains(hour) ? hour + 12 : hour, minute: 0, hasMeridiem: false)
        }
        return nil
    }

    // MARK: Day

    func extractDay(from text: inout String) -> DayMatch? {
        // "oct 15", "October 15th"
        if let match = Self.match(#"\b\#(Self.monthNames)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, in: text),
           let date = upcoming(monthName: match.group(1), day: match.group(2)) {
            text.replaceSubrange(match.range, with: " ")
            return DayMatch(date: date)
        }
        // "15 oct", "15th of October"
        if let match = Self.match(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?\#(Self.monthNames)\b"#, in: text),
           let date = upcoming(monthName: match.group(2), day: match.group(1)) {
            text.replaceSubrange(match.range, with: " ")
            return DayMatch(date: date)
        }
        // "10/15" (month/day)
        if let match = Self.match(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?![\d/])"#, in: text),
           let date = upcoming(month: Int(match.group(1) ?? ""), day: Int(match.group(2) ?? "")) {
            text.replaceSubrange(match.range, with: " ")
            return DayMatch(date: date)
        }
        // 10月15日
        if let match = Self.match(#"(\#(Self.cnNumber))\s*月\s*(\#(Self.cnNumber))\s*[日號号]?"#, in: text),
           let date = upcoming(month: Self.number(match.group(1) ?? ""), day: Self.number(match.group(2) ?? "")) {
            text.replaceSubrange(match.range, with: " ")
            return DayMatch(date: date)
        }

        // Longest phrases first: "day after tomorrow" before "tomorrow", 大後天 before 後天.
        let relative: [(pattern: String, days: Int, evening: Bool)] = [
            (#"\bday after tomorrow\b"#, 2, false),
            ("大後天|大后天", 3, false),
            ("後天|后天", 2, false),
            (#"\btomorrow\s+(?:night|evening)\b|明晚"#, 1, true),
            (#"\btomorrow\b|明天|明日"#, 1, false),
            (#"\btonight\b|今晚"#, 0, true),
            (#"\btoday\b|今天|今日"#, 0, false)
        ]
        for rule in relative {
            if let match = Self.match(rule.pattern, in: text) {
                text.replaceSubrange(match.range, with: " ")
                return DayMatch(date: offset(rule.days, from: today), evening: rule.evening)
            }
        }

        // "friday", "next mon"
        let english = #"\b(next\s+|this\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|wed|thu(?:rs?)?|fri|sat|sun)\b"#
        if let match = Self.match(english, in: text), let weekday = Self.englishWeekday(match.group(2)) {
            text.replaceSubrange(match.range, with: " ")
            let isNext = (match.group(1) ?? "").lowercased().hasPrefix("next")
            return weekdayMatch(weekday, weeksAhead: isNext ? 1 : nil)
        }
        // 週五, 下週一, 星期天
        if let match = Self.match("(下下|下|這|这|本)?\\s*(?:週|周|星期|禮拜|礼拜)([一二三四五六日天])", in: text),
           let weekday = Self.chineseWeekday(match.group(2)) {
            text.replaceSubrange(match.range, with: " ")
            let weeksAhead: Int?
            switch match.group(1) ?? "" {
            case "下下": weeksAhead = 2
            case "下": weeksAhead = 1
            case "": weeksAhead = nil
            default: weeksAhead = 0 // 這週 / 本週
            }
            return weekdayMatch(weekday, weeksAhead: weeksAhead)
        }
        return nil
    }

    /// "today", "tomorrow" or "Wed, Oct 15".
    func label(for day: Date) -> String {
        if calendar.isDate(day, inSameDayAs: today) { return "today" }
        if calendar.isDate(day, inSameDayAs: offset(1, from: today)) { return "tomorrow" }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = clock.timeZone
        return day.formatted(style)
    }

    private func offset(_ days: Int, from base: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: base) ?? base.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// `weeksAhead` nil = next occurrence on or after today; otherwise that weekday in the week `weeksAhead` from now.
    private func weekdayMatch(_ weekday: Int, weeksAhead: Int?) -> DayMatch {
        guard let weeksAhead else {
            let ahead = (weekday - calendar.component(.weekday, from: today) + 7) % 7
            return DayMatch(date: offset(ahead, from: today), rollsForward: ahead == 0)
        }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return DayMatch(date: offset(7 * weeksAhead + weekday - 1, from: weekStart))
    }

    private func upcoming(monthName: String?, day: String?) -> Date? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let monthName, let index = names.firstIndex(of: String(monthName.lowercased().prefix(3))) else { return nil }
        return upcoming(month: index + 1, day: day.flatMap { Int($0) })
    }

    /// This year's date, or next year's if it has already passed.
    private func upcoming(month: Int?, day: Int?) -> Date? {
        guard let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let year = calendar.component(.year, from: today)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        return date < today ? calendar.date(from: DateComponents(year: year + 1, month: month, day: day)) : date
    }

    private static func englishWeekday(_ token: String?) -> Int? {
        guard let token else { return nil }
        let codes = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"] // Calendar weekday 1 = Sunday
        return codes.firstIndex(of: String(token.lowercased().prefix(3))).map { $0 + 1 }
    }

    private static func chineseWeekday(_ token: String?) -> Int? {
        let weekdays: [String: Int] = ["日": 1, "天": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7]
        return weekdays[token ?? ""]
    }

    // MARK: Title

    /// What is left after the time and day tokens were removed, minus filler words at either end.
    static func title(from leftover: String) -> String {
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let leading: Set<String> = ["add", "schedule", "create", "book", "set", "up", "put", "please", "remind", "me",
                                    "to", "at", "on", "for", "in", "by", "from", "this", "next", "and", "a", "an"]
        let trailing: Set<String> = ["at", "on", "for", "in", "by", "from", "to", "this", "next", "and", "the", "of",
                                     "around", "about", "every", "each"]
        func key(_ word: String) -> String { word.lowercased().trimmingCharacters(in: trim) }

        var words = leftover.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while let first = words.first, key(first).isEmpty || leading.contains(key(first)) { words.removeFirst() }
        while let last = words.last, key(last).isEmpty || trailing.contains(key(last)) { words.removeLast() }

        var title = words.joined(separator: " ").trimmingCharacters(in: trim)
        let chinesePrefixes = ["幫我", "帮我", "提醒我", "請", "请", "新增", "安排", "的"]
        while let prefix = chinesePrefixes.first(where: { title.hasPrefix($0) }) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: trim)
        }
        guard let first = title.first else { return "" }
        return first.isLowercase ? first.uppercased() + title.dropFirst() : title
    }

    // MARK: Helpers

    /// "14" → 14, "兩" → 2, "十二" → 12, "三十" → 30.
    static func number(_ token: String) -> Int? {
        if let value = Int(token) { return value }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "两": 2, "三": 3,
                                        "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let characters = Array(token)
        guard !characters.isEmpty else { return nil }
        if let ten = characters.firstIndex(of: "十") {
            let tens: Int? = ten == 0 ? 1 : (ten == 1 ? digits[characters[0]] : nil)
            let ones: Int? = ten == characters.count - 1 ? 0 : (ten == characters.count - 2 ? digits[characters[ten + 1]] : nil)
            guard let tens, let ones else { return nil }
            return tens * 10 + ones
        }
        var value = 0
        for character in characters {
            guard let digit = digits[character] else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    /// First case-insensitive match with its capture groups (nil for groups that did not participate).
    static func match(_ pattern: String, in text: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range, in: text) else { return nil }
        let groups = (0..<result.numberOfRanges).map { index -> String? in
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
        return RegexMatch(range: range, groups: groups)
    }
}
