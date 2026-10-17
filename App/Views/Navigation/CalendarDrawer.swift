import SwiftUI
import UIKit

/// The hamburger's drawer (Artboard 5, right): WHAT you see. "General" opens Settings; then "Events", what is on
/// now and next with "All events (N)" pushing the full list (every event still to come, each opening the event
/// page); then one section per Google account, headed by its email (its "…" menu: "Remove account"), listing that
/// account's calendars. The colour square shows or hides a calendar in one tap; the row opens its details (colour
/// on this iPhone, reminders, "Use for new events"). Under the accounts, one line says where sync with Google
/// stands, followed by any change Google refused; last, "Add Google account" opens the add page. A tap on the dimmed
/// rest of the screen, or a swipe towards the edge, closes it.
///
/// Events sit above the accounts: they are what the drawer is opened to manage day to day, and with several
/// accounts the calendars would push them below the fold.
///
/// Gmail events, Tasks and "Apps from Google" from the artboard are not built.
struct CalendarDrawer: View {
    var onClose: () -> Void

    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat
    @Environment(AppRouter.self) private var router
    @State private var path: [DrawerRoute] = []
    /// The "Remove account" confirmation on screen.
    @State private var removal: ScheduleViewModel.AccountRemoval?
    /// Horizontal drag so far (negative = towards the edge); the panel follows it (`DrawerCloseSwipe`).
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                NavigationStack(path: $path) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The drawer's title as a plain heading, not a large navigation title: the drawer was the only
                        // large title in the app, and its collapse starts at the first scroll, where the app froze on
                        // an iPhone. The navigation bar is hidden on this page only.
                        Text("Smart Schedules")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        // Every minute, so an event leaves the Events section once it has ended.
                        TimelineView(.everyMinute) { context in
                            list(now: context.date)
                        }
                    }
                    .background(Theme.surface)
                    // The back button's label on pushed pages; the bar itself is hidden here.
                    .navigationTitle("Smart Schedules")
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: DrawerRoute.self) { route in
                        switch route {
                        case let .calendar(ref): CalendarDetailsView(ref: ref)
                        case .events: AllEventsView()
                        }
                    }
                }
                .frame(width: min(340, geo.size.width * 0.84))
                .background(Theme.surface.ignoresSafeArea())
                .offset(x: drag)
                // Swipe towards the edge to close: a UIKit pan on the window (never a SwiftUI gesture over the List,
                // `DrawerSwipe`). Only on the drawer's first page: rows of "All events" swipe left for Delete and Edit.
                .background(
                    DrawerCloseSwipe(isEnabled: path.isEmpty,
                                     onDrag: { offset in
                                         if offset == 0 {
                                             withAnimation(.snappy) { drag = 0 }
                                         } else {
                                             drag = offset
                                         }
                                     },
                                     onClose: onClose)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                )

                // The rest of the screen, dimmed by RootView: a tap there closes the drawer. It belongs to this layer,
                // which lies over the dim layer and spans the whole screen, so the tap can't miss it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Close"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onClose() }
            }
        }
        // The first page has no text field: it keeps its full height while a keyboard that was up when the drawer
        // opened goes away. "All events" keeps the keyboard's area for its search results.
        .ignoresSafeArea(.keyboard, edges: path.isEmpty ? Edge.Set.bottom : Edge.Set())
        .task {
            // Lists older than 6 h are fetched again; the `.accounts` change then reloads the drawer.
            await AccountManager.shared.refreshCalendarLists(force: false)
            await schedule.reloadAccounts()
        }
    }

    private func list(now: Date) -> some View {
        let rows = schedule.managedRows(now: now)

        return List {
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

            // Signed out (not demo) there is nothing to manage yet: the connect rows below say how to start.
            if schedule.isDemo || !schedule.accounts.isEmpty {
                EventsDrawerSection(rows: rows,
                                    upcoming: schedule.upcomingRows(rows, limit: EventsDrawerSection.rowLimit),
                                    now: now,
                                    clock: schedule.clock,
                                    onOpen: { event in router.selectedEventID = event.id },
                                    onShowAll: { path.append(.events) })
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
        .removeAccountDialog($removal)
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
                                  onOpen: { path.append(.calendar(calendar.id)) })
            }
        } header: {
            accountHeader(account)
        } footer: {
            if missesCalendarList {
                Text("Smart Schedules needs permission to see your calendar list.")
            }
        }
    }

    /// The account's email, with a "…" menu holding "Remove account" (not for the sample accounts).
    private func accountHeader(_ account: GoogleAccount) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: account.email)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !account.isDemo {
                if schedule.syncingBeforeRemoval == account.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Menu {
                        removeButton(account)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text(verbatim: account.email))
                }
            }
        }
        .textCase(nil)
    }

    private func removeButton(_ account: GoogleAccount) -> some View {
        Button(role: .destructive) {
            Task { removal = await schedule.prepareRemoval(of: account) }
        } label: {
            Label("Remove account", systemImage: "person.crop.circle.badge.minus")
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

    /// "Add Google account"; in demo mode "Connect Google Calendar" (the add page leaves the demo when the user
    /// continues); signed out, the two ways in. Each opens the add page as a sheet (the drawer closes).
    @ViewBuilder
    private var connectSection: some View {
        Section {
            if schedule.isDemo {
                Button {
                    router.openSheet(.addAccount)
                } label: {
                    Label("Connect Google Calendar", systemImage: "plus.circle")
                        .foregroundStyle(.white)
                }
            } else if schedule.isSignedIn {
                Button {
                    router.openSheet(.addAccount)
                } label: {
                    Label("Add Google account", systemImage: "plus.circle")
                        .foregroundStyle(.white)
                }
            } else {
                Button {
                    router.openSheet(.addAccount)
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
}

/// The drawer's swipe-to-close: a `UIPanGestureRecognizer` on the window while the drawer is on screen (the same
/// pattern as App/Views/KeyboardDismissSwipe.swift). It only watches: it recognizes alongside the List's scrolling,
/// never cancels or delays touches, and begins only for a sideways drag towards the edge (`DrawerSwipe.begins`), so
/// every vertical drag stays the List's. Taps (General, rows, the dimmed area) are never touched.
private struct DrawerCloseSwipe: UIViewRepresentable {
    var isEnabled: Bool
    var onDrag: (CGFloat) -> Void
    var onClose: () -> Void

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.swipe.isEnabled = isEnabled
        uiView.swipe.onDrag = onDrag
        uiView.swipe.onClose = onClose
    }

    /// Puts the recognizer on the window it is in, and takes it off when the drawer leaves.
    final class HostView: UIView {
        let swipe = DrawerSwipeRecognizer()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            swipe.attach(to: window)
        }
    }
}

/// The window's pan recognizer and its delegate (a recognizer does not keep its target or delegate alive; the host
/// view keeps this).
private final class DrawerSwipeRecognizer: NSObject, UIGestureRecognizerDelegate {
    var isEnabled = true
    var onDrag: (CGFloat) -> Void = { _ in }
    var onClose: () -> Void = {}

    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        return pan
    }()

    func attach(to window: UIWindow?) {
        pan.view?.removeGestureRecognizer(pan)
        window?.addGestureRecognizer(pan)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let dx = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed:
            onDrag(DrawerSwipe.offset(translation: dx))
        case .ended:
            let closes = DrawerSwipe.closes(translation: dx, velocity: pan.velocity(in: pan.view).x)
            onDrag(0)
            if closes { onClose() }
        case .cancelled, .failed:
            onDrag(0)
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        return DrawerSwipe.begins(velocity: pan.velocity(in: pan.view))
    }

    /// Always alongside, never instead of, the List's scrolling or the keyboard swipe.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// What the drawer pushes: a calendar's details, or every event still to come.
enum DrawerRoute: Hashable {
    case calendar(CalendarRef)
    case events
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
