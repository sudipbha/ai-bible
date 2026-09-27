import Foundation
@testable import AIBible

/// Scriptable stand-in for the App Store. Tests set the fields, then drive the model.
final class FakePurchaseProvider: PurchaseProvider, @unchecked Sendable {
    struct Offline: Error {}

    var entitlement: EntitlementSnapshot = .none
    var entitlementFails = false
    var purchaseResult: Result<PurchaseOutcome, Error> = .success(.verified)
    /// What the store reports after a successful Restore.
    var entitlementAfterRestore: EntitlementSnapshot?
    var restoreFails = false
    /// Test-only stand-in for the localized App Store price. The app never hard-codes a price.
    var price: String? = "$4.99"
    private(set) var restoreCalls = 0
    private(set) var purchaseCalls = 0
    private(set) var priceCalls = 0

    private var continuation: AsyncStream<EntitlementSnapshot>.Continuation?

    func currentEntitlement() async throws -> EntitlementSnapshot {
        if entitlementFails { throw Offline() }
        return entitlement
    }

    func purchase() async throws -> PurchaseOutcome {
        purchaseCalls += 1
        let outcome = try purchaseResult.get()
        if outcome == .verified { entitlement = .active }
        return outcome
    }

    func restore() async throws {
        restoreCalls += 1
        if restoreFails { throw Offline() }
        if let after = entitlementAfterRestore { entitlement = after }
    }

    func displayPrice() async -> String? {
        priceCalls += 1
        return price
    }

    func transactionUpdates() -> AsyncStream<EntitlementSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Simulates a transaction arriving from the App Store (Ask to Buy approval, refund, revocation).
    func send(_ snapshot: EntitlementSnapshot) {
        entitlement = snapshot
        continuation?.yield(snapshot)
    }
}

enum TestBooks {
    static func small(version: String = "v1", idMap: [String: String]? = nil, chapters: [Chapter]? = nil) -> BookBundle {
        BookBundle(
            contentVersion: version,
            isFixture: true,
            title: "Test book",
            chapters: chapters ?? [
                Chapter(id: "c1", label: "Chapter 1", title: "Free chapter", access: .free, blocks: [
                    Block(id: "c1.h1", kind: .heading, level: 2, text: "Getting started"),
                    Block(id: "c1.p1", kind: .paragraph, text: "The café opens early and answers every quote request by noon."),
                    Block(id: "c1.p2", kind: .paragraph, text: "A second paragraph about follow-up emails."),
                ]),
                Chapter(id: "c2", label: "Chapter 2", title: "Paid chapter", access: .paid, blocks: [
                    Block(id: "c2.p1", kind: .paragraph, text: "Paid text about quote requests and invoices."),
                    Block(id: "c2.p2", kind: .paragraph, text: "Another paid paragraph mentioning the cafe again."),
                ]),
            ],
            idMap: idMap,
            tools: ToolContent(
                filterQuestions: (1...5).map { ToolPrompt(id: "q\($0)", text: "Question \($0)") },
                rolloutItems: (1...3).map { ToolPrompt(id: "s\($0)", text: "Step \($0)") }
            )
        )
    }

    static func temporaryStore() -> FileStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIBibleTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FileStore(url: directory.appendingPathComponent("userdata.json"))
    }
}

/// Lets queued main-actor work (such as the transaction-updates listener) run.
@MainActor
func settle(until condition: () -> Bool, attempts: Int = 200) async {
    var remaining = attempts
    while !condition() && remaining > 0 {
        remaining -= 1
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}
