import Foundation
import StoreKit

/// StoreKit 2 implementation. Only transactions that StoreKit reports as
/// `.verified` count; an unverified result never unlocks anything.
struct StoreKitPurchaseProvider: PurchaseProvider {
    enum StoreError: Error {
        case productUnavailable
    }

    let productID: String

    func currentEntitlement() async throws -> EntitlementSnapshot {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productID == productID else { continue }
            return transaction.revocationDate == nil ? .active : .revoked
        }
        return .none
    }

    func purchase() async throws -> PurchaseOutcome {
        guard let product = try await Product.products(for: [productID]).first else {
            throw StoreError.productUnavailable
        }
        switch try await product.purchase() {
        case .success(.verified(let transaction)):
            await transaction.finish()
            return transaction.revocationDate == nil ? .verified : .unverified
        case .success(.unverified):
            // Left unfinished on purpose; StoreKit may deliver it again once it verifies.
            return .unverified
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws {
        try await AppStore.sync()
    }

    func displayPrice() async -> String? {
        try? await Product.products(for: [productID]).first?.displayPrice
    }

    func transactionUpdates() -> AsyncStream<EntitlementSnapshot> {
        let productID = productID
        return AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard case .verified(let transaction) = result, transaction.productID == productID else { continue }
                    await transaction.finish()
                    continuation.yield(transaction.revocationDate == nil ? .active : .revoked)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
