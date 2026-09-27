import Foundation
import Observation

enum ContentAccess: String, Codable, Sendable {
    /// Chapter 1 and the Five-Question Filter.
    case sample
    /// Every chapter and every tool.
    case full
}

/// Persisted so the app opens instantly, and offline, with the last verified answer.
struct EntitlementState: Codable, Sendable, Equatable {
    var access: ContentAccess = .sample
    /// Ask to Buy or another deferred purchase is waiting. Kept across relaunches;
    /// the transaction-updates listener clears it when the App Store resolves it.
    var awaitingApproval = false
    var lastVerifiedAt: Date?
}

/// What the App Store currently reports for the full-book product, from verified transactions only.
enum EntitlementSnapshot: Sendable, Equatable {
    case active
    case revoked
    case none
}

enum PurchaseOutcome: Sendable, Equatable {
    case verified
    case unverified
    case pending
    case cancelled
}

enum EntitlementEvent: Sendable, Equatable {
    /// A fresh read of the current entitlements succeeded.
    case refreshed(EntitlementSnapshot, at: Date)
    /// The entitlement read failed; keep the cached state.
    case refreshUnavailable
    case purchased(PurchaseOutcome, at: Date)
    /// A transaction arrived outside a purchase call: Ask to Buy approval, a
    /// purchase on another device, a refund or a revocation.
    case transactionUpdate(EntitlementSnapshot, at: Date)
}

enum EntitlementReducer {
    static func reduce(_ state: EntitlementState, _ event: EntitlementEvent) -> EntitlementState {
        var next = state
        switch event {
        case .refreshed(.active, let date), .transactionUpdate(.active, let date), .purchased(.verified, let date):
            next.access = .full
            next.awaitingApproval = false
            next.lastVerifiedAt = date
        case .refreshed(.revoked, _), .transactionUpdate(.revoked, _):
            next.access = .sample
            next.awaitingApproval = false
        case .refreshed(.none, _):
            // An authoritative read with no entitlement locks paid content. A pending
            // Ask to Buy request is not an entitlement, so the flag is left for the listener.
            next.access = .sample
        case .transactionUpdate(.none, _), .refreshUnavailable:
            break
        case .purchased(.pending, _):
            next.awaitingApproval = true
        case .purchased(.unverified, _), .purchased(.cancelled, _):
            // Never unlock on an unverified transaction.
            break
        }
        return next
    }
}

/// The App Store boundary. `StoreKitPurchaseProvider` is the real one; tests use a fake.
protocol PurchaseProvider: Sendable {
    func currentEntitlement() async throws -> EntitlementSnapshot
    func purchase() async throws -> PurchaseOutcome
    /// Asks the App Store to sync transactions (the Restore button).
    func restore() async throws
    func displayPrice() async -> String?
    func transactionUpdates() -> AsyncStream<EntitlementSnapshot>
}

@MainActor
@Observable
final class EntitlementModel {
    enum Flow: Equatable {
        case idle
        case working
        case message(String)
    }

    private(set) var state: EntitlementState
    private(set) var flow: Flow = .idle
    private(set) var displayPrice: String?

    @ObservationIgnored var onChange: ((EntitlementState) -> Void)?
    @ObservationIgnored private let provider: any PurchaseProvider
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(provider: any PurchaseProvider, cached: EntitlementState, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.state = cached
        self.now = now
    }

    /// Call once at launch: listen for transaction updates, then re-read entitlements.
    func start() async {
        if updatesTask == nil {
            let stream = provider.transactionUpdates()
            let now = self.now
            updatesTask = Task { [weak self] in
                for await snapshot in stream {
                    self?.apply(.transactionUpdate(snapshot, at: now()))
                }
            }
        }
        await refresh()
        displayPrice = await provider.displayPrice()
    }

    func refresh() async {
        do {
            let snapshot = try await provider.currentEntitlement()
            apply(.refreshed(snapshot, at: now()))
        } catch {
            apply(.refreshUnavailable)
        }
    }

    func buy() async {
        flow = .working
        do {
            let outcome = try await provider.purchase()
            apply(.purchased(outcome, at: now()))
            switch outcome {
            case .verified, .cancelled:
                flow = .idle
            case .pending:
                flow = .message("Waiting for approval. The full book unlocks by itself once the purchase is approved.")
            case .unverified:
                flow = .message("The App Store couldn't verify this purchase, so nothing was unlocked. Try again, or tap Restore Purchases.")
            }
        } catch {
            flow = .message("The purchase couldn't be completed. Check your connection and try again.")
        }
        if displayPrice == nil {
            displayPrice = await provider.displayPrice()
        }
    }

    func restore() async {
        flow = .working
        do {
            try await provider.restore()
            await refresh()
            flow = state.access == .full
                ? .idle
                : .message("No earlier purchase of the full book was found for this Apple Account.")
        } catch {
            flow = .message("Restore couldn't reach the App Store. Try again when you're online.")
        }
    }

    func dismissMessage() {
        if case .message = flow { flow = .idle }
    }

    private func apply(_ event: EntitlementEvent) {
        let next = EntitlementReducer.reduce(state, event)
        guard next != state else { return }
        state = next
        onChange?(next)
    }
}
