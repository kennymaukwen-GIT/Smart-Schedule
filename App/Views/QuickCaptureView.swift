import SwiftUI

/// Artboard 4: what the user sees after tapping the island's input pill. The OS can't host a keyboard in
/// the island, so the app opens straight into this island-shaped card (keyboard already up) instead of
/// the full month view, then gets out of the way.
struct QuickCaptureView: View {
    let startsWithVoice: Bool
    let onClose: () -> Void

    @Environment(ChatViewModel.self) private var chat
    @Environment(ScheduleViewModel.self) private var schedule
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var chat = chat
        let day = schedule.focusDay
        let exchange = chat.lastExchange

        VStack(alignment: .leading, spacing: 12) {
            header(day: day)

            Rectangle().fill(Color.white.opacity(0.8)).frame(height: 1)

            DayTimelineView(day: day, events: schedule.events(on: day))
                .frame(height: 200)

            if let user = exchange.user {
                Text(user.text)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surfaceRaised))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if chat.isSending {
                ProgressView().tint(.white)
            } else if let reply = exchange.reply {
                Text(reply.text) // "Added"
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .lineLimit(4)
            }

            ComposerBar(
                text: $chat.draft,
                placeholder: "Type in any plan to add or change",
                isBusy: chat.isSending,
                focus: $inputFocused,
                startsRecording: startsWithVoice,
                onSend: { chat.send() }
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: Theme.islandRadius, style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.islandRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
        )
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .onAppear { if !startsWithVoice { inputFocused = true } }
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height < -40 { onClose() } // flick up = back into the island
        })
    }

    private func header(day: Date) -> some View {
        HStack(alignment: .top) {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white))
            }
            Spacer()
            Text(day.formatted(.dateTime.month(.wide)))
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .padding(.top, 16)
        }
    }
}

/// Hour-grid day view from Artboard 4 (white pills, peach deadlines).
struct DayTimelineView: View {
    let day: Date
    let events: [ScheduleEvent]
    var hourHeight: CGFloat = 56

    private let calendar = WallClock().calendar
    private let gutter: CGFloat = 50

    var body: some View {
        let timed = events.filter { !$0.isAllDay }
        let firstHour = max(0, min(timed.map { calendar.component(.hour, from: $0.start) }.min() ?? 8, 20) - 1)
        let startOfRange = calendar.date(bySettingHour: firstHour, minute: 0, second: 0, of: day) ?? day

        ScrollView(showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(firstHour..<24, id: \.self) { hour in
                        HStack(alignment: .top, spacing: 6) {
                            Text(hourLabel(hour))
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .frame(width: gutter - 8, alignment: .trailing)
                            Rectangle().fill(Color.white.opacity(0.75)).frame(height: 1).padding(.top, 6)
                        }
                        .frame(height: hourHeight, alignment: .top)
                    }
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1, height: CGFloat(24 - firstHour) * hourHeight)
                    .padding(.leading, gutter)

                ForEach(Array(timed.enumerated()), id: \.element.id) { index, event in
                    let minutes = event.start.timeIntervalSince(startOfRange) / 60
                    TimelinePill(event: event)
                        .offset(x: gutter + 10 + CGFloat(overlapColumn(index, in: timed)) * 90,
                                y: CGFloat(minutes / 60) * hourHeight + 8)
                }
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        return date.formatted(.dateTime.hour())
    }

    /// Shift overlapping pills right so they stay readable.
    private func overlapColumn(_ index: Int, in events: [ScheduleEvent]) -> Int {
        events[..<index].filter { $0.overlaps(events[index]) }.count
    }
}

private struct TimelinePill: View {
    let event: ScheduleEvent

    var body: some View {
        Text(event.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.black)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(event.kind == .deadline ? Theme.deadline : Color.white))
    }
}
