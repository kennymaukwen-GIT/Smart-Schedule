import SwiftUI

/// The end of a conversation, as `ConversationScrollView` watches it.
struct ConversationTail: Equatable {
    var lastID: UUID?
    /// The user's own message always scrolls into view, wherever they had scrolled to.
    var isOwnMessage = false
    var isTyping = false
}

/// A conversation's scroll view, holding the whole history. New messages scroll into view only while the reader
/// is at (or near) the bottom; scrolled up to read, they keep their place and get a "New message ↓" pill that
/// jumps to the end.
struct ConversationScrollView<Content: View>: View {
    let tail: ConversationTail
    /// Bumped to bring `revealID` into view by its bottom edge (a plan card's Add / Keep editing).
    var revealRequest = 0
    var revealID: UUID?
    /// Called as the reader's finger scrolls back up through the history (Quick Capture makes room for it).
    var onScrollBack: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var isAtBottom = true
    @State private var hasUnseen = false
    /// The reader's finger is moving the content (not a programmatic scroll or a bounce).
    @State private var isDragging = false

    private static var bottomID: String { "conversation-bottom" }
    /// This close to the end still counts as reading the newest message.
    private static var slack: CGFloat { 48 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    content()
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
            }
            // Right above the input bar: the keyboard follows a finger dragged down into it, as in Messages, and
            // scrolling back up through the history keeps it (a swipe down hides it anywhere: KeyboardDismissSwipe).
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: ConversationViewport.self) { geometry in
                ConversationViewport(isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - Self.slack,
                                     height: geometry.containerSize.height)
            } action: { old, new in
                if new.height != old.height && old.isAtBottom && !isDragging {
                    // The keyboard or the panel changed the view's height: stay on the newest message.
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    return
                }
                isAtBottom = new.isAtBottom
                if new.isAtBottom { hasUnseen = false }
            }
            .onScrollPhaseChange { _, phase in
                isDragging = phase == .interacting
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { old, new in
                if isDragging && new < old - 1 { onScrollBack?() }
            }
            .onChange(of: tail) { old, new in
                if isAtBottom || new.isOwnMessage {
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                } else if new.lastID != old.lastID {
                    hasUnseen = true
                }
            }
            .onChange(of: revealRequest) {
                guard let revealID else { return }
                withAnimation(.snappy) { proxy.scrollTo(revealID, anchor: .bottom) }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if hasUnseen {
                    NewMessagePill {
                        withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: hasUnseen)
        }
    }
}

private struct ConversationViewport: Equatable {
    var isAtBottom: Bool
    var height: CGFloat
}

/// "New message ↓": shown while the reader is scrolled up and a reply arrives below.
private struct NewMessagePill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("New message ↓")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
