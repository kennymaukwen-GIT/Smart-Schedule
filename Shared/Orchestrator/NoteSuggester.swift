import Foundation

/// One thing an event may need ("Bring passport" for a trip abroad, "Bring water" for the gym), offered as a chip
/// under the event's notes and on the chat's added-event card. Nothing is ever written on its own: a tap appends
/// "• <text>" to the notes (`NoteSuggester.appending`).
struct NoteSuggestion: Hashable, Identifiable, Sendable {
    enum Source: String, Hashable, Sendable {
        /// Smart Schedule's own rules (`NoteSuggester`): offline, instant, deterministic.
        case rules
        /// Gemini: `suggest_event_notes` on request, or the `suggested_notes` it gave when it created the event.
        case ai
    }

    /// "rule.<item>" for a rule (stable across languages), "ai.<text as compared>" for Gemini's items.
    var id: String
    /// What the chip shows and the line the notes get, without the bullet.
    var text: String
    var source: Source

    init(id: String, text: String, source: Source) {
        self.id = id
        self.text = text
        self.source = source
    }

    /// An item Gemini wrote.
    static func ai(_ text: String) -> NoteSuggestion {
        NoteSuggestion(id: "ai." + NoteSuggester.normalized(text), text: text, source: .ai)
    }
}

/// Suggested notes for an event: what it may need, worked out offline from its title, place and notes.
///
/// Rules (`NoteSuggestionRules.swift`) recognise kinds of events in Traditional Chinese, Simplified Chinese and
/// English (whole words for English, so "gym" is not found in "gymnastics"), with a few exclusions ("跑步機維修" is
/// a repair, not a workout; "接機" is picking someone up, not a flight). Each kind has 1–7 short items in English
/// and Traditional Chinese, most useful first. A trip abroad is a foreign place plus a travel word, a flight, an
/// explicit "出國" / "abroad", or a multi-day all-day event; places in the user's own country (from the time zone)
/// are not foreign. Items already in the notes are not offered, in either language.
///
/// The language follows the event's title (Chinese characters → Traditional Chinese, other letters → English);
/// a title with neither uses `preferChinese`, else the app's language. Never medical advice: checklist nouns and
/// 2–6 word actions only.
enum NoteSuggester {
    /// What each added line starts with.
    static let bullet = "• "
    /// Longer items (from Gemini) are dropped: a chip holds a few words.
    static let maxItemLength = 60
    /// How many items "AI suggestions" adds at most; the rules answer with this many when no AI is used (demo mode).
    static let requestLimit = 8

    // MARK: Suggestions

    /// What the event page and the chat card offer at once: the `suggestedNotes` Gemini gave when it created the
    /// event (`.ai`), then the rules (`.rules`); at most `limit`, none the notes already hold, no two alike.
    ///
    /// - Parameters:
    ///   - existingNotes: the notes as they are now (the page's edit buffer), plain text.
    ///   - preferChinese: the language when the title has no letters to tell (nil: the app's language).
    ///   - homeTimeZone: where the user lives: places in that country are not "abroad".
    static func suggestions(for event: ScheduleEvent, existingNotes: String?, preferChinese: Bool? = nil,
                            limit: Int = 4, homeTimeZone: TimeZone = .current) -> [NoteSuggestion] {
        let stored = storedSuggestions(for: event, existingNotes: existingNotes)
        let rules = ruleSuggestions(for: event, existingNotes: existingNotes, preferChinese: preferChinese,
                                    limit: limit, homeTimeZone: homeTimeZone)
        return merging(rules, into: stored, existingNotes: existingNotes, limit: limit)
    }

    /// The rules alone: every kind of event recognised, best placed first (the title before the place before the
    /// notes; then the order of the rule table). With several kinds, the first leads with up to `limit - 1` items
    /// and the others add one each in turn.
    static func ruleSuggestions(for event: ScheduleEvent, existingNotes: String?, preferChinese: Bool? = nil,
                                limit: Int = 4, homeTimeZone: TimeZone = .current) -> [NoteSuggestion] {
        guard limit > 0 else { return [] }
        let chinese = usesChinese(for: event, fallback: preferChinese)
        let context = RuleContext(event: event, notes: existingNotes, homeTimeZone: homeTimeZone)
        let matched = matchedCategories(in: context)
        let matchedIDs = Set(matched.map { $0.id })
        let notes = normalized(existingNotes ?? "")
        var offered = Set<String>()
        let lists: [[Item]] = matched.map { category in
            category.items.filter { item in
                guard item.applies(in: context, matched: matchedIDs), offered.insert(item.id).inserted else { return false }
                return !item.isNoted(inNormalized: notes)
            }
        }
        return pick(lists.filter { !$0.isEmpty }, limit: limit).map { item in
            NoteSuggestion(id: "rule." + item.id, text: chinese ? item.zh : item.en, source: .rules)
        }
    }

