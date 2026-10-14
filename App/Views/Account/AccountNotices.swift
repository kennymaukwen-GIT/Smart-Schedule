import SwiftUI

/// A short confirmation: "Connected example@gmail.com", "Removed example@gmail.com" with "New events now go to …"
/// under it. Tap to close; it also goes by itself (`ScheduleViewModel.show(_:)`).
struct NoticeBanner: View {
    let notice: ScheduleViewModel.Notice
    var onDismiss: () -> Void = {}

    var body: some View {
        Button(action: onDismiss) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: notice.text)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let detail = notice.detail {
                        Text(verbatim: detail)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// "Remove account" from the account sheet and the drawer: asks first, saying that Google Calendar keeps everything
/// and how many of the account's changes have not reached Google (with "Sync first"), then removes it.
///
/// Set `removal` from `ScheduleViewModel.prepareRemoval(of:)` to ask.
struct RemoveAccountDialog: ViewModifier {
    @Binding var removal: ScheduleViewModel.AccountRemoval?
    @Environment(ScheduleViewModel.self) private var schedule

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(
            get: { removal != nil },
            set: { if !$0 { removal = nil } }
        ), titleVisibility: .visible, presenting: removal) { request in
            Button("Remove", role: .destructive) {
                Task { await schedule.removeAccount(request.account) }
            }
            if request.unsentChanges > 0 {
                Button("Sync first") {
                    Task {
                        let again = await schedule.syncBeforeRemoving(request.account)
                        // Lets this dialog finish closing before the next one opens (the flush can be instant).
                        try? await Task.sleep(for: .milliseconds(450))
                        removal = again
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(verbatim: Self.message(unsentChanges: request.unsentChanges))
        }
    }

    private var title: Text {
        Text("Remove \(removal?.account.email ?? "")?")
    }

    static func message(unsentChanges: Int) -> String {
        let removed = String(localized: "Its calendars and events leave Smart Schedule on this iPhone. Nothing is deleted in Google Calendar.")
        guard unsentChanges > 0 else { return removed }
        let lost = String(localized: "\(unsentChanges) changes haven't reached Google yet and will be lost.")
        return removed + "\n\n" + lost
    }
}

extension View {
    func removeAccountDialog(_ removal: Binding<ScheduleViewModel.AccountRemoval?>) -> some View {
        modifier(RemoveAccountDialog(removal: removal))
    }
}
