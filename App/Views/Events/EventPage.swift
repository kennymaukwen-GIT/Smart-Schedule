import SwiftUI

/// The one page for an event: everything about it, editable in place. Opened from a chip in any calendar view, the
/// drawer's Events section, the events list and the chat's "Manage" button (always through `EventDetailSheet`).
///
/// Title, all day, start and end, location, reminders and notes can be changed; Save writes through the same path
/// as the assistant (`ScheduleViewModel.updateEvent`: Google with If-Match, or the outbox while offline, where the
/// event shows "Waiting to sync"). An event of a repeating series shows its rule and saves to "This event" or "All
/// events". The calendar is shown, not changed. In a calendar the account can only read, the page is read-only.
/// Closing with unsaved changes asks "Discard changes?".
///
/// Under the notes, "Suggested" offers what the event may need ("+ Bring passport" for a trip abroad, "+ Bring
/// water" for the gym): a tap adds "• Bring passport" to the notes, which Save keeps like any other change.
/// "AI suggestions" asks Gemini for more (after the AI consent; demo mode and offline: Smart Schedule's rules).
struct EventPage: View {
    /// The cached event; it changes when the cache does (a sync, a change elsewhere).
    let event: ScheduleEvent

    @Environment(ScheduleViewModel.self) private var schedule
    /// Asks for note suggestions with the assistant the chat uses; absent in previews of the page alone.
    @Environment(ChatViewModel.self) private var chat: ChatViewModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale

    /// The event the draft started from, and the draft as it was then: changes are what differs from it.
    @State private var baseline: ScheduleEvent
    @State private var original: EventPageDraft
    @State private var draft: EventPageDraft
    @State private var scope: EditScope = .thisEvent
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false
    @State private var pendingDelete: ScheduleEvent?
    @State private var failure: Failure?
    /// The "Suggested" row under the notes.
    @State private var noteSuggestions: NoteSuggestionsModel
    @FocusState private var focus: Field?
    /// About five lines of body text.
    @ScaledMetric(relativeTo: .body) private var notesMinHeight: CGFloat = 120

    private let clock = WallClock()

