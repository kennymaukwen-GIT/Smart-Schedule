import SwiftUI

/// Over the composer (chat panel and Quick Capture) while AI data sharing is not allowed: says why the assistant
/// is quiet and opens the consent sheet.
struct ConsentBanner: View {
    var onReview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("The assistant is off until you allow AI data sharing.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(action: onReview) {
                Text("Review")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .chatCardBackground()
    }
}
