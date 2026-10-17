import Foundation

/// The next start of a minute, for a view that moves on minute by minute without a `TimelineView` (the drawer,
/// App/Views/Navigation/CalendarDrawer.swift). Time zones differ from UTC by whole minutes, so a minute starts at
/// the same instant everywhere.
enum MinuteTick {
    /// The first start of a minute strictly after `date`.
    static func next(after date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60 + 60)
    }
}
