import SwiftUI

// Suggested notes: what an event may need ("Bring passport" for a trip abroad, "Bring water" for the gym), offered
// as chips the user taps. Nothing is ever written on its own: on the event page a tap adds "• item" to the notes
// being edited (Save keeps it), on the chat's added-event card a tap writes the note to the event at once.
//
// Where the items come from: `NoteSuggester` (Smart Schedule's own rules, offline and instant), the
// `suggested_notes` Gemini gave when it created the event (`ScheduleEvent.suggestedNotes`, kept on this device), and
// "AI suggestions" (`ScheduleAssisting.suggestNotes`, on demand, behind the AI consent). Items the notes already
// hold are not offered again; "×" hides the suggestions of an event (a repeating one: of its whole series) until
// "Show suggestions".

// MARK: - Event page model

/// The event page's "Suggested" row: the chips on offer and the "AI suggestions" request with its consent step.
/// Owned by the page (`EventPage`), which also presents the consent sheet: the page is a sheet itself, so the
/// chat's consent sheet on the root view cannot show over it.
@MainActor
@Observable
final class NoteSuggestionsModel {
    enum Phase: Equatable {
        case idle
        case loading
        /// Answered. `fromRules`: Smart Schedule's own rules answered (offline, or demo mode without the AI), not
        /// Gemini.
        /// `added`: how many new chips it brought.
        case loaded(fromRules: Bool, added: Int)
        case failed
    }

    /// Drives the consent sheet over the event page; a fresh id each time it is asked.
    struct ConsentPrompt: Identifiable, Equatable {
        let id = UUID()
    }

    /// Gemini's `suggested_notes` and the rules, shown at once.
    static let instantLimit = 4
    /// What "AI suggestions" adds at most.
    static let requestLimit = 4

    private(set) var phase: Phase
    /// What "AI suggestions" brought while the page is open, after the instant chips.
    private(set) var requested: [NoteSuggestion]
    /// "×" was tapped for this event: the row only offers "Show suggestions".
    private(set) var isDismissed: Bool
    var consentPrompt: ConsentPrompt?

    /// The `NoteSuggestionDismissals` key.
    let dismissalID: String
    /// The request waiting for consent: Allow runs it again.
    @ObservationIgnored private var pendingRequest: (@MainActor () -> Void)?

    /// A repeating event is dismissed for its whole series (`NoteSuggestionDismissals.key(for:)`): every
    /// occurrence would suggest the same.
    init(event: ScheduleEvent, phase: Phase = .idle, requested: [NoteSuggestion] = []) {
        let id = NoteSuggestionDismissals.key(for: event)
        dismissalID = id
        isDismissed = NoteSuggestionDismissals.isDismissed(eventID: id)
        self.phase = phase
        self.requested = requested
    }

    /// The chips on offer for `event` as the page shows it: Gemini's `suggested_notes` and the rules (at most four
    /// between them, `NoteSuggester.suggestions`), then what "AI suggestions" brought; no two alike, none the notes
    /// already hold.
    func chips(for event: ScheduleEvent, notes: String, preferChinese: Bool, homeTimeZone: TimeZone) -> [NoteSuggestion] {
        guard !isDismissed else { return [] }
        let instant = NoteSuggester.suggestions(for: event, existingNotes: notes, preferChinese: preferChinese,
                                                limit: Self.instantLimit, homeTimeZone: homeTimeZone)
        return NoteSuggester.merging(requested, into: instant, existingNotes: notes,
                                     limit: Self.instantLimit + Self.requestLimit)
    }

    /// "×": hides this event's suggestions from now on (on this device), including what was just requested.
    func dismiss() {
        NoteSuggestionDismissals.dismiss(eventID: dismissalID)
        isDismissed = true
        requested = []
        if phase != .loading { phase = .idle }
    }

    /// "Show suggestions": undoes "×".
    func restore() {
        NoteSuggestionDismissals.restore(eventID: dismissalID)
        isDismissed = false
    }

