import Foundation

/// Offline stand-in for `ScheduleAssistant` in demo mode: no Google account, no Gemini key, no network.
/// Keyword heuristics cover the artboard flows (long-term plan, "push it 30 min", delete, agenda,
/// "title + day + time" capture, and "加個備註：…" notes). Every write goes to the local `SharedStore` only.
///
/// Plans follow the same review loop as the real assistant: a goal produces a `PlanDraft` (nothing written);
/// while it is pending, approval words add it, abandonment words drop it and anything else is read as a
/// change request ("make it 7am", "MWF", "45 min", "start next Monday") that produces the next revision.
///
/// Like Gemini, the demo writes its own sentences (plan summary, what a revision changed, follow-up questions)
/// in the language the user typed: Chinese for Chinese input, English otherwise. Shared templates
/// (`ReplyFormatter`, the demo note) follow the device language through the String Catalog.
actor DemoAssistant: ScheduleAssisting {
    typealias Reply = ScheduleAssistant.Reply

    static var demoNote: String { String(localized: "Demo mode: nothing was written to Google Calendar.") }

    private enum Proposal { case plan, events }

    private let store: SharedStore
    private let preferences: PreferencesStore
    private let fixedClock: WallClock?
    private let fixedPolicy: ReminderPolicy?
    private let rescheduleReminders: @Sendable (SharedStore) async -> Void
    /// Title and day from a "what time?" question, so tapping the "14:00" suggestion completes that event.
    private var pendingDraft: (title: String, day: Date?)?
    /// Which proposal was shown last, so "好" approves the newer of a draft plan and pending events.
    private var lastProposal: Proposal?
    /// The event this conversation last added, moved or noted: "加個備註：帶護照" without naming one goes there.
    private var lastEventID: String?

    /// - Parameters:
    ///   - clock: nil = Settings › Time zone and "Week starts on", read per request.
    ///   - policy: nil = the reminder defaults in Settings, read per request.
    ///   - preferences: where "from now on…" changes are written. Unit tests pass a temporary store.
    ///   - rescheduleReminders: runs after every write. Unit tests pass a no-op because a hostless
    ///     test bundle has no notification center.
    init(store: SharedStore = .shared,
         clock: WallClock? = nil,
         policy: ReminderPolicy? = nil,
         preferences: PreferencesStore = .shared,
         rescheduleReminders: @escaping @Sendable (SharedStore) async -> Void = { store in
             await ReminderScheduler.shared.reschedule(store: store)
         }) {
        self.store = store
        self.preferences = preferences
        self.fixedClock = clock
        self.fixedPolicy = policy
        self.rescheduleReminders = rescheduleReminders
    }

    // Read per use, so a change in Settings or by voice applies at once.
    private var settings: AppPreferences { preferences.current() }

    private var clock: WallClock {
        fixedClock ?? WallClock(timeZone: settings.timeZone, firstWeekday: settings.firstWeekday)
    }

    private var mapper: CalendarEventMapper {
        let current = settings
        return CalendarEventMapper(clock: clock,
                                   policy: fixedPolicy ?? ReminderPolicy(preferences: current),
                                   defaultEventMinutes: current.defaultEventMinutes)
    }

    private var planBuilder: PlanDraftBuilder { PlanDraftBuilder(mapper: mapper) }

    func handle(_ utterance: String, focusEventID: String? = nil, now: Date = Date()) async throws -> Reply {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let parser = DemoParser(clock: clock, now: now)
        let language = DemoLanguage.of(text, fallback: .device)
        let pending = pendingDraft
        pendingDraft = nil

        // "加個備註：…" goes first: the note itself may say anything ("以後都要帶護照", "move the meeting to 3pm").
        // "From now on…" comes next, so "8 點前不要提醒我" never becomes an 08:00 event.
        // A pending draft plan gets first look after that; it hands back anything clearly about other events.
        // Shift runs next: it only claims an utterance with a move word plus an amount (or a time and a focus
        // event), so "push the gym routine 30 min" is not mistaken for a new plan.
        let reply: Reply
        if let noted = await addNote(text, focusEventID: focusEventID, language: language, parser: parser) {
            reply = noted
        } else if let changed = await preferenceChange(text, lower: lower, language: language, parser: parser) {
            reply = changed
        } else if let decided = try await reviewPendingEvents(text, lower: lower, focusEventID: focusEventID, parser: parser) {
            reply = decided
        } else if let reviewed = try await review(text, lower: lower, focusEventID: focusEventID,
                                                  answersTimeQuestion: pending != nil, language: language, parser: parser) {
            reply = reviewed
        } else if let shifted = await shift(text, lower: lower, focusEventID: focusEventID, language: language, parser: parser) {
            reply = shifted
        } else if Self.isGoal(lower), !Self.isDeleteRequest(lower) { // "delete the gym routine" is not a new plan
            reply = try await plan(text, lower: lower, language: language, parser: parser)
        } else if let deleteReply = await deletion(lower, now: now, language: language) {
            reply = deleteReply
        } else if Self.isAgendaQuery(lower), !parser.containsTime(text) {
            reply = await agenda(text, lower: lower, parser: parser)
        } else {
            reply = await capture(text, pending: pending, language: language, parser: parser)
        }

        if reply.changed { await rescheduleReminders(store) }
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    func confirm(_ pending: ScheduleAssistant.PendingDeletion) async throws -> Reply {
        await store.remove(ids: Set(pending.eventIDs), seriesIDs: Set(pending.eventIDs))
        if let planID = pending.planID { await store.removeNudges(planID: planID) }
        await rescheduleReminders(store)
        var reply = Reply(changed: true)
        reply.append(String(localized: "Deleted \(pending.eventIDs.count) items on this device."))
        reply.append(Self.demoNote)
        return reply
    }

    func commitPlan(_ draft: PlanDraft) async throws -> Reply {
        let reply = try await writePlan(draft)
        await rescheduleReminders(store)
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    func discardPlan(_ draft: PlanDraft) async -> Reply {
        let reply = await discard(draft)
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    func commitPendingEvents(_ batch: PendingEventBatch) async throws -> Reply {
        let reply = try await writeBatch(batch)
        await rescheduleReminders(store)
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    func discardPendingEvents(_ batch: PendingEventBatch) async -> Reply {
        let reply = await discardBatch(batch)
        await store.setLastAssistantLine(reply.text)
        return reply
    }

    // MARK: - (a) Long-term goal → draft plan

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

    /// Builds the same `LongTermPlanArgs` Gemini would send and turns them into a draft for review.
    /// A new goal while a draft is pending replaces it as the next revision.
    private func plan(_ text: String, lower: String, language: DemoLanguage, parser: DemoParser) async throws -> Reply {
        let calendar = clock.calendar
        let startDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: parser.now))!
        let args = DemoPlan.make(goal: text, months: Self.planMonths(lower), startDay: startDay,
                                 startLabel: parser.label(for: startDay, language: language),
                                 language: language, clock: clock)
        let pending = await store.pendingPlan()
        let draft = try planBuilder.draft(from: args,
                                          argsJSON: PlanDraftBuilder.encode(args),
                                          id: pending?.id ?? DemoData.idPrefix + GoogleEventID.newPlanID(),
                                          revision: (pending?.revision ?? 0) + 1,
                                          utterance: pending?.utterance ?? text)
        await store.setPendingPlan(draft)
        lastProposal = .plan
        return reviewReply(for: draft, lead: nil)
    }

    private func reviewReply(for draft: PlanDraft, lead: String?) -> Reply {
        var reply = Reply()
        reply.planDraft = draft
        reply.append(lead)
        reply.append(draft.summary)
        reply.append(ReplyFormatter.planReviewPrompt)
        reply.assumptions = draft.assumptions
        reply.showRange = firstWeek(of: draft)
        return reply
    }

    private func firstWeek(of draft: PlanDraft) -> DateInterval {
        let end = clock.calendar.date(byAdding: .day, value: 7, to: draft.startDate) ?? draft.startDate.addingTimeInterval(7 * 86_400)
        return DateInterval(start: draft.startDate, end: end)
    }

    // MARK: - Draft review: "Add" / "Keep editing"

    /// Nil when no draft is pending or the message is clearly about something else (an agenda question,
    /// another event, a delete by name, a new goal), which then keeps its usual handling.
    private func review(_ text: String,
                        lower: String,
                        focusEventID: String?,
                        answersTimeQuestion: Bool,
                        language inputLanguage: DemoLanguage,
                        parser: DemoParser) async throws -> Reply? {
        // A reminder's "push it 30 min" is about that event, and "14:00" answers the last "What time…?" question.
        guard focusEventID == nil, let draft = await store.pendingPlan() else { return nil }
        if lastProposal == .events, await store.pendingEventBatch() != nil { return nil }
        if answersTimeQuestion, parser.containsTime(text) { return nil }
        // A tapped "07:00" chip has no words: keep talking in the plan's language.
        let language = DemoLanguage.of(text, fallback: DemoLanguage.of(draft.utterance, fallback: inputLanguage))

        var leftover = text
        let edit = parser.extractPlanEdit(from: &leftover)
        guard Self.isPlanTalk(leftover) else {
            let elsewhere = Self.isGoal(lower) || Self.isAgendaQuery(lower) || Self.isDeleteRequest(lower)
                || Self.isMoveRequest(lower) || parser.containsTime(text)
            return elsewhere ? nil : Self.askWhatToChange()
        }
        if !edit.isEmpty { return try await revise(draft, with: edit, language: language, parser: parser) }
        if Self.isAbandonment(lower) { return await discard(draft) }
        if Self.isApproval(lower) { return try await writePlan(draft) }
        if let topic = edit.topic { return Self.followUp(topic, language: language, parser: parser) }
        return Self.askWhatToChange()
    }

    /// Applies the change to the stored args and re-drafts them as the next revision (same id).
    private func revise(_ draft: PlanDraft, with edit: PlanEdit, language: DemoLanguage,
                        parser: DemoParser) async throws -> Reply {
        let calendar = clock.calendar
        var args = try PlanDraftBuilder.decodeArgs(draft.argsJSON)
        var change = PlanChange()

        if let day = edit.startDay, let oldStart = clock.date(args.startDate),
           let delta = calendar.dateComponents([.day], from: oldStart, to: calendar.startOfDay(for: day)).day, delta != 0 {
            DemoPlan.shift(&args, byDays: delta, clock: clock)
            change.start = parser.dayPhrase(for: day, language: language)
        }
        if let weekdays = edit.weekdays {
            DemoPlan.assign(weekdays, to: &args)
            change.weekdays = RecurrenceRule.normalizedWeekdays(weekdays)
        }
        var newTime = edit.time.map { (hour: $0.hour, minute: $0.minute) }
        if newTime == nil, let shift = edit.timeShiftMinutes,
           let current = args.sessions.first.flatMap({ clock.timeOfDay($0.startTime) }) {
            let minutes = min(max(current.hour * 60 + current.minute + shift, 5 * 60), 22 * 60)
            newTime = (hour: minutes / 60, minute: minutes % 60)
        }
        if let newTime {
            let value = String(format: "%02d:%02d", newTime.hour, newTime.minute)
            for index in args.sessions.indices { args.sessions[index].startTime = value }
            change.time = value
        }
        if let minutes = edit.durationMinutes {
            let value = min(max(minutes, 10), 240)
            for index in args.sessions.indices { args.sessions[index].durationMinutes = value }
            change.minutes = value
        } else if let step = edit.durationChange {
            for index in args.sessions.indices {
                args.sessions[index].durationMinutes = min(max(args.sessions[index].durationMinutes + step, 15), 180)
            }
            change.minutes = args.sessions.first?.durationMinutes
        }
        guard !change.isEmpty else {
            return Self.askWhatToChange(lead: language == .chinese ? "草稿已經是這樣了。" : "The draft already looks like that.")
        }

        let start = clock.date(args.startDate) ?? draft.startDate
        DemoPlan.refreshText(&args, startLabel: parser.label(for: start, language: language), language: language, clock: clock)
        let revised = try planBuilder.draft(from: args,
                                            argsJSON: PlanDraftBuilder.encode(args),
                                            id: draft.id,
                                            revision: draft.revision + 1,
                                            utterance: draft.utterance)
        await store.setPendingPlan(revised)
        lastProposal = .plan
        return reviewReply(for: revised, lead: change.sentences(language))
    }

    /// "Add": the reviewed args, expanded locally the way Google would, with real (non-draft) ids.
    private func writePlan(_ draft: PlanDraft) async throws -> Reply {
        let args = try PlanDraftBuilder.decodeArgs(draft.argsJSON)
        let mapped = try mapper.events(fromPlan: args, planID: draft.id, utterance: draft.utterance)
        let events = planBuilder.occurrences(of: mapped, through: planBuilder.previewHorizon(for: draft),
                                             idPrefix: DemoData.idPrefix)
        await store.upsert(events)
        if let nudge = mapper.nudge(from: args, planID: draft.id) { await store.addNudge(nudge) }
        if await store.pendingPlan()?.id == draft.id { await store.setPendingPlan(nil) }

        var reply = Reply(changed: true)
        reply.created = events
        reply.committedPlanID = draft.id
        reply.showRange = firstWeek(of: draft)
        reply.append(String(localized: "Added “\(draft.title)” on this device."))
        reply.append(Self.demoNote)
        return reply
    }

    private func discard(_ draft: PlanDraft) async -> Reply {
        if await store.pendingPlan()?.id == draft.id { await store.setPendingPlan(nil) }
        var reply = Reply()
        reply.discardedPlanID = draft.id
        reply.append(ReplyFormatter.planDiscarded)
        return reply
    }

    private static func askWhatToChange(lead: String? = nil) -> Reply {
        var reply = Reply()
        reply.needsClarification = true
        reply.append(lead)
        reply.append(ReplyFormatter.planEditQuestion)
        reply.suggestions = ReplyFormatter.planEditSuggestions
        return reply
    }

    /// The suggestion chips name a topic without a value ("Change the time"), so ask for the value.
    /// Every suggestion is something `extractPlanEdit` reads back.
    private static func followUp(_ topic: PlanEdit.Topic, language: DemoLanguage, parser: DemoParser) -> Reply {
        var reply = Reply()
        reply.needsClarification = true
        let chinese = language == .chinese
        switch topic {
        case .days:
            reply.append(chinese ? "要練哪幾天？" : "Which days do you want to train?")
            reply.suggestions = chinese ? ["週一、三、五", "平日", "週二、四、六"] : ["Mon · Wed · Fri", "Weekdays", "Tue · Thu · Sat"]
        case .time:
            reply.append(chinese ? "幾點開始？" : "What time should the sessions start?")
            reply.suggestions = ["07:00", "12:30", "18:30"]
        case .start:
            reply.append(chinese ? "要從哪一天開始？" : "When should the plan start?")
            reply.suggestions = (chinese ? ["明天", "下週一"] : ["Tomorrow", "Next Monday"])
                + [parser.firstOfNextMonthLabel(language: language)]
        }
        return reply
    }

    /// True when nothing but plan vocabulary is left once the change tokens were removed: "make it 7am",
    /// "looks good", "cancel the plan", 改成週一三五. "Lunch with Andrew" leaves "lunch" and "andrew".
    private static func isPlanTalk(_ leftover: String) -> Bool {
        var rest = leftover.lowercased().replacingOccurrences(of: "’", with: "'")
        for phrase in chinesePlanPhrases { rest = rest.replacingOccurrences(of: phrase, with: " ") }
        let words = rest.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        return words.allSatisfy { planTalkWords.contains($0) }
    }

    private static func isApproval(_ lower: String) -> Bool {
        let bare = lower.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        let exact: Set<String> = ["ok", "okay", "k", "yes", "yep", "yeah", "yup", "sure", "add", "fine", "great", "perfect",
                                  "nice", "good", "lgtm", "done", "confirm", "好", "好的", "好啊", "可以", "行", "對", "对",
                                  "嗯", "加", "加入", "確定", "确定"]
        if exact.contains(bare) { return true }
        let phrases = ["looks good", "look good", "looks great", "looks fine", "sounds good", "sounds great", "add it",
                       "add this", "add the plan", "add them", "add to my calendar", "add to calendar", "go ahead", "do it",
                       "confirm", "加入", "加進", "加进", "確定", "确定", "沒問題", "没问题", "就這樣", "就这样", "可以了"]
        return phrases.contains { lower.contains($0) }
    }

    private static func isAbandonment(_ lower: String) -> Bool {
        let phrases = ["cancel", "discard", "forget it", "forget about it", "never mind", "nevermind", "scrap", "drop it",
                       "drop the plan", "don't add", "dont add", "do not add", "don't want", "dont want", "no thanks",
                       "no thank you", "not interested", "abandon", "delete", "remove", "不要", "算了", "取消", "放棄", "放弃",
                       "刪掉", "删掉", "刪除", "删除", "不用了"]
        return phrases.contains { lower.replacingOccurrences(of: "’", with: "'").contains($0) }
    }

    private static let planTalkWords: Set<String> = [
        // filler
        "a", "an", "the", "it", "its", "it's", "them", "they", "this", "that", "these", "those", "my", "me", "i", "i'd",
        "i'm", "we", "us", "let's", "lets", "you", "your", "can", "could", "would", "will", "should", "please", "pls",
        "just", "only", "maybe", "instead", "rather", "prefer", "like", "want", "need", "do", "does", "be", "is", "are",
        "to", "at", "on", "in", "for", "from", "of", "by", "with", "and", "or", "but", "so", "then", "also", "too",
        "every", "each", "per", "all", "bit", "little", "lot", "more", "less", "much", "than", "now", "how", "about",
        "what", "which", "when", "hmm", "um", "uh", "well", "actually", "thanks", "thank", "oh", "hey", "again",
        // plan vocabulary
        "plan", "draft", "session", "sessions", "workout", "workouts", "training", "train", "gym", "exercise",
        "exercises", "routine", "week", "weeks", "weekly", "day", "days", "time", "times", "date", "start", "starts",
        "starting", "begin", "begins", "beginning", "different", "another", "other", "new", "later", "earlier",
        "shorter", "longer", "make", "change", "move", "switch", "set", "put", "shift", "push", "delay", "postpone",
        "edit", "update", "adjust", "keep", "editing", "o'clock", "oclock", "after", "before", "work",
        // approval / abandonment
        "looks", "look", "good", "great", "perfect", "fine", "nice", "ok", "okay", "k", "yes", "yeah", "yep", "yup",
        "sure", "add", "confirm", "go", "ahead", "sounds", "lgtm", "right", "alright", "done", "no", "not", "don't",
        "dont", "nope", "cancel", "discard", "forget", "never", "mind", "nevermind", "scrap", "drop", "abandon",
        "delete", "remove", "interested", "calendar"
    ]

    /// Stripped longest first, so 不要了 goes before 不要 and 訓練日 (the 換訓練日 chip) before 訓練.
    private static let chinesePlanPhrases: [String] = [
        "訓練日", "训练日", "沒問題", "没问题", "就這樣", "就这样", "不要了", "不用了", "可以了", "改成", "改到", "換成",
        "换成", "調整", "调整", "時長", "时长", "訓練", "训练", "運動", "运动", "健身", "計畫", "計劃", "计划", "時間",
        "时间", "日期", "開始", "开始", "每次",
        "請", "请", "幫我", "帮我", "我想", "我要", "可以", "好的", "好啊", "加入", "加進", "加进", "確定", "确定", "不要",
        "算了", "取消", "放棄", "放弃", "刪掉", "删掉", "刪除", "删除", "一點", "一点", "還是", "还是", "然後", "然后",
        "這個", "这个", "好", "加", "行", "對", "对", "嗯", "吧", "了", "的", "改", "換", "换", "從", "从", "再", "都",
        "就", "也", "在", "到", "成", "練", "练", "課", "课", "每週", "每周", "每"
    ].sorted { $0.count > $1.count }

    private static func isMoveRequest(_ lower: String) -> Bool {
        let chineseMoveWords = ["延後", "延后", "推遲", "推迟", "晚一點", "晚一点", "晚點", "晚点", "改到", "移到", "延到"]
        return DemoParser.match(#"\b(?:push|delay|later|postpone|move|reschedule)\b"#, in: lower) != nil
            || chineseMoveWords.contains(where: { lower.contains($0) })
    }

    // MARK: - (c) "push it 30 min"

    private func shift(_ text: String, lower: String, focusEventID: String?, language: DemoLanguage,
                       parser: DemoParser) async -> Reply? {
        guard Self.isMoveRequest(lower) else { return nil }
        let delta = Self.relativeMinutes(lower)
        var leftover = text
        var newTime: DemoParser.TimeOfDay?
        // An absolute "push it to 4pm" only makes sense when a reminder says which event "it" is.
        if delta == nil, focusEventID != nil { newTime = parser.extractTime(from: &leftover) }
        guard delta != nil || newTime != nil else { return nil }

        guard let event = await target(lower: lower, focusEventID: focusEventID, now: parser.now) else {
            var reply = Reply()
            reply.needsClarification = true
            reply.append(language == .chinese ? "要移動哪個行程？例如「團隊會議延後 30 分鐘」。"
                                              : "Which event should I move? Try “push the team sync 30 min”.")
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
        lastEventID = updated.id

        var reply = Reply()
        reply.changed = true
        reply.showRange = DateInterval(start: clock.calendar.startOfDay(for: updated.start), duration: 86_400)
        reply.append(ReplyFormatter.updated(updated, clock: clock))
        return reply
    }

    fileprivate static func relativeMinutes(_ lower: String) -> Int? {
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

    private static func isDeleteRequest(_ lower: String) -> Bool {
        ["delete", "cancel", "remove", "刪除", "删除", "取消"].contains(where: { lower.contains($0) })
    }

    private func deletion(_ lower: String, now: Date, language: DemoLanguage) async -> Reply? {
        guard Self.isDeleteRequest(lower) else { return nil }
        let snapshot = await store.snapshot()
        let events = snapshot.events.sorted { $0.start < $1.start }
        var reply = Reply()

        let wantsPlan = ["plan", "計畫", "计划", "計劃", "routine"].contains { lower.contains($0) }
        if wantsPlan, let planID = snapshot.nudges.last?.planID ?? events.last(where: { $0.planID != nil })?.planID {
            let ids = events.filter { $0.planID == planID }.map(\.id)
            reply.pendingDeletion = ScheduleAssistant.PendingDeletion(eventIDs: ids, planID: planID,
                                                                      summary: String(localized: "the plan (\(ids.count) items)"))
        } else {
            let named = events.filter { $0.end > now && Self.mentions(lower, $0.title) }
            guard let first = named.first else {
                reply.append(language == .chinese ? "找不到這個行程。請說出名稱，例如「取消看牙醫」。"
                                                  : "I couldn't find that event. Try naming it, like “cancel the dentist”.")
                return reply
            }
            let everyOccurrence = DemoParser.match(#"\b(?:all|every)\b"#, in: lower) != nil
                || lower.contains("所有") || lower.contains("全部")
            let chosen = everyOccurrence && first.seriesID != nil ? named.filter { $0.seriesID == first.seriesID } : [first]
            let summary = chosen.count == 1
                ? "\(first.title) · \(ReplyFormatter.when(first, clock: clock))"
                : String(localized: "\(first.title) (\(chosen.count) times)")
            reply.pendingDeletion = ScheduleAssistant.PendingDeletion(eventIDs: chosen.map(\.id), planID: nil, summary: summary)
        }
        if let summary = reply.pendingDeletion?.summary { reply.append(ReplyFormatter.deletePrompt(summary)) }
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
        if ["week", "這週", "这周", "本週", "本周"].contains(where: { lower.contains($0) }),
           let week = calendar.dateInterval(of: .weekOfYear, for: parser.now) {
            interval = week
        } else {
            var leftover = text
            let day = parser.extractDay(from: &leftover)?.date ?? calendar.startOfDay(for: parser.now)
            interval = DateInterval(start: day, end: calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400))
        }
        let events = await store.events(in: interval)
        let digest = AgendaDigest(range: interval,
                                  title: ReplyFormatter.agendaTitle(for: interval, now: parser.now, clock: clock),
                                  events: events)
        var reply = Reply()
        reply.showRange = interval
        reply.agenda = digest
        reply.append(ReplyFormatter.agenda(digest, clock: clock))
        return reply
    }

    // MARK: - (d) "Lunch with Andrew tomorrow 1pm" · (e) no time → ask

    private func capture(_ text: String, pending: (title: String, day: Date?)?, language: DemoLanguage,
                         parser: DemoParser) async -> Reply {
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
        if title.isEmpty { title = language == .chinese ? "新行程" : "New event" }

        var reply = Reply()
        guard let time else {
            pendingDraft = (title: title, day: day)
            let when = day.map { parser.dayPhrase(for: $0, language: language) }
            reply.needsClarification = true
            reply.suggestions = ["09:00", "14:00", "19:00"]
            switch language {
            case .chinese:
                reply.append("\(when.map { $0 + "的" } ?? "")「\(title)」要排在幾點？")
            case .english:
                reply.append("What time should I schedule “\(title)”\(when.map { " " + $0 } ?? "")?")
            }
            return reply
        }

        var hour = time.hour
        if dayMatch?.evening == true, !time.hasMeridiem, hour < 12 { hour += 12 }
        guard var start = clock.combine(day: day ?? calendar.startOfDay(for: now), time: (hour: hour, minute: time.minute)) else {
            reply.append(language == .chinese ? "看不懂這個時間。" : "I couldn't work out that time.")
            return reply
        }
        if start < now, day == nil {
            start = calendar.date(byAdding: .day, value: 1, to: start) ?? start // "3pm" said at 5pm means tomorrow
        } else if start < now, dayMatch?.rollsForward == true {
            start = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        }

        let kind = CalendarEventMapper.inferKind(title)
        let minutes = Self.defaultMinutes(for: kind, settings: settings)
        let dayInterval = DateInterval(start: calendar.startOfDay(for: start), duration: 86_400)
        let sameDay = await store.events(in: dayInterval)

        if settings.autonomy == .askFirst {
            return await proposeBatch(title: title, start: start, minutes: minutes, kind: kind, utterance: text,
                                      now: now, dayInterval: dayInterval, sameDay: sameDay)
        }

        let event = makeEvent(id: DemoData.idPrefix + "chat-" + UUID().uuidString.prefix(8).lowercased(),
                              title: title, start: start, minutes: minutes, kind: kind, utterance: text)
        await store.upsert([event])
        lastEventID = event.id

        reply.changed = true
        reply.created = [event]
        reply.addedEvents = [event]
        reply.showRange = dayInterval
        reply.append(ReplyFormatter.confirmation(for: [event], clock: clock))
        reply.append(ReplyFormatter.conflicts([event], against: sameDay))
        reply.append(Self.demoNote)
        await noteHiddenTarget(Self.demoTarget(for: settings), in: &reply)
        return reply
    }

    /// Kinds that get the default length from Settings (events, routines); tasks and deadlines keep an hour here,
    /// as the demo always did.
    private static func defaultMinutes(for kind: ScheduleEvent.Kind, settings: AppPreferences) -> Int {
        switch kind {
        case .event, .routine: settings.defaultEventMinutes
        case .task, .deadline: 60
        }
    }

    /// A captured event in the calendar new events go to (Settings or "以後用學校帳號").
    private func makeEvent(id: String, title: String, start: Date, minutes: Int, kind: ScheduleEvent.Kind,
                           utterance: String) -> ScheduleEvent {
        let target = Self.demoTarget(for: settings)
        return ScheduleEvent(
            id: id,
            seriesID: nil,
            title: title,
            start: start,
            end: start.addingTimeInterval(TimeInterval(minutes) * 60),
            isAllDay: false,
            kind: kind,
            colorHex: DemoData.colorHex(for: kind),
            location: nil,
            meetURL: nil,
            notes: CalendarEventMapper.provenancePrefix + utterance,
            reminderMinutes: nil,
            planID: nil,
            htmlLink: nil,
            isCompleted: false,
            accountID: target.accountID,
            calendarID: target.calendarID
        )
    }

    /// The sample calendar new events go to: the one chosen in Settings or by voice, else the personal calendar.
    static func demoTarget(for settings: AppPreferences) -> CalendarRef {
        if let chosen = settings.defaultCalendar, demoWritableCalendars.contains(where: { $0.id == chosen }) { return chosen }
        return DemoData.defaultCalendar
    }

    private static var demoWritableCalendars: [CalendarInfo] {
        DemoData.accounts.flatMap(\.calendars).filter(\.isWritable)
    }

    /// Sample calendars can be hidden in the drawer too: the confirmation then says where the event went, with
    /// Show. Nothing is redirected. Without an account store (unit tests) every calendar counts as shown.
    private func noteHiddenTarget(_ target: CalendarRef, in reply: inout Reply) async {
        guard let calendar = await store.accounts?.calendar(target) else { return }
        ScheduleAssistant.noteHidden(calendar, in: &reply)
    }

    // MARK: - "Ask me first": pending events

    /// Same as capture, but nothing is written: the event waits on a card with Add and Edit.
    private func proposeBatch(title: String, start: Date, minutes: Int, kind: ScheduleEvent.Kind, utterance: String,
                              now: Date, dayInterval: DateInterval, sameDay: [ScheduleEvent]) async -> Reply {
        let draft = EventDraft(title: title, start: clock.promptDateTimeString(start), durationMinutes: minutes,
                               kind: kind.rawValue)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let argsJSON = (try? encoder.encode(CreateEventsArgs(events: [draft]))) ?? Data("{\"events\":[]}".utf8)
        let id = PendingEventBatch.newID()
        var preview = makeEvent(id: PendingEventBatch.previewID(batchID: id, index: 0), title: title, start: start,
                                minutes: minutes, kind: kind, utterance: utterance)
        // Previews belong to no calendar, like plan previews: always drawn, never hidden.
        preview.accountID = nil
        preview.calendarID = nil
        let batch = PendingEventBatch(id: id, createdAt: now, utterance: utterance, seed: id,
                                      argsJSON: argsJSON, previewEvents: [preview])
        await store.setPendingEventBatch(batch)
        lastProposal = .events

        var reply = Reply()
        reply.pendingEvents = batch
        reply.showRange = dayInterval
        reply.append(ReplyFormatter.pendingEventsSummary(batch, clock: clock))
        reply.append(ReplyFormatter.conflicts([preview], against: sameDay))
        reply.append(ReplyFormatter.pendingEventsPrompt)
        return reply
    }

    /// "Add": the batch's args, written locally with ids derived from the batch (a second Add changes nothing).
    private func writeBatch(_ batch: PendingEventBatch) async throws -> Reply {
        let args = try ScheduleAssistant.decodeCreateArgs(batch.argsJSON)
        let suffix = batch.id.hasPrefix(PendingEventBatch.idPrefix)
            ? String(batch.id.dropFirst(PendingEventBatch.idPrefix.count)) : batch.id
        var events: [ScheduleEvent] = []
        for (index, draft) in args.events.prefix(20).enumerated() {
            guard let start = clock.dateTime(draft.start) else { throw MappingError.invalidDate(draft.start) }
            let kind = ScheduleEvent.Kind(rawValue: draft.kind ?? "") ?? .event
            events.append(makeEvent(id: DemoData.idPrefix + "chat-\(suffix)-\(index)", title: draft.title, start: start,
                                    minutes: draft.durationMinutes ?? Self.defaultMinutes(for: kind, settings: settings),
                                    kind: kind, utterance: batch.utterance))
        }
        await store.upsert(events)
        if let last = events.last { lastEventID = last.id }
        if await store.pendingEventBatch()?.id == batch.id { await store.setPendingEventBatch(nil) }
        if lastProposal == .events { lastProposal = nil }

        var reply = Reply(changed: true)
        reply.created = events
        reply.addedEvents = events
        reply.committedEventBatchID = batch.id
        reply.showRange = ScheduleAssistant.dayRange(of: events, clock: clock)
        reply.append(ReplyFormatter.confirmation(for: events, clock: clock))
        reply.append(Self.demoNote)
        await noteHiddenTarget(Self.demoTarget(for: settings), in: &reply)
        return reply
    }

    private func discardBatch(_ batch: PendingEventBatch) async -> Reply {
        if await store.pendingEventBatch()?.id == batch.id { await store.setPendingEventBatch(nil) }
        if lastProposal == .events { lastProposal = nil }
        var reply = Reply()
        reply.discardedEventBatchID = batch.id
        reply.append(ReplyFormatter.pendingEventsDiscarded)
        return reply
    }

    /// While events wait for Add, a bare "好" / "add them" adds them and "不要" / "never mind" drops them. Anything
    /// else keeps its usual handling (and a new capture replaces the batch).
    private func reviewPendingEvents(_ text: String, lower: String, focusEventID: String?,
                                     parser: DemoParser) async throws -> Reply? {
        guard focusEventID == nil, let batch = await store.pendingEventBatch() else { return nil }
        if await store.pendingPlan() != nil, lastProposal != .events { return nil }
        // "加入明天 3 點開會" is a new event, not an approval.
        var leftover = text
        let namesWhen = parser.containsTime(text) || parser.extractDay(from: &leftover) != nil
        if !namesWhen, Self.isApproval(lower) { return try await writeBatch(batch) }
        let bare = lower.replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let abandonment: Set<String> = ["no", "nope", "discard", "cancel", "never mind", "nevermind", "don't add",
                                        "dont add", "forget it", "不要", "不要了", "算了", "取消", "不用了"]
        if abandonment.contains(bare) { return await discardBatch(batch) }
        return nil
    }
}

// MARK: - (g) "加個備註：帶護照" / "add a note: bring passport"

extension DemoAssistant {
    /// Adds a note below an event's notes: the event the reminder is about, else the one the words before the
    /// note name ("add a note to the dentist: …", "看牙醫加個備註：…"), else the one this conversation last added,
    /// moved or noted. nil when the utterance is not a note request.
    fileprivate func addNote(_ text: String, focusEventID: String?, language: DemoLanguage,
                             parser: DemoParser) async -> Reply? {
        guard let request = Self.noteRequest(text) else { return nil }
        // "明天 3 點開會，備註：帶簡報" describes a new event rather than a note on an existing one.
        guard !parser.containsTime(request.target) else { return nil }
        let now = parser.now
        guard let event = await noteTarget(request.target.lowercased(), focusEventID: focusEventID, now: now) else {
            var reply = Reply()
            reply.needsClarification = true
            reply.append(language == .chinese ? "要把備註加到哪個行程？例如「看牙醫加個備註：帶健保卡」。"
                                              : "Which event is the note for? Try “add a note to the dentist: bring the forms”.")
            return reply
        }
        var updated = event
        updated.notes = EventNotes.appending(request.note, to: event.notes)
        await store.upsert([updated])
        lastEventID = updated.id

        var reply = Reply()
        reply.changed = true
        reply.showRange = DateInterval(start: clock.calendar.startOfDay(for: updated.start), duration: 86_400)
        reply.append(language == .chinese ? "已在「\(updated.title)」加上備註：\(request.note)"
                                          : "Added a note to “\(updated.title)”: \(request.note)")
        reply.append(Self.demoNote)
        return reply
    }

    private func noteTarget(_ words: String, focusEventID: String?, now: Date) async -> ScheduleEvent? {
        if let focusEventID, let event = await store.event(id: focusEventID), !event.isDraft { return event }
        let upcoming = await store.events(in: DateInterval(start: now, duration: 60 * 86_400))
            .filter { !$0.isDraft && $0.end > now }
        if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let named = upcoming.first(where: { Self.mentions(words, $0.title) }) {
            return named
        }
        if let lastEventID, let event = await store.event(id: lastEventID), !event.isDraft, event.end > now { return event }
        return nil
    }

    /// The note and the words before it that may name the event, from "加個備註：帶護照", "看牙醫加備註 帶健保卡",
    /// "備註：帶護照", "add a note: bring passport", "add a note to the dentist: bring the forms",
    /// "add a note saying bring passport" or "note: bring passport".
    static func noteRequest(_ text: String) -> (note: String, target: String)? {
        let patterns = [
            #"^(.*?)(?:加|新增|寫|写|補|补|記|记)(?:個|个|一個|一个|一下|上|條|条|一條|一条)?\s*(?:備註|备注)\s*[：:，,]?\s*(.+)$"#,
            #"^(.*?)(?:備註|备注)\s*[：:]\s*(.+)$"#,
            #"^(?:please\s+)?(?:add|write|put|leave)\s+(?:a\s+)?note(?:\s+(?:to|on|for)\s+(.+?))?\s*[:：]\s*(.+)$"#,
            #"^(?:please\s+)?(?:add|write|put|leave)\s+(?:a\s+)?note(?:\s+(?:to|on|for)\s+(.+?))?\s+(?:saying|that says|that)\s+(.+)$"#,
            #"^()\s*notes?\s*[:：]\s*(.+)$"#
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in patterns {
            guard let match = DemoParser.match(pattern, in: trimmed) else { continue }
            let note = (match.group(2) ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "。．.!！「」“”\"")))
            guard !note.isEmpty else { continue }
            return (note, match.group(1) ?? "")
        }
        return nil
    }
}

// MARK: - (f) "From now on…": preferences by voice

extension DemoAssistant {
    /// Lasting instructions the demo understands offline, applied through the same `PreferencesStore.apply` as
    /// Gemini's update_preferences (validation, ledger, Undo). Nil for anything else, which keeps its usual handling.
    fileprivate func preferenceChange(_ text: String, lower: String, language: DemoLanguage,
                                      parser: DemoParser) async -> Reply? {
        guard let intent = DemoPreferenceIntent.parse(text, lower: lower, settings: settings, parser: parser) else {
            return nil
        }
        let result = await preferences.apply(intent.requests, source: .voice(utterance: text), resolveCalendar: { value in
            DemoPreferenceIntent.calendar(matching: value).map { CalendarChoice(ref: $0.id, label: $0.promptLabel) }
        })
        // No demo note: nothing would have gone to Google either way.
        var reply = Reply()
        ScheduleAssistant.describe(result.receipt, rejected: result.rejected, summary: intent.sentence(language),
                                   in: &reply)
        if ScheduleAssistant.touchesNotifications(result.receipt) { await rescheduleReminders(store) }
        return reply
    }
}

/// One recognised lasting instruction: the update_preferences changes it means and what to say back.
private struct DemoPreferenceIntent {
    var requests: [PreferenceChangeRequest]
    var english: String
    var chinese: String

    func sentence(_ language: DemoLanguage) -> String { language == .chinese ? chinese : english }

    static func parse(_ text: String, lower: String, settings: AppPreferences, parser: DemoParser) -> DemoPreferenceIntent? {
        let lower = lower.replacingOccurrences(of: "’", with: "'")
        var leftover = text
        // A date or a time of day makes it about one event ("remind me 2 hours before gym tomorrow").
        let namesWhen = parser.extractDay(from: &leftover) != nil || parser.containsTime(text)
        return quietHours(lower, settings: settings)
            ?? reminderRule(lower, settings: settings, namesWhen: namesWhen)
            ?? defaultCalendar(lower, namesWhen: namesWhen)
            ?? defaultDuration(text, lower: lower, namesWhen: namesWhen)
            ?? replyLanguage(lower)
            ?? autonomy(lower)
    }

    // MARK: Vocabulary

    private static let lastingMarkers = [
        "以後", "以后", "從現在開始", "从现在开始", "從今以後", "从今以后", "今後", "今后", "別再", "别再", "不要再", "每次",
        "一律", "總是", "总是", "永遠", "永远", "from now on", "always", "never", "don't ever", "do not ever",
        "every time", "going forward", "in future", "in the future", "by default"
    ]

    private static func hasLastingMarker(_ lower: String) -> Bool {
        lastingMarkers.contains { lower.contains($0) }
    }

    /// "不要提醒", "別再提前一天提醒", "don't remind", "no reminders", "never notify"; not "別忘了提醒我".
    private static func isNegative(_ lower: String) -> Bool {
        DemoParser.match(#"(?:不要|不用|別|别|勿|不想|停止)(?!忘)[^，。,.!?！？]{0,10}?(?:提醒|通知|吵)"#, in: lower) != nil
            || DemoParser.match(#"\b(?:don't|dont|do not|never|stop|no)\b.*\b(?:remind|reminders?|notify|notifications?|alerts?|ping)\b"#, in: lower) != nil
    }

    private static func mentionsReminder(_ lower: String) -> Bool {
        ["提醒", "通知"].contains { lower.contains($0) }
            || DemoParser.match(#"\b(?:remind|reminders?|alerts?|notify|notifications?)\b"#, in: lower) != nil
    }

    /// The kind of activity a reminder rule is about.
    private static func activityKind(_ lower: String) -> ScheduleEvent.Kind? {
        let kinds: [(ScheduleEvent.Kind, String)] = [
            (.deadline, #"截止|期限|\bdeadlines?\b|\bdue\b"#),
            (.task, #"待辦|待办|任務|任务|\btasks?\b|\bto-?dos?\b"#),
            (.routine, #"健身|運動|运动|訓練|训练|瑜伽|跑步|例行|\bgym\b|\bworkouts?\b|\btraining\b|\bexercises?\b|\broutines?\b|\byoga\b|\bruns?\b"#),
            (.event, #"會議|会议|開會|开会|行程|約會|约会|\bmeetings?\b|\bappointments?\b|\bevents?\b"#)
        ]
        return kinds.first { DemoParser.match($0.1, in: lower) != nil }?.0
    }

    private static func kindName(_ kind: ScheduleEvent.Kind) -> (english: String, chinese: String) {
        switch kind {
        case .routine: ("workouts and other routines", "健身和例行活動")
        case .event: ("events", "行程")
        case .deadline: ("deadlines", "截止日")
        case .task: ("tasks", "待辦事項")
        }
    }

    /// How long before: "2 小時", "兩小時", "一天", "30 min", "2 hours", "a day".
    private static func leadMinutes(_ lower: String) -> Int? {
        if let match = DemoParser.match(#"(\#(DemoParser.cnNumber))\s*(?:個|个)?\s*(?:天|days?\b)"#, in: lower),
           let days = DemoParser.number(match.group(1) ?? "") {
            return days * 1440
        }
        if DemoParser.match(#"\b(?:a|one)\s+day\b|\bthe day before\b"#, in: lower) != nil { return 1440 }
        if DemoParser.match(#"(?:一|1)\s*(?:個|个)?\s*(?:星期|禮拜|礼拜|週|周)|\b(?:a|one)\s+week\b"#, in: lower) != nil { return 10_080 }
        return DemoAssistant.relativeMinutes(lower)
    }

    private static func amountText(_ minutes: Int) -> (english: String, chinese: String) {
        if minutes >= 1440, minutes % 1440 == 0 {
            let days = minutes / 1440
            return (days == 1 ? "1 day" : "\(days) days", "\(days) 天")
        }
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return (hours == 1 ? "1 hour" : "\(hours) hours", "\(hours) 小時")
        }
        return ("\(minutes) minutes", "\(minutes) 分鐘")
    }

    private static func clock(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    // MARK: Quiet hours: "8 點前不要提醒我", "don't remind me before 8am", "10 點後別提醒我"

    private static func quietHours(_ lower: String, settings: AppPreferences) -> DemoPreferenceIntent? {
        guard isNegative(lower) else { return nil }
        let period = #"(凌晨|清晨|早上|早晨|上午|中午|下午|傍晚|晚上)?\s*"#
        let clockTime = #"(\#(DemoParser.cnNumber))\s*[點点](?:\s*(半|\#(DemoParser.cnNumber))\s*分?)?\s*"#
        let quiet = settings.quietHours
        if let match = DemoParser.match(period + clockTime + "(?:以前|之前|前)", in: lower),
           let time = chineseMinute(match, evening: false) {
            return before(time, quiet: quiet)
        }
        if let match = DemoParser.match(period + clockTime + "(?:以後|以后|之後|之后|後|后)", in: lower),
           let time = chineseMinute(match, evening: true) {
            return after(time, quiet: quiet)
        }
        let english = #"\s+(\d{1,2})(?:[:.]([0-5]\d))?\s*(a\.?m\.?|p\.?m\.?)?"#
        if let match = DemoParser.match(#"\bbefore"# + english, in: lower), let time = englishMinute(match, evening: false) {
            return before(time, quiet: quiet)
        }
        if let match = DemoParser.match(#"\bafter"# + english, in: lower), let time = englishMinute(match, evening: true) {
            return after(time, quiet: quiet)
        }
        return nil
    }

    /// Reminders before `end` arrive silently, from the current start (22:00 while quiet hours are off).
    private static func before(_ end: Int, quiet: QuietHours) -> DemoPreferenceIntent {
        let start = quiet.isEnabled ? quiet.startMinute : 22 * 60
        let time = clock(end)
        return DemoPreferenceIntent(
            requests: [PreferenceChangeRequest(key: .quietHours, value: "\(clock(start))-\(time)")],
            english: "OK. From now on, reminders before \(time) arrive silently.",
            chinese: "好的，以後 \(time) 前的提醒會靜音送達。")
    }

    /// Reminders after `start` arrive silently, until the current end (07:00 while quiet hours are off).
    private static func after(_ start: Int, quiet: QuietHours) -> DemoPreferenceIntent {
        let end = quiet.isEnabled ? quiet.endMinute : 7 * 60
        let time = clock(start)
        return DemoPreferenceIntent(
            requests: [PreferenceChangeRequest(key: .quietHours, value: "\(time)-\(clock(end))")],
            english: "OK. From now on, reminders after \(time) arrive silently.",
            chinese: "好的，以後 \(time) 後的提醒會靜音送達。")
    }

    /// Groups: 1 period, 2 hour, 3 minutes or 半. A bare hour "after" something means the evening (10 點後 = 22:00).
    private static func chineseMinute(_ match: DemoParser.RegexMatch, evening: Bool) -> Int? {
        guard var hour = DemoParser.number(match.group(2) ?? "") else { return nil }
        let minute = match.group(3).map { $0 == "半" ? 30 : (DemoParser.number($0) ?? 0) } ?? 0
        switch match.group(1) ?? "" {
        case "下午", "傍晚", "晚上": if hour < 12 { hour += 12 }
        case "中午": if hour < 6 { hour += 12 }
        case "凌晨", "清晨", "早上", "早晨", "上午": if hour == 12 { hour = 0 }
        default: if evening, (1...11).contains(hour) { hour += 12 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// Groups: 1 hour, 2 minutes, 3 am/pm.
    private static func englishMinute(_ match: DemoParser.RegexMatch, evening: Bool) -> Int? {
        guard var hour = Int(match.group(1) ?? "") else { return nil }
        let minute = Int(match.group(2) ?? "") ?? 0
        if let meridiem = match.group(3)?.lowercased() {
            hour = hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
        } else if evening, (1...11).contains(hour) {
            hour += 12
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    // MARK: Reminder rules: "健身提前 2 小時提醒", "remind me 2 hours before gym", "別再提前一天提醒截止日"

    private static func reminderRule(_ lower: String, settings: AppPreferences, namesWhen: Bool) -> DemoPreferenceIntent? {
        guard !namesWhen, mentionsReminder(lower),
              DemoParser.match(#"提前|之前|前|\bbefore\b|\bahead\b|\bearly\b|\bin advance\b"#, in: lower) != nil,
              let minutes = leadMinutes(lower), (0...40_320).contains(minutes) else { return nil }
        guard let kind = activityKind(lower) ?? (hasLastingMarker(lower) ? .event : nil) else { return nil }
        let key: PreferenceKey = switch kind {
        case .event: .eventReminders
        case .deadline: .deadlineReminders
        case .task: .taskReminders
        case .routine: .routineReminders
        }
        let names = kindName(kind)
        let amount = amountText(minutes)
        if isNegative(lower) {
            let remaining = settings.reminders(for: kind).filter { $0 != minutes }
            let value = remaining.isEmpty ? "none" : remaining.map(String.init).joined(separator: ",")
            return DemoPreferenceIntent(
                requests: [PreferenceChangeRequest(key: key, value: value)],
                english: "OK. From now on, \(names.english) get no reminder \(amount.english) before.",
                chinese: "好的，以後\(names.chinese)不會再提前 \(amount.chinese)提醒。")
        }
        return DemoPreferenceIntent(
            requests: [PreferenceChangeRequest(key: key, value: String(minutes))],
            english: "OK. From now on, \(names.english) get a reminder \(amount.english) before.",
            chinese: "好的，以後\(names.chinese)會提前 \(amount.chinese)提醒。")
    }

    // MARK: Calendar for new events: "以後用學校帳號", "from now on use my school account"

    private static let schoolPattern = #"學校|学校|學生|学生|大學|大学|\bschool\b|\buni\b|\buniversity\b|\bcollege\b|\bstudent\b|\.edu\b|\.ac\."#

    private static func defaultCalendar(_ lower: String, namesWhen: Bool) -> DemoPreferenceIntent? {
        guard !namesWhen,
              DemoParser.match(#"帳號|账号|帳戶|账户|行事曆|行事历|日曆|日历|信箱|郵箱|邮箱|\baccount\b|\bcalendar\b|\bemail\b"#, in: lower) != nil,
              DemoParser.match(#"用|改用|換成|换成|切換|切换|放到|放在|加到|\buse\b|\bswitch\b|\bput\b|\bsave\b"#, in: lower) != nil
        else { return nil }
        let primaries = DemoData.accounts.compactMap(\.primaryCalendar).filter(\.isWritable)
        let chosen: CalendarInfo?
        if let email = DemoParser.match(#"[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#, in: lower)?.group(0) {
            chosen = primaries.first { $0.accountEmail.lowercased() == email }
        } else if DemoParser.match(schoolPattern, in: lower) != nil {
            // The sample addresses say nothing about school, so go by the sample account itself.
            chosen = primaries.first { $0.accountID == DemoData.schoolAccountID }
        } else if DemoParser.match(#"個人|个人|私人|自己的|\bpersonal\b|\bprivate\b|\bhome\b|\bmy own\b"#, in: lower) != nil {
            chosen = primaries.first { $0.accountID == DemoData.personalAccountID }
        } else {
            chosen = nil
        }
        guard let chosen else { return nil }
        return DemoPreferenceIntent(
            requests: [PreferenceChangeRequest(key: .defaultCalendar, value: chosen.promptLabel)],
            english: "OK. From now on, new events go to \(chosen.displayName) (\(chosen.accountEmail)).",
            chinese: "好的，以後新行程會加到 \(chosen.accountEmail) 的「\(chosen.displayName)」。")
    }

    /// The demo's `resolveCalendar`: an exact CALENDARS line of a writable sample calendar.
    static func calendar(matching value: String) -> CalendarInfo? {
        let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return DemoData.accounts.flatMap(\.calendars).first { $0.isWritable && $0.promptLabel.lowercased() == wanted }
    }

    // MARK: Default length: "以後會議預設 30 分鐘", "make meetings 30 minutes by default"

    private static func defaultDuration(_ text: String, lower: String, namesWhen: Bool) -> DemoPreferenceIntent? {
        guard !namesWhen, !mentionsReminder(lower) else { return nil }
        let saysDefault = DemoParser.match(#"預設|默認|默认|\bdefault\b|\bby default\b"#, in: lower) != nil
        guard saysDefault || (hasLastingMarker(lower) && activityKind(lower) != nil) else { return nil }
        var leftover = lower
        guard let minutes = DemoParser.extractMinutes(from: &leftover) else { return nil }
        return DemoPreferenceIntent(
            requests: [PreferenceChangeRequest(key: .defaultDuration, value: String(minutes))],
            english: "OK. From now on, events last \(minutes) minutes unless you say how long.",
            chinese: "好的，以後沒說長度的行程預設 \(minutes) 分鐘。")
    }

    // MARK: Reply language: "以後用英文回覆", "always reply in Chinese"

    private static func replyLanguage(_ lower: String) -> DemoPreferenceIntent? {
        guard DemoParser.match(#"回覆|回复|回答|回應|回应|回話|回话|\breply\b|\breplies\b|\brespond\b|\banswer\b|\btalk\b|\bspeak\b"#, in: lower) != nil
        else { return nil }
        func intent(_ value: String, _ english: String, _ chinese: String) -> DemoPreferenceIntent {
            DemoPreferenceIntent(requests: [PreferenceChangeRequest(key: .replyLanguage, value: value)],
                                 english: english, chinese: chinese)
        }
        if DemoParser.match(#"same language|language i (?:type|write|use)|跟我(?:一樣|一样|相同)|我(?:用|輸入|输入)的語言|我(?:用|輸入|输入)的语言"#, in: lower) != nil {
            return intent("match", "OK. From now on, I'll reply in the language you type.", "好的，以後用你輸入的語言回覆。")
        }
        if DemoParser.match(#"英文|英語|英语|\benglish\b"#, in: lower) != nil {
            return intent("en", "OK. From now on, I'll reply in English.", "好的，以後用英文回覆。")
        }
        if DemoParser.match(#"中文|繁體|繁体|國語|国语|\bchinese\b|\bmandarin\b"#, in: lower) != nil {
            return intent("zh-Hant", "OK. From now on, I'll reply in Chinese.", "好的，以後用中文回覆。")
        }
        return nil
    }

    // MARK: Adding events: "以後先問我再加", "ask me before adding events", "直接加就好"

    private static func autonomy(_ lower: String) -> DemoPreferenceIntent? {
        if DemoParser.match(#"先問我|先问我|問過我|问过我|先跟我確認|先跟我确认|先確認|先确认|\bask me (?:first|before)|\bcheck with me\b|\bconfirm with me\b|\bask before\b"#, in: lower) != nil {
            return DemoPreferenceIntent(
                requests: [PreferenceChangeRequest(key: .autonomy, value: AssistantAutonomy.askFirst.rawValue)],
                english: "OK. From now on, I'll ask before adding events.",
                chinese: "好的，以後新增行程前會先問你。")
        }
        if DemoParser.match(#"直接加|直接新增|直接放|不用問|不用问|不要問|不要问|別問|别问|\bdon't ask\b|\bdo not ask\b|\bno need to ask\b|\bwithout asking\b|\badd (?:them |events |it )?directly\b"#, in: lower) != nil {
            return DemoPreferenceIntent(
                requests: [PreferenceChangeRequest(key: .autonomy, value: AssistantAutonomy.addDirectly.rawValue)],
                english: "OK. From now on, I'll add events directly.",
                chinese: "好的，以後會直接加入行程。")
        }
        return nil
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
    /// Capture group of English weekday names and abbreviations.
    static let weekdayNames = "(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|wed|thu(?:rs?)?|fri|sat|sun)"
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
        if let match = Self.match(#"(?<![\d:])(1[0-2]|0?[1-9])(?:[：:]([0-5]\d))?\s*(a\.?m\.?|p\.?m\.?)(?![a-z])"#, in: text),
           let hour = Int(match.group(1) ?? "") {
            text.replaceSubrange(match.range, with: " ")
            let isPM = (match.group(3) ?? "").lowercased().hasPrefix("p")
            return TimeOfDay(hour: hour % 12 + (isPM ? 12 : 0), minute: Int(match.group(2) ?? "") ?? 0, hasMeridiem: true)
        }
        // "13:00", "9:05", "14：30"
        if let match = Self.match(#"(?<!\d)([01]?\d|2[0-3])[：:]([0-5]\d)(?!\d)"#, in: text),
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
        if let match = extractCalendarDay(from: &text) { return match }

        // "friday", "next mon"
        let english = #"\b(next\s+|this\s+)?\#(Self.weekdayNames)\b"#
        if let match = Self.match(english, in: text), let weekday = Self.englishWeekday(match.group(2)) {
            text.replaceSubrange(match.range, with: " ")
            let isNext = (match.group(1) ?? "").lowercased().hasPrefix("next")
            return weekdayMatch(weekday, weeksAhead: isNext ? 1 : nil)
        }
        // 週五, 下週一, 星期天
        if let match = Self.match("(下下|下|這|这|本)?\\s*(?:週|周|星期|禮拜|礼拜)([一二三四五六日天])", in: text),
           let weekday = Self.chineseWeekday(match.group(2)) {
            text.replaceSubrange(match.range, with: " ")
            return chineseWeekMatch(weekday, prefix: match.group(1) ?? "")
        }
        return nil
    }

    /// Month-day dates and relative days: "Oct 15", "15th of October", "10/15", 10月15日, "tomorrow", 明晚.
    private func extractCalendarDay(from text: inout String) -> DayMatch? {
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
        return nil
    }

    private func chineseWeekMatch(_ weekday: Int, prefix: String) -> DayMatch {
        switch prefix {
        case "下下": return mondayWeekMatch(weekday, weeksAhead: 2)
        case "下": return mondayWeekMatch(weekday, weeksAhead: 1)
        case "": return weekdayMatch(weekday, weeksAhead: nil)
        default: return mondayWeekMatch(weekday, weeksAhead: 0) // 這週 / 本週
        }
    }

    /// "today", "tomorrow" or "Wed, Oct 15"; 今天, 明天 or 10月15日（週四）.
    func label(for day: Date, language: DemoLanguage) -> String {
        if calendar.isDate(day, inSameDayAs: today) { return language == .chinese ? "今天" : "today" }
        if calendar.isDate(day, inSameDayAs: offset(1, from: today)) { return language == .chinese ? "明天" : "tomorrow" }
        return ReplyFormatter.dayLabel(day, clock: clock, locale: language.locale)
    }

    /// `label` as it reads after a verb: "tomorrow" but "on Wed, Oct 15" (Chinese needs no preposition).
    func dayPhrase(for day: Date, language: DemoLanguage) -> String {
        let text = label(for: day, language: language)
        let relative = calendar.isDate(day, inSameDayAs: today) || calendar.isDate(day, inSameDayAs: offset(1, from: today))
        return language == .english && !relative ? "on " + text : text
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

    /// Chinese weeks run Monday–Sunday, so 這週日 / 下週日 is the Sunday that ends that week, not the one before it.
    private func mondayWeekMatch(_ weekday: Int, weeksAhead: Int) -> DayMatch {
        let monday = offset(-((calendar.component(.weekday, from: today) + 5) % 7), from: today)
        return DayMatch(date: offset(7 * weeksAhead + (weekday + 5) % 7, from: monday))
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

/// The demo's muscle-plan template and its wording. The summary, nudge and assumptions are rebuilt after every
/// revision so they always describe the sessions; titles keep the language of the original goal.
private enum DemoPlan {
    static func make(goal: String, months: Int, startDay: Date, startLabel: String, language: DemoLanguage,
                     clock: WallClock) -> LongTermPlanArgs {
        let calendar = clock.calendar
        let chinese = language == .chinese
        let endExclusive = calendar.date(byAdding: .month, value: months, to: startDay)!
        let endDay = calendar.date(byAdding: .day, value: -1, to: endExclusive)!
        let totalDays = max(calendar.dateComponents([.day], from: startDay, to: endExclusive).day ?? months * 30, 3)

        let phaseInfo = chinese
            ? [("基礎期", "練好技巧和完整動作幅度，養成習慣"),
               ("增肌期", "每組 8–12 下，每週增加重量或次數"),
               ("力量期", "較重的複合動作，每組 4–6 下")]
            : [("Foundation", "Technique, full range of motion, build the habit"),
               ("Hypertrophy", "8–12 reps, add weight or reps every week"),
               ("Strength", "Heavier compound lifts, 4–6 reps")]
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
            sessions.append(SessionDraft(phaseIndex: index, title: chinese ? "上半身" : "Upper body", weekdays: ["MO", "TH"],
                                         startTime: "18:30", durationMinutes: 60,
                                         notes: chinese ? "推和拉，最後練核心" : "Push + pull, then core"))
            sessions.append(SessionDraft(phaseIndex: index, title: chinese ? "下半身" : "Lower body", weekdays: ["TU", "FR"],
                                         startTime: "18:30", durationMinutes: 60,
                                         notes: chinese ? "深蹲或硬舉，最後做伸展" : "Squat or deadlift, then mobility"))
        }

        var milestones: [MilestoneDraft] = []
        for month in 1...months {
            let monthEnd = calendar.date(byAdding: .month, value: month, to: startDay)!
            let day = calendar.date(byAdding: .day, value: -1, to: monthEnd)!
            let title: String
            switch (chinese, month == months) {
            case (true, true): title = "最終檢查：照片、圍度、力量測試"
            case (true, false): title = "第 \(month) 個月檢查：體重和照片"
            case (false, true): title = "Final check-in: photos, measurements, strength test"
            case (false, false): title = "Month \(month) check-in: weigh-in and photos"
            }
            milestones.append(MilestoneDraft(date: clock.dateString(day), title: title))
        }

        var args = LongTermPlanArgs(
            goal: goal,
            planTitle: chinese ? "增肌計畫" : "Muscle Plan",
            startDate: clock.dateString(startDay),
            endDate: clock.dateString(endDay),
            summaryForUser: "",
            phases: phases,
            sessions: sessions,
            dailyNudge: nil,
            milestones: milestones,
            assumptions: nil
        )
        refreshText(&args, startLabel: startLabel, language: language, clock: clock)
        return args
    }

    /// Moves the whole plan (phases, milestones, end) by whole calendar days, keeping its length.
    static func shift(_ args: inout LongTermPlanArgs, byDays days: Int, clock: WallClock) {
        func moved(_ value: String) -> String {
            guard let day = clock.date(value), let shifted = clock.calendar.date(byAdding: .day, value: days, to: day)
            else { return value }
            return clock.dateString(shifted)
        }
        args.startDate = moved(args.startDate)
        args.endDate = moved(args.endDate)
        for index in args.phases.indices {
            args.phases[index].startDate = moved(args.phases[index].startDate)
            args.phases[index].endDate = moved(args.phases[index].endDate)
        }
        args.milestones = args.milestones?.map { MilestoneDraft(date: moved($0.date), title: $0.title) }
    }

    /// Deals the training days round-robin over each phase's session templates, so Upper/Lower alternate:
    /// MO,WE,FR → Upper MO,FR · Lower WE. A template left without a day is dropped.
    static func assign(_ weekdays: [String], to args: inout LongTermPlanArgs) {
        let days = RecurrenceRule.normalizedWeekdays(weekdays)
        guard !days.isEmpty else { return }
        var sessions: [SessionDraft] = []
        for phase in Set(args.sessions.map(\.phaseIndex)).sorted() {
            let templates = args.sessions.filter { $0.phaseIndex == phase }
            for (slot, template) in templates.enumerated() {
                let mine = days.enumerated().filter { $0.offset % templates.count == slot }.map(\.element)
                guard !mine.isEmpty else { continue }
                var session = template
                session.weekdays = mine
                sessions.append(session)
            }
        }
        args.sessions = sessions
    }

    /// The summary follows the readability rules the model gets: what the plan is and the weekly load, nothing
    /// the card's schedule table already shows (days, times, phases, check-ins, reminders).
    static func refreshText(_ args: inout LongTermPlanArgs, startLabel: String, language: DemoLanguage, clock: WallClock) {
        let calendar = clock.calendar
        let firstPhase = args.sessions.map(\.phaseIndex).min() ?? 0
        let first = args.sessions.filter { $0.phaseIndex == firstPhase }
        let dayCount = Set(first.flatMap { RecurrenceRule.normalizedWeekdays($0.weekdays) }).count
        let time = first.first?.startTime ?? "18:30"
        let shortest = first.map(\.durationMinutes).min() ?? 60
        let longest = first.map(\.durationMinutes).max() ?? 60

        var months = 1
        if let start = clock.date(args.startDate), let end = clock.date(args.endDate),
           let afterEnd = calendar.date(byAdding: .day, value: 1, to: end) {
            months = max(calendar.dateComponents([.month], from: start, to: afterEnd).month ?? 1, 1)
        }
        let nudge = nudgeTime(forSessionAt: time, clock: clock)
        let afterWork = (clock.timeOfDay(time)?.hour ?? 18) >= 17

        switch language {
        case .english:
            let article = [8, 11, 18].contains(months) ? "An" : "A"
            let workouts = dayCount == 1 ? "1 workout a week" : "\(dayCount) workouts a week"
            let length = shortest != longest ? "\(shortest) to \(longest) minutes each"
                : (shortest == 60 ? "about an hour each" : "\(shortest) minutes each")
            args.summaryForUser = "\(article) \(months)-month muscle plan: \(workouts), \(length)."
            args.dailyNudge = NudgeDraft(time: nudge, message: "Good morning! Have some protein with breakfast.")
            args.assumptions = [afterWork ? "You train at \(time), after work" : "You train at \(time)",
                                "Starts \(startLabel)",
                                "You have gym access"]
        case .chinese:
            let length = shortest != longest ? "每次 \(shortest) 到 \(longest) 分鐘"
                : (shortest == 60 ? "每次約 1 小時" : "每次 \(shortest) 分鐘")
            args.summaryForUser = "\(months) 個月增肌計畫：每週練 \(dayCount) 次，\(length)。"
            args.dailyNudge = NudgeDraft(time: nudge, message: "早安！早餐記得補充蛋白質。")
            args.assumptions = [afterWork ? "下班後 \(time) 訓練" : "\(time) 訓練",
                                "\(startLabel)開始",
                                "可以使用健身房"]
        }
    }

    /// 07:30, or an hour before an early session (never before 05:00).
    private static func nudgeTime(forSessionAt time: String, clock: WallClock) -> String {
        guard let value = clock.timeOfDay(time) else { return "07:30" }
        let minutes = value.hour * 60 + value.minute
        guard minutes < 8 * 60 + 30 else { return "07:30" }
        let nudge = max(minutes - 60, 5 * 60)
        return String(format: "%02d:%02d", nudge / 60, nudge % 60)
    }
}

/// The language demo sentences are written in: Chinese when the user typed Chinese, English otherwise.
enum DemoLanguage {
    case english
    case chinese

    /// Chinese when `text` has Han characters, English when it has other letters, else `fallback`
    /// (a bare "07:00" or "45").
    static func of(_ text: String, fallback: DemoLanguage = .english) -> DemoLanguage {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }) {
            return .chinese
        }
        return scalars.contains(where: { CharacterSet.letters.contains($0) }) ? .english : fallback
    }

    /// The language the UI strings resolved to.
    static var device: DemoLanguage {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? .chinese : .english
    }

    /// For dates inside demo sentences. English keeps the device's region when the device is in English.
    var locale: Locale {
        switch self {
        case .chinese: Locale(identifier: "zh_Hant_TW")
        case .english: Locale.current.language.languageCode?.identifier == "en" ? Locale.current : Locale(identifier: "en_US")
        }
    }
}

/// What a revision changed, said in short sentences: "Now every Monday and Thursday at 07:00." /
/// "已改成每週一、四 07:00。" Days are written out, never "Mon/Thu".
private struct PlanChange {
    var weekdays: [String]?        // normalized MO…SU
    var time: String?              // "HH:mm"
    var minutes: Int?
    var start: String?             // "tomorrow", "on Mon, Oct 19", 明天, 10月19日（週一）

    var isEmpty: Bool { weekdays == nil && time == nil && minutes == nil && start == nil }

    func sentences(_ language: DemoLanguage) -> String {
        var parts: [String] = []
        switch language {
        case .english:
            if let weekdays {
                parts.append("Now \(Self.englishDays(weekdays))\(time.map { " at \($0)" } ?? "").")
            } else if let time {
                parts.append("Sessions now start at \(time).")
            }
            if let minutes { parts.append("Each session is now \(minutes) minutes.") }
            if let start { parts.append("The plan now starts \(start).") }
            return parts.joined(separator: " ")
        case .chinese:
            if let weekdays {
                parts.append("已改成\(Self.chineseDays(weekdays))\(time.map { " \($0)" } ?? "")。")
            } else if let time {
                parts.append("已改成 \(time) 開始。")
            }
            if let minutes { parts.append("每次改成 \(minutes) 分鐘。") }
            if let start { parts.append("改成\(start)開始。") }
            return parts.joined()
        }
    }

    private static let weekdaysOnly = ["MO", "TU", "WE", "TH", "FR"]
    private static let weekend = ["SA", "SU"]
    private static let everyDay = weekdaysOnly + weekend

    /// "every Monday and Thursday", "on weekdays", "every day".
    private static func englishDays(_ codes: [String]) -> String {
        if codes == everyDay { return "every day" }
        if codes == weekdaysOnly { return "on weekdays" }
        if codes == weekend { return "on weekends" }
        let names = ["MO": "Monday", "TU": "Tuesday", "WE": "Wednesday", "TH": "Thursday",
                     "FR": "Friday", "SA": "Saturday", "SU": "Sunday"]
        let words = codes.compactMap { names[$0] }
        guard let last = words.last else { return "" }
        return "every " + (words.count == 1 ? last : words.dropLast().joined(separator: ", ") + " and " + last)
    }

    /// 每週一、三、五 · 平日 · 週末 · 每天.
    private static func chineseDays(_ codes: [String]) -> String {
        if codes == everyDay { return "每天" }
        if codes == weekdaysOnly { return "平日" }
        if codes == weekend { return "週末" }
        let names = ["MO": "一", "TU": "二", "WE": "三", "TH": "四", "FR": "五", "SA": "六", "SU": "日"]
        return "每週" + codes.compactMap { names[$0] }.joined(separator: "、")
    }
}

/// What a "Keep editing" message asked for; nil fields stay as they are.
private struct PlanEdit {
    enum Topic { case days, time, start }

    var startDay: Date?
    var weekdays: [String]?
    var time: DemoParser.TimeOfDay?
    var timeShiftMinutes: Int?     // "30 min later" (+30), "an hour earlier" (-60)
    var durationMinutes: Int?
    var durationChange: Int?       // "shorter" (-15) / "longer" (+15)
    var topic: Topic?              // a chip like "Change the time" that names no value yet

    var isEmpty: Bool {
        startDay == nil && weekdays == nil && time == nil && timeShiftMinutes == nil
            && durationMinutes == nil && durationChange == nil
    }
}

// MARK: - Plan revisions

extension DemoParser {
    /// Reads a "Keep editing" message. Every recognised phrase is removed from `text`, so the caller can tell
    /// plan talk ("make it 7am" leaves "make it") from a request about something else.
    func extractPlanEdit(from text: inout String) -> PlanEdit {
        var edit = PlanEdit()

        // "30 min later", "an hour earlier", 延後半小時 move the sessions; a bare "45 min" is their length.
        let later = #"\b(?:later|push(?:ed)?|delay|postpone)\b|延後|延后|推遲|推迟|晚一點|晚一点|往後|往后"#
        let earlier = #"\b(?:earlier|sooner)\b|提早|提前|早一點|早一点|往前"#
        let direction = Self.match(earlier, in: text) != nil ? -1 : (Self.match(later, in: text) != nil ? 1 : 0)
        let minutes = Self.extractMinutes(from: &text)
        if direction != 0, let minutes {
            edit.timeShiftMinutes = direction * minutes
        } else {
            edit.durationMinutes = minutes
        }
        if !Self.extractAll(#"\bshorter\b|短一點|短一点|縮短|缩短"#, from: &text).isEmpty {
            edit.durationChange = -15
        } else if !Self.extractAll(#"\blonger\b|長一點|长一点|延長|延长"#, from: &text).isEmpty {
            edit.durationChange = 15
        }

        // The start day goes first, so "starting next Monday" is a date and "Mondays" a training day.
        edit.startDay = extractStartDay(from: &text)
        edit.weekdays = Self.extractWeekdays(from: &text)
        edit.time = extractTime(from: &text)
        if edit.time == nil { edit.time = Self.extractPeriodTime(from: &text) }
        if edit.time == nil, edit.timeShiftMinutes == nil, direction != 0,
           Self.match(#"\b(?:later|earlier)\b|晚一點|晚一点|早一點|早一点"#, in: text) != nil {
            edit.timeShiftMinutes = direction * 30 // "a bit later"
        }
        _ = Self.extractAll(later + "|" + earlier, from: &text)
        if edit.isEmpty { edit.topic = Self.planTopic(text) }
        return edit
    }

    /// A plan's new first day: dates and relative days, but a weekday only after "next"/"this", a start word,
    /// 下週/這週 or 從, or before 開始, so "Mondays and Thursdays" stays a list of training days.
    func extractStartDay(from text: inout String) -> Date? {
        if let match = extractCalendarDay(from: &text) { return match.date }
        if let match = Self.match(#"\b(next|this)\s+\#(Self.weekdayNames)\b"#, in: text),
           let weekday = Self.englishWeekday(match.group(2)) {
            text.replaceSubrange(match.range, with: " ")
            return weekdayMatch(weekday, weeksAhead: match.group(1)?.lowercased() == "next" ? 1 : nil).date
        }
        if let match = Self.match(#"\b(?:start(?:s|ing)?|begin(?:s|ning)?|from)\s+(?:on\s+)?\#(Self.weekdayNames)\b"#, in: text),
           let weekday = Self.englishWeekday(match.group(1)) {
            text.replaceSubrange(match.range, with: " ")
            return weekdayMatch(weekday, weeksAhead: nil).date
        }
        if let match = Self.match("(下下|下|這|这|本)\\s*(?:週|周|星期|禮拜|礼拜)([一二三四五六日天])", in: text),
           let weekday = Self.chineseWeekday(match.group(2)) {
            text.replaceSubrange(match.range, with: " ")
            return chineseWeekMatch(weekday, prefix: match.group(1) ?? "").date
        }
        let chineseStart = "(?:從|从)\\s*(?:週|周|星期|禮拜|礼拜)([一二三四五六日天])|(?:週|周|星期|禮拜|礼拜)([一二三四五六日天])\\s*(?:開始|开始|起)"
        if let match = Self.match(chineseStart, in: text),
           let weekday = Self.chineseWeekday(match.group(1) ?? match.group(2)) {
            text.replaceSubrange(match.range, with: " ")
            return weekdayMatch(weekday, weeksAhead: nil).date
        }
        return nil
    }

    /// Training days: "MWF", "weekdays", "Mon, Wed and Fri", "3 days a week", 週一三五, 平日, 一週三次.
    static func extractWeekdays(from text: inout String) -> [String]? {
        let everyDay = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
        // Counts first, so 一週三次 is not read as 週三.
        var count: Int?
        let countWords = ["once": 1, "twice": 2, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7]
        let englishCount = #"\b([1-7]|one|two|three|four|five|six|seven|once|twice)\s*(?:x|times|days|sessions|workouts)?\s*(?:a|per|each|every|/)\s*week\b"#
        let chineseCount = #"(?:每|一)\s*(?:個|个)?\s*(?:週|周|星期|禮拜|礼拜)\s*(?:練|练|訓練|训练|運動|运动|上)?\s*(\#(cnNumber))\s*(?:天|次)"#
        if let match = Self.match(englishCount, in: text) {
            let token = (match.group(1) ?? "").lowercased()
            count = Int(token) ?? countWords[token]
            text.replaceSubrange(match.range, with: " ")
        } else if let match = Self.match(chineseCount, in: text) {
            count = Self.number(match.group(1) ?? "")
            text.replaceSubrange(match.range, with: " ")
        }

        var days: [String] = []
        let named: [(pattern: String, codes: [String])] = [
            (#"\b(?:every\s+)?weekdays?\b|平日|工作日|(?:週|周)一\s*(?:到|至|-|~)\s*(?:週|周)?五"#, Array(everyDay.prefix(5))),
            (#"\b(?:on\s+)?weekends?\b|週末|周末"#, ["SA", "SU"]),
            (#"\bevery\s*day\b|\beach\s+day\b|\bdaily\b|每天|每日"#, everyDay)
        ]
        for set in named where !Self.extractAll(set.pattern, from: &text).isEmpty { days += set.codes }
        let compact = ["mwf": ["MO", "WE", "FR"], "mw": ["MO", "WE"], "mf": ["MO", "FR"], "wf": ["WE", "FR"],
                       "mth": ["MO", "TH"], "tth": ["TU", "TH"], "tuth": ["TU", "TH"],
                       "mtwtf": Array(everyDay.prefix(5)), "mtwthf": Array(everyDay.prefix(5))]
        for match in Self.extractAll(#"\b(mwf|mw|mf|wf|mth|tth|tuth|mtwtf|mtwthf)\b"#, from: &text) {
            days += compact[(match.group(1) ?? "").lowercased()] ?? []
        }
        for match in Self.extractAll(#"\b\#(weekdayNames)s?\b"#, from: &text) {
            if let weekday = Self.englishWeekday(match.group(1)) { days.append(RecurrenceRule.weekdayCodes[weekday - 1]) }
        }
        let chineseDays = "(?:週|周|星期|禮拜|礼拜)([一二三四五六日天](?:\\s*[、,，和與与及跟/]?\\s*[一二三四五六日天])*)"
        for match in Self.extractAll(chineseDays, from: &text) {
            for character in match.group(1) ?? "" {
                if let weekday = Self.chineseWeekday(String(character)) { days.append(RecurrenceRule.weekdayCodes[weekday - 1]) }
            }
        }

        if days.isEmpty, let count {
            switch count {
            case ...1: days = ["WE"]
            case 2: days = ["TU", "FR"]
            case 3: days = ["MO", "WE", "FR"]
            case 4: days = ["MO", "TU", "TH", "FR"]
            default: days = Array(everyDay.prefix(min(count, 7)))
            }
        }
        let normalized = RecurrenceRule.normalizedWeekdays(days)
        return normalized.isEmpty ? nil : normalized
    }

    /// "45 min", "1 hour", "an hour and a half", "half an hour", 30分鐘, 一小時, 半小時 → minutes.
    static func extractMinutes(from text: inout String) -> Int? {
        let patterns: [(pattern: String, minutes: (RegexMatch) -> Int?)] = [
            (#"\b(?:an|one)\s+hour\s+and\s+a\s+half\b|\b1\.5\s*(?:h|hrs?|hours?)\b|一個半小時|一个半小时"#, { _ in 90 }),
            (#"\bhalf\s+an\s+hour\b|半\s*(?:個|个)?\s*(?:小時|小时|鐘頭|钟头)"#, { _ in 30 }),
            (#"\b(\d{1,3})\s*-?\s*(?:mins?|minutes?)\b"#, { Int($0.group(1) ?? "") }),
            (#"\b(\d{1,2})\s*-?\s*(?:h|hrs?|hours?)\b"#, { Int($0.group(1) ?? "").map { $0 * 60 } }),
            (#"\b(?:an|one)\s+hour\b"#, { _ in 60 }),
            (#"(\#(cnNumber))\s*(?:分鐘|分钟)"#, { Self.number($0.group(1) ?? "") }),
            (#"(\#(cnNumber))\s*(?:個|个)?\s*(?:小時|小时|鐘頭|钟头)"#, { Self.number($0.group(1) ?? "").map { $0 * 60 } })
        ]
        for entry in patterns {
            if let match = Self.match(entry.pattern, in: text), let minutes = entry.minutes(match) {
                text.replaceSubrange(match.range, with: " ")
                return minutes
            }
        }
        return nil
    }

    /// "mornings" → 07:00 (before work), "lunch" → 12:30, "afternoon" → 14:00, "after work" → 18:30, "evenings" → 19:00.
    static func extractPeriodTime(from text: inout String) -> TimeOfDay? {
        let periods: [(pattern: String, hour: Int, minute: Int)] = [
            (#"\bbefore\s+work\b|\bmornings?\b|早上|早晨|清晨|上午"#, 7, 0),
            (#"\blunch(?:\s*time)?\b|\bmidday\b|午休"#, 12, 30),
            (#"\bafternoons?\b|下午"#, 14, 0),
            (#"\bafter\s+work\b|下班後|下班后"#, 18, 30),
            (#"\bevenings?\b|\bnights?\b|晚上|傍晚"#, 19, 0)
        ]
        for period in periods {
            if let match = Self.match(period.pattern, in: text) {
                text.replaceSubrange(match.range, with: " ")
                return TimeOfDay(hour: period.hour, minute: period.minute, hasMeridiem: true)
            }
        }
        return nil
    }

    /// What a suggestion chip like "Change the time" is about, once nothing concrete was found.
    static func planTopic(_ text: String) -> PlanEdit.Topic? {
        let lower = text.lowercased()
        if Self.match(#"\b(?:start|begin|date)\b"#, in: lower) != nil || ["開始", "开始", "日期"].contains(where: { lower.contains($0) }) {
            return .start
        }
        if Self.match(#"\bdays?\b"#, in: lower) != nil
            || ["訓練日", "训练日", "哪幾天", "哪几天", "星期", "天"].contains(where: { lower.contains($0) }) {
            return .days
        }
        if Self.match(#"\b(?:time|times|when|hour)\b"#, in: lower) != nil || ["時間", "时间", "幾點", "几点"].contains(where: { lower.contains($0) }) {
            return .time
        }
        return nil
    }

    /// "Nov 1" / 11月1日 (the first of next month), a start-day suggestion this parser reads back.
    func firstOfNextMonthLabel(language: DemoLanguage) -> String {
        let month = calendar.component(.month, from: today) % 12 + 1
        if language == .chinese { return "\(month)月1日" }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[month - 1]) 1"
    }

    /// Every case-insensitive match of `pattern` with its groups; all of them are replaced by a space in `text`.
    static func extractAll(_ pattern: String, from text: inout String) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: whole).compactMap { result -> RegexMatch? in
            guard let range = Range(result.range, in: text) else { return nil }
            let groups = (0..<result.numberOfRanges).map { index -> String? in
                Range(result.range(at: index), in: text).map { String(text[$0]) }
            }
            return RegexMatch(range: range, groups: groups)
        }
        if !matches.isEmpty {
            text = regex.stringByReplacingMatches(in: text, options: [], range: whole, withTemplate: " ")
        }
        return matches
    }
}
