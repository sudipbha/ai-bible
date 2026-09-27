import SwiftUI

/// One purchase, clearly described, with Restore always next to Buy.
struct UnlockSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = model.entitlements
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Unlock the full book and tools")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("A one-time purchase. No subscription and no account.")

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Every chapter and appendix", systemImage: "book")
                        Label("Rollout tracker", systemImage: "checklist")
                        Label("Whole-job cost worksheet", systemImage: "clock")
                        Label("Works offline once unlocked", systemImage: "wifi.slash")
                    }

                    Text("Free without buying: Chapter 1 and the Five-Question Filter.")
                        .foregroundStyle(.secondary)

                    if store.state.access == .full {
                        Label("Unlocked", systemImage: "checkmark.seal")
                            .font(.headline)
                    } else {
                        Button {
                            Task { await store.buy() }
                        } label: {
                            Text(store.displayPrice.map { "Buy for \($0)" } ?? "Buy")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!store.canStartPurchase)

                        switch store.priceState {
                        case .available:
                            EmptyView()
                        case .notLoaded, .loading:
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Getting the price from the App Store…")
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                        case .unavailable:
                            VStack(alignment: .leading, spacing: 6) {
                                Text("The App Store price isn't available right now. Check your connection, then try again.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button("Try Again") {
                                    Task { await store.refreshPrice() }
                                }
                            }
                        }
                        if store.state.awaitingApproval {
                            Label("Waiting for approval. If it was declined, you can ask again.", systemImage: "hourglass")
                        }
                    }

                    Button {
                        Task { await store.restore() }
                    } label: {
                        Text("Restore Purchases").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.flow == .working)

                    if store.flow == .working {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if case .message(let text) = store.flow {
                        Text(text)
                            .accessibilityAddTraits(.updatesFrequently)
                    }

                    Text("Books bought elsewhere, such as the EPUB edition, don't unlock this app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        store.dismissMessage()
                        dismiss()
                    }
                }
            }
        }
        .task {
            // Fetches the price only; a purchase starts only when Buy is tapped.
            await store.refreshPrice()
        }
        .onChange(of: store.state.access) { _, access in
            if access == .full { dismiss() }
        }
    }
}
