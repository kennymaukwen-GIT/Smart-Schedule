import StoreKit
import SwiftUI

/// The avatar's sheet: WHO you are. Connected Google accounts (reconnect, remove, add another on a pushed page) and,
/// when `AppConstants.subscriptionsEnabled` (off in version 1.0), Smart Schedules Pro (status, restore, manage, terms).
/// Subscriptions are infrastructure only: nothing is gated. Terms of Use and Privacy Policy are always in
/// Settings › About.
struct AccountSheet: View {
    @Environment(ScheduleViewModel.self) private var schedule
    @Environment(ChatViewModel.self) private var chat
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Pages pushed inside the sheet. Value-based, so the add page stays open when leaving the demo swaps the rows.
    private enum Page: Hashable {
        case addAccount
    }

    /// The "Remove account" confirmation on screen.
    @State private var removal: ScheduleViewModel.AccountRemoval?
    @State private var isRestoring = false
    @State private var restoreFoundNothing = false
    @State private var showsManageSubscriptions = false

    private var subscriptions: SubscriptionStore { .shared }

    /// `removal`: previews open with the confirmation showing.
    init(removal: ScheduleViewModel.AccountRemoval? = nil) {
        _removal = State(initialValue: removal)
    }

    var body: some View {
        NavigationStack {
            List {
                accountsSection
                // Version 1.0 sells nothing (AppConstants.subscriptionsEnabled): no Pro section, no StoreKit testing.
                if AppConstants.subscriptionsEnabled {
                    proSection
                    #if DEBUG
                    storeKitTestingSection
                    #endif
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .addAccount: AddAccountView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .removeAccountDialog($removal)
            .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
            .safeAreaInset(edge: .bottom) {
                if let notice = schedule.notice {
                    NoticeBanner(notice: notice) { schedule.dismissNotice() }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: schedule.notice)
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    // MARK: Google accounts

    @ViewBuilder
    private var accountsSection: some View {
        Section {
            if schedule.isDemo {
                HStack {
                    Label("Demo mode is on", systemImage: "theatermasks")
                    Spacer(minLength: 8)
                    Button("Exit demo") {
                        chat.disableDemo()
                        Task { await schedule.stopDemo() }
                    }
                    .buttonStyle(.bordered)
                }
                // The add page leaves the demo when the user continues.
                NavigationLink(value: Page.addAccount) {
                    Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                }
            } else if schedule.accounts.isEmpty {
                NavigationLink(value: Page.addAccount) {
                    Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                }
                Button {
                    dismiss()
                    chat.enableDemo()
                    Task { await schedule.startDemo() }
                } label: {
                    Label("Try without signing in", systemImage: "sparkles")
                }
            } else {
                ForEach(schedule.accounts) { account in
                    accountRow(account)
                }
                NavigationLink(value: Page.addAccount) {
                    Label("Add Google account", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Google accounts")
        }
    }

    private func accountRow(_ account: GoogleAccount) -> some View {
        HStack(spacing: 12) {
            AccountAvatar(initial: account.initial, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account.email)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if account.needsReconnect {
                    Text("Reconnect needed")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    Text("Connected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if schedule.syncingBeforeRemoval == account.id {
                ProgressView()
            } else {
                Menu {
                    accountActions(account)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text(verbatim: account.email))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            accountActions(account, inSwipe: true)
        }
    }

    /// In a swipe, "Remove account" is red without the destructive role, which would slide the row away before the
    /// confirmation is answered.
    @ViewBuilder
    private func accountActions(_ account: GoogleAccount, inSwipe: Bool = false) -> some View {
        Button(role: inSwipe ? nil : .destructive) {
            Task { removal = await schedule.prepareRemoval(of: account) }
        } label: {
            Label("Remove account", systemImage: "person.crop.circle.badge.minus")
        }
        .tint(.red)
        if account.needsReconnect {
            Button {
                dismiss()
                Task { await schedule.reconnect(accountID: account.id) }
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .tint(.orange)
        }
    }

    // MARK: Smart Schedules Pro

    private var proSection: some View {
        Section {
            LabeledContent("Status") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: subscriptions.statusText)
                    if let renewal = renewalText {
                        Text(renewal)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                Task {
                    isRestoring = true
                    restoreFoundNothing = false
                    await subscriptions.restore()
                    isRestoring = false
                    restoreFoundNothing = !subscriptions.isPro
                }
            } label: {
                HStack {
                    Text("Restore Purchases")
                    Spacer(minLength: 8)
                    if isRestoring { ProgressView() }
                }
            }
            .disabled(isRestoring)

            if restoreFoundNothing {
                Text("No purchases to restore.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("Manage Subscription") {
                showsManageSubscriptions = true
            }

            if let terms = Self.url(forInfoKey: "SSTermsURL") {
                Button("Terms of Use") { openURL(terms) }
            }
            if let privacy = Self.url(forInfoKey: "SSPrivacyURL") {
                Button("Privacy Policy") { openURL(privacy) }
            }
        } header: {
            Text(verbatim: "Smart Schedules Pro")
        } footer: {
            Text("Subscriptions renew automatically unless cancelled at least 24 hours before the end of the period. Manage or cancel them in your Apple Account settings.")
        }
    }

    /// "Renews 10月14日" / "Expires Oct 14" when StoreKit knows the date.
    private var renewalText: String? {
        guard subscriptions.isPro, let date = subscriptions.expirationDate else { return nil }
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return subscriptions.willAutoRenew == true
            ? String(localized: "Renews \(day)")
            : String(localized: "Expires \(day)")
    }

    static func url(forInfoKey key: String) -> URL? {
        AppConstants.info(key).flatMap(URL.init(string:))
    }

    // MARK: StoreKit testing (Debug builds only)

    #if DEBUG
    private var storeKitTestingSection: some View {
        Section {
            if subscriptions.products.isEmpty {
                Text(verbatim: "No products (run with Config/SmartSchedule.storekit)")
                    .foregroundStyle(.secondary)
            }
            ForEach(subscriptions.products, id: \.id) { product in
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: product.displayName)
                        Text(verbatim: product.displayPrice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { _ = try? await subscriptions.purchase(product) }
                    } label: {
                        Text(verbatim: "Buy")
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Text(verbatim: "StoreKit testing")
        }
    }
    #endif
}
