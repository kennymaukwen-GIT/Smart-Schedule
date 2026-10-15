import Foundation
import Observation
import StoreKit

/// StoreKit 2 infrastructure for the "Smart Schedule Pro" subscription group. Nothing reads `isPro` to gate a
/// feature yet: pricing and what Pro unlocks are the owner's decision (docs/SETTINGS.md §16). Off in version 1.0
/// (`AppConstants.subscriptionsEnabled`): `start()` returns at once and nothing else is reachable.
///
/// StoreKit is the source of truth; nothing is stored here. Local testing uses Config/SmartSchedule.storekit, which
/// the run scheme points at.
@MainActor
@Observable
final class SubscriptionStore {
    static let shared = SubscriptionStore()

    static let monthlyID = "com.smartschedule.pro.monthly"
    static let yearlyID = "com.smartschedule.pro.yearly"
    static let productIDs: [String] = [monthlyID, yearlyID]

    /// Monthly first (cheapest first).
    private(set) var products: [Product] = []
    /// Any verified, unrevoked, unexpired transaction for a Pro product.
    private(set) var isPro = false
    private(set) var activeProductID: String?
    private(set) var expirationDate: Date?
    /// nil while unknown (offline, or the products are not loaded yet).
    private(set) var willAutoRenew: Bool?
    private(set) var isRestoring = false
    /// Set when the last Restore Purchases failed (not when it simply found nothing).
    private(set) var restoreError: String?

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    /// "Free", "Pro · Monthly", "Pro · Yearly".
    var statusText: String {
        guard isPro else { return String(localized: "Free") }
        switch activeProductID {
        case Self.monthlyID: return String(localized: "Pro · Monthly")
        case Self.yearlyID: return String(localized: "Pro · Yearly")
        default: return String(localized: "Pro")
        }
    }

    /// Once at launch: listens for transactions (renewals, purchases on other devices, refunds), loads the
    /// products and works out the entitlement.
    func start() {
        // Version 1.0 sells nothing (AppConstants.subscriptionsEnabled): StoreKit stays idle.
        guard AppConstants.subscriptionsEnabled, updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                if case let .verified(transaction) = result { await transaction.finish() }
                await self?.refreshEntitlements()
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    func loadProducts() async {
        guard let loaded = try? await Product.products(for: Self.productIDs) else { return }
        products = loaded.sorted { $0.price < $1.price }
    }

    func refreshEntitlements() async {
        var best: Transaction?
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            if let current = best,
               (current.expirationDate ?? .distantFuture) >= (transaction.expirationDate ?? .distantFuture) { continue }
            best = transaction
        }
        isPro = best != nil
        activeProductID = best?.productID
        expirationDate = best?.expirationDate
        willAutoRenew = await renewalStatus(of: best)
    }

    /// Restore Purchases: asks the App Store to sync this Apple Account's transactions (it may ask the user to
    /// sign in), then recomputes the entitlement.
    func restore() async {
        isRestoring = true
        restoreError = nil
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
        } catch {
            restoreError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    /// Only the DEBUG "StoreKit testing" section calls this; there is no paywall. True when the purchase went through.
    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        switch try await product.purchase() {
        case let .success(verification):
            guard case let .verified(transaction) = verification else { return false }
            await transaction.finish()
            await refreshEntitlements()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    private func renewalStatus(of transaction: Transaction?) async -> Bool? {
        guard let transaction else { return nil }
        if products.isEmpty { await loadProducts() }
        guard let product = products.first(where: { $0.id == transaction.productID }),
              let statuses = try? await product.subscription?.status else { return nil }
        for status in statuses {
            guard case let .verified(renewal) = status.renewalInfo,
                  case let .verified(statusTransaction) = status.transaction,
                  statusTransaction.originalID == transaction.originalID else { continue }
            return renewal.willAutoRenew
        }
        return nil
    }
}