    /// "AI suggestions": ideas for `event` (as edited so far) added after the chips already shown. Offline, this
    /// device answers from the rule engine, in demo mode too (its AI needs the network as well); so it does when
    /// Gemini's content filter blocks the request, which "Try again" could never get past. Demo mode asks Gemini
    /// about a sample event once AI data sharing is allowed, and its rules answer otherwise; an answer without an AI
    /// item says the rules answered. Without AI consent `fetch` throws `GeminiError.consentRequired` (demo mode: only
    /// before "Use the AI assistant?" was answered): the sheet asks, and Allow asks Gemini again.
    func requestSuggestions(for event: ScheduleEvent,
                            notes: String,
                            shown: [NoteSuggestion],
                            preferChinese: Bool,
                            homeTimeZone: TimeZone,
                            isDemo: Bool,
                            isOffline: Bool,
                            fetch: @escaping @MainActor (ScheduleEvent) async throws -> [NoteSuggestion]) {
        guard phase != .loading else { return }
        pendingRequest = nil
        let fallback: @MainActor () -> Void = { [weak self] in
            self?.answerFromRules(for: event, notes: notes, shown: shown, preferChinese: preferChinese,
                                  homeTimeZone: homeTimeZone)
        }
        if isOffline {
            fallback()
            return
        }
        phase = .loading
        Task {
            do {
                let suggestions = try await fetch(event)
                // The answer leads with the rules the row already shows; without an AI item, only they answered.
                let fromRules = !suggestions.contains(where: { $0.source == .ai })
                add(suggestions, fromRules: fromRules, shown: shown, notes: notes)
            } catch GeminiError.consentRequired {
                phase = .idle
                pendingRequest = { [weak self] in
                    self?.requestSuggestions(for: event, notes: notes, shown: shown, preferChinese: preferChinese,
                                             homeTimeZone: homeTimeZone, isDemo: isDemo, isOffline: isOffline,
                                             fetch: fetch)
                }
                consentPrompt = ConsentPrompt()
            } catch is URLError {
                // Gemini cannot be reached: Smart Schedule's own suggestions instead.
                fallback()
            } catch GeminiError.blocked(let reason) where GeminiError.isContentBlock(reason: reason) {
                // Gemini's filter blocked the request (the event's title, place or notes): asking again would be
                // blocked the same way, so Smart Schedule's own suggestions instead of "Try again".
                fallback()
            } catch {
                phase = .failed
            }
        }
    }

    /// "Allow" on the consent sheet: records consent (the chat follows), then asks again.
    func allowConsent() {
        AIConsentStore.grant()
        consentPrompt = nil
        let request = pendingRequest
        pendingRequest = nil
        request?()
    }

    /// "Not now": nothing is sent; the rule chips stay.
    func declineConsent() {
        AIConsentStore.decline()
        consentPrompt = nil
        pendingRequest = nil
        phase = .idle
    }

    private func answerFromRules(for event: ScheduleEvent, notes: String, shown: [NoteSuggestion],
                                 preferChinese: Bool, homeTimeZone: TimeZone) {
        let rules = NoteSuggester.ruleSuggestions(for: event, existingNotes: notes, preferChinese: preferChinese,
                                                  limit: NoteSuggester.requestLimit, homeTimeZone: homeTimeZone)
        add(rules, fromRules: true, shown: shown, notes: notes)
    }

    /// Appends what is new: not alike anything shown or requested before, not in the notes.
    private func add(_ suggestions: [NoteSuggestion], fromRules: Bool, shown: [NoteSuggestion], notes: String) {
        let before = NoteSuggester.merging(requested, into: shown, existingNotes: notes, limit: Int.max)
        let after = NoteSuggester.merging(suggestions, into: before, existingNotes: notes,
                                          limit: before.count + Self.requestLimit)
        let new = after.dropFirst(before.count)
        requested += new
        phase = .loaded(fromRules: fromRules, added: new.count)
    }
}

// MARK: - Event page row

/// Under the event page's notes: "Suggested" with "×", a chip per item ("+ Bring passport" / 「+ 帶護照」) and
/// "AI suggestions" (a spinner while it works, then where the answer came from). A chip adds "• item" to the notes
/// being edited. After "×" only "Show suggestions" is left.
struct NoteSuggestionsRow: View {
    let model: NoteSuggestionsModel
    let chips: [NoteSuggestion]
    var onAdd: (NoteSuggestion) -> Void
    var onRequest: () -> Void

