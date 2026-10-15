import SwiftUI

/// "Use the AI assistant?" (App Store guideline 5.1.2(i)): what the assistant sends and to whom, before anything
/// personal reaches Gemini. Shown on the first message without consent and from the composer banner. The user has
/// to choose: the sheet cannot be swiped away.
struct AIConsentSheet: View {
    var onAllow: () -> Void
    var onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                AIConsentDisclosureText(showsTitle: true)
                    .padding(.top, 8)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 10) {
                Button(action: onAllow) {
                    Text("Allow")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onNotNow) {
                    Text("Not now")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .background(Theme.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }
}

/// The disclosure itself (`AIConsentDisclosure`, the single source of the wording): the sheet and Settings › AI &
/// privacy › What is sent both render it.
struct AIConsentDisclosureText: View {
    var showsTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTitle {
                Text(verbatim: AIConsentDisclosure.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(verbatim: AIConsentDisclosure.lead)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.92))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AIConsentDisclosure.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "•")
                            .foregroundStyle(Theme.textSecondary)
                        Text(verbatim: item)
                    }
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.92))
            Label {
                Text(verbatim: AIConsentDisclosure.recipient)
            } icon: {
                Image(systemName: "arrow.up.right.circle")
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            if let note = AIConsentDisclosure.serverNote {
                Label {
                    Text(verbatim: note)
                } icon: {
                    Image(systemName: "server.rack")
                }
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.92))
            }
            Label {
                Text(verbatim: AIConsentDisclosure.speechNote)
            } icon: {
                Image(systemName: "mic")
            }
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.92))
            Text(verbatim: AIConsentDisclosure.footnote)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
