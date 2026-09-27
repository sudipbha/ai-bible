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

    /// The localized price from the App Store. Buy is offered only when this is `.available`.
    enum PriceState: Equatable {
        case notLoaded
        case loading
        case available(String)
        /// The last attempt returned no product (offline, or the product isn't set up yet).
        case unavailable
    }

    private(set) var state: EntitlementState
    private(set) var flow: Flow = .idle
    private(set) var priceState: PriceState = .notLoaded

    var displayPrice: String? {
        if case .available(let price) = priceState { return price }
        return nil
    }

    /// True when a purchase can be started: price known, not already unlocked, nothing in progress.
    var canStartPurchase: Bool {
        displayPrice != nil && state.access != .full && flow != .working
    }

    @ObservationIgnored var onChange: ((EntitlementState) -> Void)?
    @ObservationIgnored private let provider: any PurchaseProvider
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(provider: any PurchaseProvider, cached: EntitlementState, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.state = cached
        self.now = now
    }

    /// The listener task only holds the model weakly, but it keeps iterating the updates
    /// stream (which never ends by itself) after the model is gone. Cancelling it ends that
    /// iteration, which terminates the stream and, for StoreKit, its inner `Transaction.updates`
    /// task.
    deinit {
        updatesTask?.cancel()
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
        await refreshPrice()
    }

    /// One attempt to fetch the localized price. It never starts a purchase. It is
    /// called at launch, when the unlock sheet appears, when the app returns to the
    /// foreground, after Restore, and from the sheet's Try Again button. Each call is
    /// a single request, and a call while another is in flight does nothing.
    func refreshPrice() async {
        guard priceState != .loading else { return }
        if case .available = priceState { return }
        priceState = .loading
        if let price = await provider.displayPrice() {
            priceState = .available(price)
        } else {
            priceState = .unavailable
        }
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
        guard canStartPurchase else { return }
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
    }

    func restore() async {
        flow = .working
        do {
            try await provider.restore()
            await refresh()
            await refreshPrice()
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
