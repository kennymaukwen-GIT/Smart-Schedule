import SwiftUI

// Pieces shared by Quick Capture's WEEK and MONTH cards.

/// Very dark card behind the WEEK and MONTH grids. Gradients stand in for the photo in the design.
struct CaptureCardBackground: View {
    static let radius: CGFloat = 16

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#07090B"), Color(hex: "#121A1F"), Color(hex: "#1D2A2F")],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: "#2F4A50").opacity(0.55), .clear],
                           center: .bottomTrailing, startRadius: 8, endRadius: 260)
            RadialGradient(colors: [Color(hex: "#3A3550").opacity(0.35), .clear],
                           center: .bottomLeading, startRadius: 4, endRadius: 180)
            RadialGradient(colors: [Color.white.opacity(0.05), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 200)
        }
    }
}

/// Tasks get a red-orange check circle in the WEEK and MONTH cards (design 04), whatever their calendar color.
enum CaptureChipStyle {
    static let taskTint = Color(hex: "#FF6A4D")
}

/// Date number of a grid column: today is a white disc with a black number, the focus day gets a ring.
struct CaptureDayNumber: View {
    let day: Date
    let calendar: Calendar
    var isToday = false
    var isFocused = false
    var diameter: CGFloat = 20
    var fontSize: CGFloat = 11

    var body: some View {
        Text("\(calendar.component(.day, from: day))")
            .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
            .foregroundStyle(isToday ? Color.black : Color.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(isToday ? Color.white : Color.clear))
            .overlay {
                if isFocused && !isToday {
                    Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                }
            }
            .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).month(.wide).day()))
    }
}

/// One multi-day event drawn across its columns; square ends where it carries on into the next/previous week.
struct CaptureSpanBar: View {
    let span: CalendarPaging.WeekSpan
    var fontSize: CGFloat = 7

    var body: some View {
        let radius: CGFloat = 3
        HStack(spacing: 2) {
            if span.event.isWaitingToSync && !span.continuesBefore {
                PendingSyncGlyph(size: fontSize - 1, color: .white.opacity(0.85))
            }
            Text(span.event.title)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: span.continuesBefore ? 0 : radius,
                bottomLeading: span.continuesBefore ? 0 : radius,
                bottomTrailing: span.continuesAfter ? 0 : radius,
                topTrailing: span.continuesAfter ? 0 : radius
            ))
            .fill(Color(hex: span.event.colorHex).opacity(0.9))
        )
        .draftGhost(span.event.isDraft, shape: RoundedRectangle(cornerRadius: radius),
                    tint: Color(hex: span.event.colorHex))
    }
}

/// The bars of one week row, laid over seven equal columns. Lanes at or past `visibleLanes` are left out.
struct CaptureSpanBars: View {
    let spans: [CalendarPaging.WeekSpan]
    var visibleLanes = Int.max
    var barHeight: CGFloat = 12
    var laneSpacing: CGFloat = 2
    var topInset: CGFloat = 0
    var fontSize: CGFloat = 7
    var onSelect: (ScheduleEvent) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let column = geo.size.width / 7
            ForEach(spans.filter { $0.lane < visibleLanes }) { span in
                CaptureSpanBar(span: span, fontSize: fontSize)
                    .frame(width: max(0, column * CGFloat(span.columnCount) - 3), height: barHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(span.event) }
                    .offset(x: column * CGFloat(span.firstColumn) + 1.5,
                            y: topInset + CGFloat(span.lane) * (barHeight + laneSpacing))
            }
        }
    }
}
