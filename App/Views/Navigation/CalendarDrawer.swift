import SwiftUI

/// The hamburger's drawer (Artboard 5, right): WHAT you see. "General" opens Settings; then one section per
/// Google account, headed by its email, listing that account's calendars. The colour square shows or hides a
/// calendar in one tap; the row opens its details (colour on this iPhone, reminders, "Use for new events").
/// Under the accounts, one line says where sync with Google stands, followed by any change Google refused.
///
/// Gmail events, Tasks and "Apps from Google" from the artboard are not built.
struct CalendarDrawer: View {
    var onClose: () -> Void

    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat
    @Environment(AppRouter.self) private var router
    @State private var path: [CalendarRef] = []
    /// Horizontal drag so far (negative = towards the edge); the panel follows it.
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            NavigationStack(path: $path) {
                list
                    .navigationTitle("Smart Schedule")
                    .navigationBarTitleDisplayMode(.large)
                    .navigationDestination(for: CalendarRef.self) { ref in
                        CalendarDetailsView(ref: ref)
                    }
            }
            .frame(width: min(340, geo.size.width * 0.84))
            .background(Theme.surface.ignoresSafeArea())
            .offset(x: min(0, drag))
            .simultaneousGesture(closeGesture)
        }
        .task {
            // Lists older than 6 h are fetched again; the `.accounts` change then reloads the drawer.
            await AccountManager.shared.refreshCalendarLists(force: false)
            await schedule.reloadAccounts()
        }
    }

    private var list: some View {
        List {
            Section {
                Button {
                    router.openSheet(.settings)
                } label: {
                    HStack(spacing: 12) {
                        DrawerIcon(systemName: "gearshape.fill")
                        Text("General")
                            .foregroundStyle(.white)
                        Spacer(minLength: 8)
                        Chevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(schedule.accounts) { account in
                accountSection(account)
            }

            syncSection

            connectSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
    }

    // MARK: Accounts

    private func accountSection(_ account: GoogleAccount) -> some View {
        // Accounts moved over from the single-account version may not have the calendar-list permission yet.
        let missesCalendarList = !account.isDemo && !account.canListCalendars

        return Section {
            if account.needsReconnect {
                Button {
                    reconnect(account)
                } label: {
                    Label("Reconnect", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            if missesCalendarList {
                Button {
                    reconnect(account)
                } label: {
                    Label("Show all calendars", systemImage: "list.bullet")
                        .foregroundStyle(.white)
                }
            }
            ForEach(account.calendars) { calendar in
                DrawerCalendarRow(calendar: calendar,
                                  onToggle: { schedule.setVisible(!calendar.isVisible, calendar: calendar.id) },
                                  onOpen: { path.append(calendar.id) })
            }
        } header: {
            Text(verbatim: account.email)
                .textCase(nil)
        } footer: {
            if missesCalendarList {
                Text("Smart Schedule needs permission to see your calendar list.")
            }
        }
    }

    // MARK: Sync

    /// The status line ("Synced · just now", "Offline · 3 changes waiting") as the section's header, then one row
    /// per change Google refused, with Retry and Discard. Tapping the line syncs now.
    @ViewBuilder
    private var syncSection: some View {
        if schedule.isDemo || !schedule.accounts.isEmpty {
            Section {
                ForEach(schedule.failedChanges, id: \.id) { change in
                    FailedChangeRow(change: change,
                                    isRetrying: schedule.retryingChangeIDs.contains(change.id),
                                    onRetry: { schedule.retryFailedChange(change.id) },
                                    onDiscard: { withAnimation(.snappy) { schedule.discardFailedChange(change.id) } })
                }
            } header: {
                SyncStatusLine(summary: syncSummary) {
                    Task { await schedule.refresh(.pull) }
                }
                .textCase(nil)
            }
        }
    }

    private var syncSummary: SyncSummary {
        SyncSummary(status: schedule.syncStatus,
                    isDemo: schedule.isDemo,
                    isNetworkOffline: schedule.isNetworkOffline,
                    isSyncing: schedule.isRefreshing,
                    accountIDs: schedule.accounts.filter { !$0.needsReconnect }.map(\.id))
    }

    /// "Add Google account"; in demo mode "Connect Google Calendar" (leaves the demo first); signed out, the two
    /// ways in.
    @ViewBuilder
    private var connectSection: some View {
        Section {
            if schedule.isDemo {
                Button {
                    onClose()
                    chat.disableDemo()
                    Task {
                        await schedule.stopDemo()
                        await schedule.addAccount()
                    }
                } label: {
                    Label("Connect Google Calendar", systemImage: "plus.circle")
                        .foregroundStyle(.white)
                }
            } else if schedule.isSignedIn {
                Button {
                    onClose()
                    Task { await schedule.addAccount() }
                } label: {
                    Label("Add Google account", systemImage: "plus.circle")
                        .foregroundStyle(.white)
                }
            } else {
                Button {
                    onClose()
                    Task { await schedule.addAccount() }
                } label: {
                    Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                        .foregroundStyle(.white)
                }
                Button {
                    onClose()
                    chat.enableDemo()
                    Task { await schedule.startDemo() }
                } label: {
                    Label("Try without signing in", systemImage: "sparkles")
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func reconnect(_ account: GoogleAccount) {
        onClose()
        Task { await schedule.reconnect(accountID: account.id) }
    }

    /// Drag towards the leading edge to close; vertical drags are left to the list.
    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($drag) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -80 || value.predictedEndTranslation.width < -200 { onClose() }
            }
    }
}

/// One calendar in the drawer: its colour square (a toggle), its name, a chevron to its details.
struct DrawerCalendarRow: View {
    let calendar: CalendarInfo
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                CalendarSquare(hex: calendar.displayColorHex, isFilled: calendar.isVisible)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Show \(calendar.displayName)"))
            .accessibilityValue(Text(calendar.isVisible ? "On" : "Off"))
            .accessibilityAddTraits(.isToggle)
            .sensoryFeedback(.impact(weight: .light), trigger: calendar.isVisible)

            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Text(verbatim: calendar.displayName)
                        .foregroundStyle(calendar.isVisible ? Color.white : Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Chevron()
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, -6) // the square's tap area reaches into the row inset
    }
}

/// 14 × 14 colour square with a 3 pt radius; a hidden calendar's is an outline.
struct CalendarSquare: View {
    let hex: String
    var isFilled = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            if isFilled {
                shape.fill(Color(hex: hex))
            } else {
                shape.strokeBorder(Color(hex: hex), lineWidth: 1.5)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// The drawer's rounded icon tile (the General row's gear).
private struct DrawerIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.42)))
    }
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }
}
