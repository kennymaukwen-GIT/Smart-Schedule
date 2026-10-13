import SwiftUI

/// Main view + the Quick Capture overlay that "spawns" from the Dynamic Island position.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat

    var body: some View {
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
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: router.quickCapture)
        .sheet(item: Binding(
            get: { router.selectedEventID.flatMap(schedule.event(id:)) },
            set: { router.selectedEventID = $0?.id }
        )) { event in
            EventDetailSheet(event: event)
        }
        // A draft made through Siri or a notification shows up here as a card with Add / Keep editing.
        .onChange(of: schedule.pendingPlan) { _, plan in
            chat.syncPendingPlan(plan)
        }
    }

    private func close() {
        router.quickCapture = nil
    }
}
