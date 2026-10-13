import SwiftUI

/// Main view, the calendar drawer, and the Quick Capture overlay that "spawns" from the Dynamic Island position.
/// Sheets: event detail, accounts (avatar), Settings (drawer › General) and AI consent.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat

    var body: some View {
        @Bindable var router = router
        @Bindable var chat = chat

        ZStack(alignment: .top) {
            MainView()

            if let request = router.quickCapture {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                QuickCaptureView(startsWithVoice: request.startsWithVoice, onClose: close)
                    // Grows out of the island: anchored top-center, starts pill-sized.
                    .transition(.scale(scale: 0.18, anchor: .top).combined(with: .opacity))
                    .zIndex(1)
            }

            if router.isDrawerOpen {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }
                    .transition(.opacity)
                    .zIndex(2)
                CalendarDrawer(onClose: closeDrawer)
                    .transition(.move(edge: .leading))
                    .zIndex(3)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: router.quickCapture)
        .animation(.snappy, value: router.isDrawerOpen)
        .sheet(item: Binding(
            get: { router.selectedEventID.flatMap(schedule.event(id:)) },
            set: { router.selectedEventID = $0?.id }
        )) { event in
            EventDetailSheet(event: event)
        }
        .sheet(item: $router.sheet) { sheet in
            Group {
                switch sheet {
                case .accounts: AccountSheet()
                case .settings: SettingsView()
                }
            }
            .environment(router)
            .environment(schedule)
            .environment(chat)
        }
        .sheet(item: $chat.consentRequest) { _ in
            AIConsentSheet(onAllow: { chat.allowConsent() }, onNotNow: { chat.declineConsent() })
        }
        // A draft made through Siri or a notification shows up here as a card with Add / Keep editing.
        .onChange(of: schedule.pendingPlan) { _, plan in
            chat.syncPendingPlan(plan)
        }
        // Likewise "Ask me first" events, with Add / Edit.
        .onChange(of: schedule.pendingEvents) { _, batch in
            chat.syncPendingEvents(batch)
        }
        // Dates follow Settings › Time zone (Text(date, style:) and pickers read it).
        .environment(\.timeZone, schedule.clock.timeZone)
    }

    private func close() {
        router.quickCapture = nil
    }

    private func closeDrawer() {
        router.isDrawerOpen = false
    }
}
