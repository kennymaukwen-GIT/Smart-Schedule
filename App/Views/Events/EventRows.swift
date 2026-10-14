import SwiftUI

/// When an event happens, compactly, for the drawer and the events list: "Now · until 15:00", "Today 14:00",
/// "Tomorrow 09:00", "Wed, Oct 16 09:00" / 「進行中 · 到 15:00」「今天 14:00」「10月16日（週三）09:00」; all-day
/// events "Today · All day". 24-hour times in Settings › Time zone. A `Text`, so the zh-Hant previews (which set
/// `\.locale`) read in Chinese too.
struct EventWhenText: View {
    let event: ScheduleEvent
    let now: Date
    var clock = WallClock()

    @Environment(\.locale) private var environmentLocale

    var body: some View {
        Self.text(event, now: now, clock: clock, locale: ChatFormat.dateLocale(environmentLocale))
    }

    static func text(_ event: ScheduleEvent, now: Date, clock: WallClock, locale: Locale) -> Text {
        let calendar = clock.calendar
        let isChinese = ReplyFormatter.isChinese(locale)
        let today = calendar.startOfDay(for: now)

        func dayOffset(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? .max
        }
        func dayName(_ date: Date) -> Text {
            switch dayOffset(date) {
            case 0: return Text("Today")
            case 1: return Text("Tomorrow")
            default: return Text(verbatim: ReplyFormatter.dayLabel(date, clock: clock, locale: locale))
            }
        }
        func dayAndTime(_ date: Date) -> Text {
            let time = ReplyFormatter.clockTime(date, clock: clock)
            switch dayOffset(date) {
            case 0: return Text("Today \(time)")
            case 1: return Text("Tomorrow \(time)")
            default:
                let day = ReplyFormatter.dayLabel(date, clock: clock, locale: locale)
                // Chinese closes the day with "）", so the time follows directly.
                return Text(verbatim: isChinese ? day + time : day + " " + time)
            }
        }

        let isHappening = event.start <= now && now < event.end
        if event.isAllDay {
            // All-day ends are exclusive: an event on Oct 14 ends at Oct 15 00:00.
            let lastDay = calendar.date(byAdding: .day, value: -1, to: event.end).map { calendar.startOfDay(for: $0) }
                ?? calendar.startOfDay(for: event.start)
            if isHappening && lastDay > today {
                let until = ReplyFormatter.dayLabel(lastDay, clock: clock, locale: locale)
                return Text("Now · until \(until)")
            }
            return dayName(isHappening ? now : event.start) + Text(verbatim: " · ") + Text("All day")
        }
        if isHappening {
            let until = calendar.isDate(event.end, inSameDayAs: now)
                ? Text(verbatim: ReplyFormatter.clockTime(event.end, clock: clock))
                : dayAndTime(event.end)
            return Text("Now · until \(until)")
        }
        return dayAndTime(event.start)
    }
}

/// The calendar's colour as a small dot, the title, when it is, and glyphs for a repeating event and for a change
/// still waiting to sync. The drawer and the events list both use it; the list adds a line under the title.
struct ManagedEventRowView<Detail: View>: View {
    let event: ScheduleEvent
    var isSeries = false
    var isHappeningNow = false
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Color(hex: event.colorHex))
                .frame(width: 9, height: 9)
                .overlay {
                    // A ring marks what is on right now.
                    if isHappeningNow {
                        Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5).padding(-3)
                    }
                }
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(event.title)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if isSeries {
                        Image(systemName: "repeat")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityLabel(Text("Repeating"))
                    }
                    if event.isWaitingToSync {
                        PendingSyncGlyph(size: 11, color: Theme.textSecondary)
                    }
                }
                detail
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A section of the events list: Now, Today, Tomorrow, This week, Later, Repeating. The keys of
/// `ManagedEventSection.title`, as `Text` so the zh-Hant previews read in Chinese too.
struct ManagedEventSectionTitle: View {
    let section: ManagedEventSection

    var body: some View {
        switch section {
        case .now: Text("Now")
        case .today: Text("Today")
        case .tomorrow: Text("Tomorrow")
        case .thisWeek: Text("This week")
        case .later: Text("Later")
        case .repeating: Text("Repeating")
        }
    }
}

/// "Next: Sat, Oct 18" / 「下一次：10月18日（週六）」 for a repeating series in the events list.
struct NextOccurrenceText: View {
    let start: Date
    var clock = WallClock()

    @Environment(\.locale) private var environmentLocale

    var body: some View {
        let day = ReplyFormatter.dayLabel(start, clock: clock, locale: ChatFormat.dateLocale(environmentLocale))
        Text("Next: \(day)")
    }
}