    /// The event's `suggestedNotes` (from `create_events`), tidied, minus what the notes hold.
    static func storedSuggestions(for event: ScheduleEvent, existingNotes: String?) -> [NoteSuggestion] {
        cleanedItems(event.suggestedNotes, existingNotes: existingNotes, limit: 8).map { NoteSuggestion.ai($0) }
    }

    /// `base`, then `extra`, keeping the first of any two alike ("Passport" and "Bring passport") and leaving out
    /// what the notes hold; at most `limit`.
    static func merging(_ extra: [NoteSuggestion], into base: [NoteSuggestion], existingNotes: String?,
                        limit: Int) -> [NoteSuggestion] {
        let notes = normalized(existingNotes ?? "")
        var kept: [(suggestion: NoteSuggestion, key: String)] = []
        for suggestion in base + extra {
            guard kept.count < limit else { break }
            let key = normalized(suggestion.text)
            guard !key.isEmpty, !isAlreadyNoted(normalizedText: key, inNormalized: notes) else { continue }
            let duplicate = kept.contains { $0.suggestion.id == suggestion.id || areAlike($0.key, key) }
            if !duplicate { kept.append((suggestion, key)) }
        }
        return kept.map { $0.suggestion }
    }

    /// The kinds of event the rules recognise, best placed first ("abroad", "workout", …). For tests and
    /// docs/GEMINI_FUNCTION_CALLING.md §12.
    static func matchedCategoryIDs(for event: ScheduleEvent, existingNotes: String? = nil,
                                   homeTimeZone: TimeZone = .current) -> [String] {
        matchedCategories(in: RuleContext(event: event, notes: existingNotes, homeTimeZone: homeTimeZone)).map { $0.id }
    }

    // MARK: Notes

    /// The notes already say it: `text`, or its core without a leading "Bring" / "帶" ("passport" for
    /// "Bring passport"), appears in `notes`, ignoring case, full-width letters, accents and punctuation. English
    /// matches whole words ("ID" is not found in "did"); Chinese matches anywhere, spaces ignored.
    static func isAlreadyNoted(_ text: String, in notes: String?) -> Bool {
        guard let notes else { return false }
        return isAlreadyNoted(normalizedText: normalized(text), inNormalized: normalized(notes))
    }

    /// `notes` with "• <text>" on a new line at the end (after a blank line when the notes are only Smart Schedule's
    /// provenance line, as `EventNotes.appending` does). Trailing blank lines go; the notes are returned unchanged
    /// when that line is already there or `text` is blank.
    static func appending(_ suggestion: NoteSuggestion, to notes: String?) -> String {
        appending(suggestion.text, to: notes)
    }

    /// Same, for a chip's text.
    static func appending(_ text: String, to notes: String?) -> String {
        let item = cleaned(text)
        guard !item.isEmpty else { return notes ?? "" }
        let line = bullet + item
        let current = (notes ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if current.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) {
            return notes ?? ""
        }
        var kept = current
        while let last = kept.last, last.isWhitespace { kept.removeLast() }
        guard !kept.isEmpty else { return line }
        let onlyProvenance = CalendarEventMapper.startsWithProvenance(kept) && !kept.contains("\n")
        return kept + (onlyProvenance ? "\n\n" : "\n") + line
    }

    // MARK: Items from Gemini

    /// Gemini's items as chips: one line each, without bullets, numbering or a final full stop; blank, overlong
    /// (over `maxItemLength`), repeated or already noted items left out; at most `limit`.
    static func cleanedItems(_ raw: [String]?, existingNotes: String? = nil, limit: Int = 4) -> [String] {
        let notes = normalized(existingNotes ?? "")
        var result: [(text: String, key: String)] = []
        for item in raw ?? [] {
            guard result.count < limit else { break }
            let text = cleaned(item)
            let key = normalized(text)
            guard !key.isEmpty, text.count <= maxItemLength,
                  !isAlreadyNoted(normalizedText: key, inNormalized: notes),
                  !result.contains(where: { areAlike($0.key, key) }) else { continue }
            result.append((text, key))
        }
        return result.map { $0.text }
    }