    /// "Add reminder" choices, in minutes before the start; all-day: before 00:00 of the day.
    private static let reminderChoices = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10_080]
    private static let allDayReminderChoices = [0, 720, 900, 2340, 9540]
    private static let maxReminders = ReminderPolicy.googleMaxOverrides

    private enum Field: Hashable {
        case title, location, notes
    }

    private struct Failure: Identifiable {
        let id = UUID()
        var title: LocalizedStringKey
        var message: String
    }

    /// `noteSuggestions`: previews pass one in a given state.
    init(event: ScheduleEvent, noteSuggestions: NoteSuggestionsModel? = nil) {
        self.event = event
        let draft = EventPageDraft(event, clock: WallClock())
        _baseline = State(initialValue: event)
        _original = State(initialValue: draft)
        _draft = State(initialValue: draft)
        _noteSuggestions = State(initialValue: noteSuggestions ?? NoteSuggestionsModel(event: event))
    }

    private var isReadOnly: Bool { schedule.isReadOnly(baseline) }
    private var isSeries: Bool { baseline.seriesID != nil }
    /// "All events" moves every occurrence to a new time of day; their days and all-day stay as they are.
    private var editsWholeSeries: Bool { isSeries && scope == .allEvents }
    private var isDirty: Bool { !isReadOnly && draft.hasChanges(from: original) }
    private var canSave: Bool { isDirty && draft.isValid && !isSaving }

    var body: some View {
        Form {
            if isReadOnly {
                Section {
                    Label("You can't change events in this calendar.", systemImage: "lock")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            titleSection
            timeSection
            if isSeries { repeatSection }
            placeSection
            remindersSection
            notesSection
            linksSection
            if !isReadOnly { deleteSection }
        }
        .disabled(isSaving)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(Text("Event"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .interactiveDismissDisabled(isDirty || isSaving)
        .confirmationDialog(Text("Discard changes?"), isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .eventDeleteDialog($pendingDelete) { event, scope in delete(event, scope: scope) }
        .alert(Text(failure?.title ?? ""), isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        ), presenting: failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        // Over this page, not the root view: the page is a sheet already.
        .sheet(item: Binding(
            get: { noteSuggestions.consentPrompt },
            set: { noteSuggestions.consentPrompt = $0 }
        )) { _ in
            AIConsentSheet(onAllow: {
                noteSuggestions.allowConsent()
                chat?.refreshConsent()
            }, onNotNow: {
                noteSuggestions.declineConsent()
                chat?.refreshConsent()
            })
        }
        .onChange(of: scope) { _, scope in
            if scope == .allEvents { draft.keepDays(of: original, clock: clock) }
        }
        .onChange(of: event) { _, latest in
            // Synced or changed elsewhere while open: shown as long as nothing here is being edited.
            guard !isDirty, !isSaving else { return }
            baseline = latest
            original = EventPageDraft(latest, clock: clock)
            draft = original
        }
    }

    // MARK: Sections

    private var titleSection: some View {
        Section {
            TextField("Title", text: $draft.title)
                .font(.title3.weight(.semibold))
                .focused($focus, equals: .title)
                .submitLabel(.done)
                .disabled(isReadOnly)
            if baseline.isWaitingToSync {
                Label("Waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var timeSection: some View {
        Section {
            Toggle("All day", isOn: Binding(
                get: { draft.isAllDay },
                set: { draft.setAllDay($0, from: baseline, clock: clock) }
            ))
            .disabled(editsWholeSeries)
            Group {
                DatePicker("Starts",
                           selection: Binding(get: { draft.start }, set: { draft.moveStart(to: $0, clock: clock) }),
                           displayedComponents: pickerComponents)
                DatePicker("Ends",
                           selection: Binding(get: { draft.end }, set: { draft.setEnd($0, clock: clock) }),
                           in: draft.start...,
                           displayedComponents: pickerComponents)
            }
            .disabled(editsWholeSeries && draft.isAllDay)
        } footer: {
            if !draft.hasValidTimes {
                Text("The end must be after the start.")
                    .foregroundStyle(.red)
            }
        }
        // 24-hour, like every time the app writes.
        .environment(\.locale, Self.twentyFourHour(locale))
        .disabled(isReadOnly)
    }

    private var pickerComponents: DatePickerComponents {
        if draft.isAllDay { return [.date] }
        return editsWholeSeries ? [.hourAndMinute] : [.date, .hourAndMinute]
    }

    private var repeatSection: some View {
        Section {
            LabeledContent {
                Text(verbatim: schedule.repeatSummary(of: baseline, locale: ChatFormat.dateLocale(locale)) ?? "")
            } label: {
                Text("Repeat")
            }
            if !isReadOnly {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save changes to")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Save changes to", selection: $scope) {
                        Text("This event").tag(EditScope.thisEvent)
                        Text("All events").tag(EditScope.allEvents)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.vertical, 2)
            }
        } footer: {
            if !isReadOnly && scope == .allEvents {
                Text("A new time applies to every event in the series. Their dates stay the same.")
            }
        }
    }

    private var placeSection: some View {
        Section {
            if let calendar = schedule.calendarInfo(of: baseline) {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            CalendarSquare(hex: calendar.displayColorHex)
                            Text(verbatim: calendar.displayName)
                                .lineLimit(1)
                        }
                        Text(verbatim: calendar.accountEmail)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } label: {
                    Text("Calendar")
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                TextField("Location", text: $draft.location)
                    .focused($focus, equals: .location)
                    .submitLabel(.done)
            }
            .disabled(isReadOnly)
        }
    }

    private var remindersSection: some View {
        let minutes = (draft.reminderMinutes ?? defaultReminders).sorted(by: >)
        let choices = (draft.isAllDay ? Self.allDayReminderChoices : Self.reminderChoices).filter { !minutes.contains($0) }

        return Section {
            if minutes.isEmpty {
                Text("None")
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(minutes, id: \.self) { offset in
                Label {
                    Text(verbatim: ReminderText.offset(offset, allDay: draft.isAllDay))
                } icon: {
                    Image(systemName: "bell")
                }
                .deleteDisabled(isReadOnly)
            }
            .onDelete { indices in
                draft.reminderMinutes = minutes.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
            }
            if !isReadOnly {
                Menu {
                    ForEach(choices, id: \.self) { offset in
                        Button(ReminderText.offset(offset, allDay: draft.isAllDay)) {
                            draft.reminderMinutes = (minutes + [offset]).sorted(by: >)
                        }
                    }
                } label: {
                    Label("Add reminder", systemImage: "plus.circle")
                }
                .disabled(minutes.count >= Self.maxReminders || choices.isEmpty)
                if draft.reminderMinutes != nil {
                    Button("Use default reminders") {
                        draft.reminderMinutes = nil
                    }
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            if draft.reminderMinutes == nil {
                Text("Default reminders from Settings › Notifications.")
            }
        }
    }

    /// Settings › Notifications for this kind of event (all-day: the all-day reminder).
    private var defaultReminders: [Int] {
        let policy = ReminderPolicy(preferences: PreferencesStore.shared.current())
        return draft.isAllDay ? policy.allDayDefaults : policy.defaults(for: baseline.kind)
    }

    private var notesSection: some View {
        let chips = isReadOnly ? [] : suggestedChips
        return Section {
            if isReadOnly {
                if draft.notes.isEmpty {
                    Text("None")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(verbatim: draft.notes)
                        .textSelection(.enabled)
                }
            } else {
                // Grows with the text from about five lines.
                TextEditor(text: $draft.notes)
                    .focused($focus, equals: .notes)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: notesMinHeight)
                    .overlay(alignment: .topLeading) {
                        if draft.notes.isEmpty {
                            Text("Add details…")
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(Text("Notes"))
                NoteSuggestionsRow(model: noteSuggestions, chips: chips, onAdd: addSuggestion,
                                   onRequest: requestSuggestions)
            }
        } header: {
            Text("Notes")
        } footer: {
            if !chips.isEmpty {
                Text("Tap a suggestion to add it to the notes, then Save.")
            }
        }
    }

    // MARK: Suggested notes

    /// The event as edited so far: suggestions follow the title, place, time and notes being typed.
    private var suggestionSubject: ScheduleEvent {
        var event = baseline
        let span = draft.span(clock: clock)
        event.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.location
        event.notes = EventNotes.joining(provenance: draft.provenance, userNotes: draft.notes)
        event.start = span.start
        event.end = span.end
        event.isAllDay = draft.isAllDay
        return event
    }

    /// The app's language, for an event whose title says nothing either way.
    private var prefersChinese: Bool {
        ReplyFormatter.isChinese(ChatFormat.dateLocale(locale))
    }

    private var suggestedChips: [NoteSuggestion] {
        noteSuggestions.chips(for: suggestionSubject, notes: draft.notes, preferChinese: prefersChinese,
                              homeTimeZone: clock.timeZone)
    }

    /// A chip: "• item" on a line of its own at the end of the notes; Save keeps it.
    private func addSuggestion(_ chip: NoteSuggestion) {
        draft.notes = NoteSuggester.appending(chip.text, to: draft.notes)
    }

    /// "AI suggestions": through the chat's assistant (the demo one in demo mode), else the mode's own.
    private func requestSuggestions() {
        focus = nil
        let subject = suggestionSubject
        let chat = chat
        let isDemo = schedule.isDemo || AppConstants.isDemoMode
        noteSuggestions.requestSuggestions(
            for: subject,
            notes: draft.notes,
            shown: suggestedChips,
            preferChinese: prefersChinese,
            homeTimeZone: clock.timeZone,
            isDemo: isDemo,
            isOffline: schedule.isNetworkOffline,
            fetch: { event in
                if let chat { return try await chat.suggestNotes(for: event) }
                let assistant: any ScheduleAssisting = isDemo ? DemoAssistant() : ScheduleAssistant.shared
                return try await assistant.suggestNotes(for: event)
            }
        )
    }

    /// Google Meet, Google Calendar and any link written in the notes (where the event came from), as rows to tap.
    @ViewBuilder
    private var linksSection: some View {
        let noteLinks = EventLinks.urls(in: EventNotes.joining(provenance: original.provenance, userNotes: original.notes) ?? "")
            .filter { $0 != baseline.meetURL }
        if baseline.meetURL != nil || baseline.htmlLink != nil || baseline.planID != nil || !noteLinks.isEmpty {
            Section {
                if let meet = baseline.meetURL {
                    Button { openURL(meet) } label: { Label("Join Google Meet", systemImage: "video") }
                }
                ForEach(noteLinks, id: \.self) { url in
                    Button { openURL(url) } label: {
                        Label {
                            Text(verbatim: EventLinks.label(url))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "link")
                        }
                    }
                }
                if let link = baseline.htmlLink {
                    Button { openURL(link) } label: {
                        Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                    }
                }
                if baseline.planID != nil {
                    Label("Part of a long-term plan", systemImage: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                focus = nil
                pendingDelete = baseline
            } label: {
                Label("Delete event", systemImage: "trash")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isDirty {
                Button("Cancel") { isConfirmingDiscard = true }
            } else {
                Button("Close") { dismiss() }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView()
            } else if !isReadOnly {
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .disabled(!canSave)
            }
        }
    }

    // MARK: Actions

    private func save() {
        guard canSave else { return }
        focus = nil
        let edit = draft.edit(from: original, clock: clock)
        let target = baseline
        let editScope = isSeries ? scope : .thisEvent
        isSaving = true
        Task {
            do {
                _ = try await schedule.updateEvent(target, with: edit, scope: editScope)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                failure = Failure(title: "Couldn't save", message: error.localizedDescription)
            }
        }
    }

    private func delete(_ event: ScheduleEvent, scope: EditScope) {
        isSaving = true
        Task {
            do {
                try await schedule.deleteEvent(event, scope: scope)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                failure = Failure(title: "Couldn't delete", message: error.localizedDescription)
            }
        }
    }

    /// `locale` reading hours 00–23, so the pickers match the 24-hour times everywhere else.
    private static func twentyFourHour(_ locale: Locale) -> Locale {
        var components = Locale.Components(locale: locale)
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }
}

// MARK: - Draft

/// What the page edits. All-day events keep their last day (inclusive) in `end`, as the end picker shows it;
/// `span` turns it back into the exclusive end the cache and Google use.
struct EventPageDraft: Equatable {
    var title: String
    var isAllDay: Bool
    var start: Date
    var end: Date
    var location: String
    /// Plain text: Google's description as `EventNotes` reads it, saved back as plain text. Without Smart Schedule's
    /// provenance line, which is kept apart and written back on save.
    var notes: String
    /// "由 Smart Schedules 智慧助理自動排程：…" (or the older "由 Smart Schedule …"): stays in Google Calendar, hidden from
    /// the notes editor.
    var provenance: String?
    /// nil: the kind's default reminders; [] none.
    var reminderMinutes: [Int]?

    init(_ event: ScheduleEvent, clock: WallClock) {
        title = event.title
        isAllDay = event.isAllDay
        if event.isAllDay {
            let calendar = clock.calendar
            start = calendar.startOfDay(for: event.start)
            end = EventEdit.lastDay(ofAllDayEnd: event.end, start: event.start, calendar: calendar)
        } else {
            start = event.start
            end = event.end
        }
        location = event.location ?? ""
        // Already plain text when cached by this version; older caches may still hold Google's HTML.
        let fullNotes = EventNotes.plainText(fromDescription: event.notes)
        provenance = EventNotes.provenanceLine(fullNotes)
        notes = EventNotes.withoutProvenance(fullNotes) ?? ""
        reminderMinutes = event.reminderMinutes
    }

    /// Changed in a way that saves differently (spaces around the title or the notes do not count).
    func hasChanges(from original: EventPageDraft) -> Bool {
        titleChanged(from: original) || timesChanged(from: original) || locationChanged(from: original)
            || notesChanged(from: original) || reminderMinutes != original.reminderMinutes
    }

    private func titleChanged(from original: EventPageDraft) -> Bool {
        Self.trimmed(title) != Self.trimmed(original.title)
    }

    private func timesChanged(from original: EventPageDraft) -> Bool {
        isAllDay != original.isAllDay || start != original.start || end != original.end
    }

    private func locationChanged(from original: EventPageDraft) -> Bool {
        Self.trimmed(location) != Self.trimmed(original.location)
    }

    private func notesChanged(from original: EventPageDraft) -> Bool {
        EventNotes.normalized(notes) != EventNotes.normalized(original.notes)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasValidTimes: Bool { isAllDay ? end >= start : end > start }
    var isValid: Bool { hasValidTimes && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Start and (exclusive) end as stored.
    func span(clock: WallClock) -> (start: Date, end: Date) {
        guard isAllDay else { return (start, end) }
        let calendar = clock.calendar
        return (calendar.startOfDay(for: start), EventEdit.allDayEnd(lastDay: max(start, end), calendar: calendar))
    }

    /// For "All events": back on the occurrence's own days (and all-day or not), keeping a new time of day and
    /// length, since a series edit moves only the time.
    mutating func keepDays(of original: EventPageDraft, clock: WallClock) {
        guard isAllDay == original.isAllDay, !isAllDay else {
            isAllDay = original.isAllDay
            start = original.start
            end = original.end
            return
        }
        let parts = clock.calendar.dateComponents([.hour, .minute], from: start)
        let length = end.timeIntervalSince(start)
        let moved = clock.combine(day: original.start, time: (parts.hour ?? 0, parts.minute ?? 0)) ?? original.start
        start = moved
        end = moved.addingTimeInterval(length)
    }

    /// A new start keeps the length: the end moves with it.
    mutating func moveStart(to newStart: Date, clock: WallClock) {
        if isAllDay {
            let calendar = clock.calendar
            let day = calendar.startOfDay(for: newStart)
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: day).day ?? 0
            start = day
            end = calendar.date(byAdding: .day, value: days, to: end) ?? end
        } else {
            end = end.addingTimeInterval(newStart.timeIntervalSince(start))
            start = newStart
        }
    }

    mutating func setEnd(_ newEnd: Date, clock: WallClock) {
        end = isAllDay ? clock.calendar.startOfDay(for: newEnd) : newEnd
    }

    /// All day on: the days the event touches. Off: the event's own time of day and length when it had one,
    /// otherwise 09:00 for an hour.
    mutating func setAllDay(_ isOn: Bool, from event: ScheduleEvent, clock: WallClock) {
        guard isOn != isAllDay else { return }
        let calendar = clock.calendar
        if isOn {
            let first = calendar.startOfDay(for: start)
            // An event ending at 00:00 ends on the day before.
            let lastInstant = end > start ? end.addingTimeInterval(-1) : start
            start = first
            end = max(first, calendar.startOfDay(for: lastInstant))
        } else {
            var time = (hour: 9, minute: 0)
            var length: TimeInterval = 3600
            if !event.isAllDay {
                let parts = calendar.dateComponents([.hour, .minute], from: event.start)
                time = (parts.hour ?? 9, parts.minute ?? 0)
                length = max(event.duration, 300)
            }
            let newStart = clock.combine(day: start, time: time) ?? start
            start = newStart
            end = newStart.addingTimeInterval(length)
        }
        isAllDay = isOn
    }

    /// Only what changed since `original`; a cleared location or note is removed.
    func edit(from original: EventPageDraft, clock: WallClock) -> EventEdit {
        var edit = EventEdit()
        if titleChanged(from: original), !Self.trimmed(title).isEmpty {
            edit.title = Self.trimmed(title)
        }
        if timesChanged(from: original) {
            let span = span(clock: clock)
            edit.start = span.start
            edit.end = span.end
            edit.isAllDay = isAllDay
        }
        if locationChanged(from: original) {
            let place = Self.trimmed(location)
            edit.location = .some(place.isEmpty ? nil : place)
        }
        if notesChanged(from: original) {
            edit.notes = .some(EventNotes.joining(provenance: provenance, userNotes: notes))
        }
        if reminderMinutes != original.reminderMinutes {
            edit.reminderMinutes = .some(reminderMinutes)
        }
        return edit
    }
}

// MARK: - Links in notes

/// Web links written in an event's notes (where a pasted event came from), shown as rows to tap.
enum EventLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func urls(in text: String) -> [URL] {
        guard let detector, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<URL>()
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .filter { $0.scheme == "https" || $0.scheme == "http" }
            .filter { seen.insert($0).inserted }
            .prefix(5)
            .map { $0 }
    }

    /// "example.com/tickets" for a row.
    static func label(_ url: URL) -> String {
        let host = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
        let path = url.path == "/" ? "" : url.path
        return host + path
    }
}
