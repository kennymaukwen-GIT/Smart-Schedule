import SwiftUI

/// DAY | WEEK | MONTH pill in the Quick Capture header. The lighter selection capsule slides between options.
struct CaptureModePicker: View {
    @Binding var selection: CalendarScope

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CalendarScope.allCases, id: \.self) { scope in
                let isSelected = scope == selection
                Button {
                    withAnimation(.snappy(duration: 0.3)) { selection = scope }
                } label: {
                    Text(scope.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white.opacity(0.36))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.surfaceRaised))
    }
}

extension CalendarScope {
    /// Segment label: DAY / WEEK / MONTH, 日 / 週 / 月 in Chinese (String Catalog).
    var title: LocalizedStringKey {
        switch self {
        case .day: "DAY"
        case .week: "WEEK"
        case .month: "MONTH"
        }
    }
}