    /// One line, single spaces, no leading bullet or "1." and no final full stop or comma.
    static func cleaned(_ item: String) -> String {
        var text = item.components(separatedBy: .newlines).joined(separator: " ")
        text = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" }).joined(separator: " ")
        let bullets: Set<Character> = ["•", "·", "・", "-", "–", "—", "*", "+", "✓", "✔", "☐", "□", "▪", "◦", "●", "○"]
        while let first = text.first, bullets.contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let numbering = text.range(of: #"^\d{1,2}(?:[.):]\s+|、)"#, options: .regularExpression) {
            text.removeSubrange(numbering)
        }
        let endings: Set<Character> = [".", "。", ";", "；", ",", "，", "、"]
        while let last = text.last, endings.contains(last) { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Language

    /// Chinese when the title has Chinese (or other CJK) characters, English when it has other letters; otherwise
    /// `fallback`, else the app's language.
    static func usesChinese(for event: ScheduleEvent, fallback: Bool? = nil) -> Bool {
        if containsCJK(event.title) { return true }
        if event.title.contains(where: { $0.isLetter }) { return false }
        return fallback ?? appUsesChinese
    }

    /// The language the app's strings resolved to.
    static var appUsesChinese: Bool {
        (Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
    }

    // MARK: Text

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Lower case, half width, without accents: what the rules look in.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: posix)
    }

    /// Folded letters and digits only, single spaces between words and between Chinese and Latin runs:
    /// "• BRING ｐａｓｓｐｏｒｔ!" → "bring passport", "帶passport" → "帶 passport".
    static func normalized(_ text: String) -> String {
        var result = ""
        var lastWasCJK: Bool?
        for character in fold(text) {
            if character.isLetter || character.isNumber {
                let cjk = character.unicodeScalars.contains { isCJK($0) }
                if let lastWasCJK, lastWasCJK != cjk { result.append(" ") }
                result.append(character)
                lastWasCJK = cjk
            } else if lastWasCJK != nil {
                result.append(" ")
                lastWasCJK = nil
            }
        }
        if result.last == " " { result.removeLast() }
        return result
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCJK($0) }
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    /// Both normalized: `needle`, or its core, is in `haystack`.
    static func isAlreadyNoted(normalizedText needle: String, inNormalized haystack: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        if normalizedContains(haystack, needle) { return true }
        if let core = core(of: needle), normalizedContains(haystack, core) { return true }
        return false
    }

    /// Two normalized items that say the same thing ("passport" and "bring passport").
    static func areAlike(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || isAlreadyNoted(normalizedText: lhs, inNormalized: rhs)
            || isAlreadyNoted(normalizedText: rhs, inNormalized: lhs)
    }

    /// Chinese: anywhere, spaces ignored. Otherwise: whole words.
    private static func normalizedContains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        if containsCJK(needle) {
            return haystack.replacingOccurrences(of: " ", with: "").contains(needle.replacingOccurrences(of: " ", with: ""))
        }
        return (" " + haystack + " ").contains(" " + needle + " ")
    }

    /// Normalized words an item may start with that say nothing about what it is. Longer ones first.
    private static let leadingWords: [String] = [
        "remember to bring", "bring", "take", "pack", "carry", "wear", "prepare", "get", "buy", "print", "have",
        "a", "an", "the", "your", "my", "some", "extra",
        "記得帶", "记得带", "記得", "记得", "攜帶", "携带", "帶上", "带上", "帶", "带", "準備好", "准备好", "準備", "准备", "穿"
    ]

    /// The item without leading verbs and articles ("bring a towel" → "towel", "帶護照" → "護照"); nil when nothing
    /// changed or what is left is too short to tell (one Chinese character, two Latin letters).
    static func core(of text: String) -> String? {
        var remainder = text
        var stripped = true
        while stripped {
            stripped = false
            for word in leadingWords where remainder.hasPrefix(word) {
                let rest = remainder.dropFirst(word.count)
                // English words end at a space; Chinese verbs run straight into the noun.
                guard containsCJK(word) || rest.hasPrefix(" ") else { continue }
                remainder = String(rest).trimmingCharacters(in: .whitespaces)
                stripped = true
                break
            }
        }
        guard remainder != text, !remainder.isEmpty else { return nil }
        let length = remainder.replacingOccurrences(of: " ", with: "").count
        return length >= (containsCJK(remainder) ? 2 : 3) ? remainder : nil
    }

    // MARK: Picking

    /// The first list leads with up to `limit - 1` items when there are others (all of `limit` when alone); then
    /// each other list adds one in turn, the first's remaining items taking the last turn.
    static func pick<T>(_ lists: [[T]], limit: Int) -> [T] {
        guard let first = lists.first, limit > 0 else { return [] }
        let others = lists.dropFirst()
        let lead = others.isEmpty ? limit : max(1, limit - 1)
        var result = Array(first.prefix(lead))
        var queues: [ArraySlice<T>] = others.map { ArraySlice($0) } + [first.dropFirst(lead)]
        while result.count < limit, queues.contains(where: { !$0.isEmpty }) {
            for index in queues.indices where result.count < limit {
                if let next = queues[index].popFirst() { result.append(next) }
            }
        }
        return result
    }
}
