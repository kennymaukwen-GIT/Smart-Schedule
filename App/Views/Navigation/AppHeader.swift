import SwiftUI

/// Artboard 5's header: the hamburger opens the calendar drawer (what you see), the title names the month on
/// screen ("2027 October" / "2027年10月"), and the avatar opens accounts and subscription (who you are). A tiny
/// sync mark follows the title only while changes wait for Google or Google refused one.
struct AppHeader: View {
    let month: Date
    let calendar: Calendar
    /// The first account's initial; nil shows a person glyph (signed out, demo mode).
    let avatarInitial: String?
    var onMenu: () -> Void = {}
    var onAvatar: () -> Void = {}
    /// nil: everything is in Google (the usual case), so nothing is drawn.
    var syncIndicator: SyncHeaderIndicator? = nil
    /// Opens the drawer, where the status line and any failed changes are.
    var onSyncIndicator: () -> Void = {}

    @Environment(\.locale) private var environmentLocale

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onMenu) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceRaised))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Calendars")

            Text(verbatim: CalendarPaging.headerTitle(month, calendar: calendar,
                                                      locale: ChatFormat.dateLocale(environmentLocale)))
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .accessibilityAddTraits(.isHeader)

            if let syncIndicator {
                SyncHeaderIndicatorView(indicator: syncIndicator, action: onSyncIndicator)
                    .padding(.leading, -6)
            }

            Spacer(minLength: 8)

            Button(action: onAvatar) {
                AccountAvatar(initial: avatarInitial, size: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Accounts and subscription")
        }
        .frame(minHeight: 44)
        .animation(.snappy, value: syncIndicator)
    }
}

/// A round initial ("K"), or a person glyph when there is no account to name.
struct AccountAvatar: View {
    let initial: String?
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Theme.surfaceRaised)
            Circle().strokeBorder(Theme.hairline, lineWidth: 1)
            if let initial {
                Text(verbatim: initial)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}