    var body: some View {
        if model.isDismissed {
            Button {
                withAnimation(.snappy) { model.restore() }
            } label: {
                Label("Show suggestions", systemImage: "lightbulb")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.borderless)
        } else {
            suggestions
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chips.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Suggested")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.snappy) { model.dismiss() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Hide suggestions"))
                }
                WrappingChipLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(chips) { chip in
                        Button {
                            withAnimation(.snappy) { onAdd(chip) }
                        } label: {
                            NoteChipLabel(text: chip.text, isAI: chip.source == .ai)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Add “\(chip.text)” to notes"))
                    }
                }
            }
            requestControl
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: chips)
        .animation(.snappy, value: model.phase)
    }

    @ViewBuilder
    private var requestControl: some View {
        switch model.phase {
        case .idle:
            requestButton
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Getting suggestions…")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityElement(children: .combine)
        case let .loaded(fromRules, added):
            if fromRules {
                Label("Suggestions from Smart Schedules", systemImage: "checklist")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            } else if added == 0 {
                Text("No more suggestions")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed:
            HStack(spacing: 10) {
                Text("Couldn't get AI suggestions.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Button("Try again", action: onRequest)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
    }

    private var requestButton: some View {
        Button(action: onRequest) {
            Label {
                Text("AI suggestions")
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.demoBadge)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Chat card chips

/// Under an event the assistant just added: up to three things worth noting. A tap writes "• item" to the event's
/// notes at once, through the event page's path (`ScheduleViewModel.updateEvent`: Google with If-Match, or the
/// outbox while offline; demo mode edits the sample data), and the chip then reads "Added: …". A repeating event
/// gets the note on every occurrence. The items are Gemini's `suggested_notes` first, then Smart Schedule's rules,
/// worked out from the event as the reply added it, so the row stays put as notes are added.
struct AddedEventNoteChips: View {
    /// As the reply added it.
    let event: ScheduleEvent
    /// The calendar's copy (a repeating event: its next occurrence), whose notes change.
    let live: ScheduleEvent
    let schedule: ScheduleViewModel

    @Environment(\.locale) private var environmentLocale
    @State private var adding: String?
    @State private var failed = false

    static let limit = 3

    var body: some View {
        let notes = Self.plainNotes(of: live)
        let items = Self.items(for: event, live: live,
                               preferChinese: ReplyFormatter.isChinese(ChatFormat.dateLocale(environmentLocale)),
                               homeTimeZone: schedule.clock.timeZone)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                WrappingChipLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(items) { chip in
                        chipButton(chip, isAdded: NoteSuggester.isAlreadyNoted(chip.text, in: notes))
                    }
                }
                if failed {
                    Text("Couldn't add the note.")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            .animation(.snappy, value: notes)
        }
    }

    @ViewBuilder
    private func chipButton(_ chip: NoteSuggestion, isAdded: Bool) -> some View {
        if isAdded {
            NoteChipLabel(text: chip.text, isAI: chip.source == .ai, state: .added, size: 13)
                .accessibilityElement(children: .combine)
        } else {
            Button {
                add(chip.text)
            } label: {
                NoteChipLabel(text: chip.text, isAI: chip.source == .ai, state: adding == chip.text ? .adding : .add,
                              size: 13)
            }
            .buttonStyle(.plain)
            // One at a time: each write starts from the notes the previous one left.
            .disabled(adding != nil)
            .accessibilityLabel(Text("Add “\(chip.text)” to notes"))
        }
    }

    /// Gemini's `suggested_notes` for the event (the calendar's copy keeps them when the reply's has none), then the
    /// rules; at most three, leaving out what the notes held when the event was added.
    static func items(for event: ScheduleEvent, live: ScheduleEvent, preferChinese: Bool,
                      homeTimeZone: TimeZone) -> [NoteSuggestion] {
        var subject = event
        if subject.suggestedNotes == nil { subject.suggestedNotes = live.suggestedNotes }
        return NoteSuggester.suggestions(for: subject, existingNotes: plainNotes(of: event),
                                         preferChinese: preferChinese, limit: limit, homeTimeZone: homeTimeZone)
    }

    /// Whether the card offers chips for `live`: an upcoming event the account can change, whose suggestions were
    /// not hidden with "×".
    @MainActor
    static func isOffered(for live: ScheduleEvent, in schedule: ScheduleViewModel, now: Date = Date()) -> Bool {
        live.end > now && !schedule.isReadOnly(live)
            && !NoteSuggestionDismissals.isDismissed(eventID: NoteSuggestionDismissals.key(for: live))
    }

    /// Plain text, as the event page shows it (older caches may still hold Google's HTML).
    static func plainNotes(of event: ScheduleEvent) -> String {
        EventNotes.plainText(fromDescription: event.notes) ?? ""
    }

    private func add(_ item: String) {
        guard adding == nil, let current = schedule.manageableEvent(for: event) else { return }
        adding = item
        failed = false
        let notes = NoteSuggester.appending(item, to: Self.plainNotes(of: current))
        let scope: EditScope = current.seriesID != nil ? .allEvents : .thisEvent
        Task {
            do {
                try await schedule.updateEvent(current, with: EventEdit(notes: .some(notes)), scope: scope)
            } catch {
                failed = true
            }
            adding = nil
        }
    }
}

// MARK: - Chip

/// "+ Bring passport": a capsule on the dark page and on chat cards. Gemini's items carry a small sparkle;
/// `.adding` shows a spinner, `.added` "✓ Added: Bring passport".
struct NoteChipLabel: View {
    enum Status {
        case add, adding, added
    }

    let text: String
    var isAI = false
    var state: Status = .add
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 5) {
            switch state {
            case .add:
                Image(systemName: "plus")
                    .font(.system(size: size - 3, weight: .bold))
            case .adding:
                ProgressView()
                    .controlSize(.small)
            case .added:
                Image(systemName: "checkmark")
                    .font(.system(size: size - 3, weight: .bold))
            }
            Group {
                if state == .added {
                    Text("Added: \(text)")
                } else {
                    Text(verbatim: text)
                }
            }
            .lineLimit(1)
            if isAI && state != .added {
                Image(systemName: "sparkles")
                    .font(.system(size: size - 4))
                    .foregroundStyle(Theme.demoBadge.opacity(0.85))
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(state == .added ? Theme.textSecondary : .white)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(state == .added ? 0.04 : 0.08)))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .contentShape(Capsule())
    }
}

// MARK: - Layout

/// Lays chips out in rows, wrapping to the next row when one does not fit; a chip wider than the row is given the
/// row's width (its text truncates).
struct WrappingChipLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(of: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(of: subviews, width: bounds.width)
        for index in subviews.indices {
            let frame = layout.frames[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrangement(of subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if width.isFinite && size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: widest, height: frames.isEmpty ? 0 : y + rowHeight))
    }
}
