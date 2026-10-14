import Foundation

/// What removing a Google account changes beyond the account itself (pure, unit-tested). The removal is
/// `AccountManager.disconnect(accountID:)`; the confirmation and the "Removed …" notice use this.
enum AccountRemovalEffects {
    /// Where new events go once the account is gone, when that changes because the calendar they went to belonged
    /// to it: the one picked in Settings (reset to automatic by the removal) or, automatically, its primary
    /// calendar as the first account. nil when nothing changes or no account is left.
    static func newEventsTarget(before: CalendarInfo?, after: CalendarInfo?, removedAccountID: String) -> CalendarInfo? {
        guard let before, before.accountID == removedAccountID,
              let after, after.accountID != removedAccountID else { return nil }
        return after
    }

    /// "My calendar · example@yourmail.com": names the calendar and its account, as the pending events card does.
    static func label(_ calendar: CalendarInfo) -> String {
        "\(calendar.displayName) · \(calendar.accountEmail)"
    }
}
